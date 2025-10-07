import BackgroundTasks
import CloudKit
import SQLite3
import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // Flag to show the SwiftData test interface
    @State private var showSwiftDataTest = false

    // State for CloudKit status alert
    @State private var showCloudKitStatusAlert = false
    @State private var cloudKitAlertMessage = ""
    @State private var cloudKitStatusChange = false

    // Use the existing SwiftDataContainer instead of creating our own
    @MainActor
    static var sharedModelContainer: ModelContainer {
        // Get the container from the SwiftDataContainer singleton
        // which already handles CloudKit integration and fallbacks
        return SwiftDataContainer.shared.container
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Main content
                ContentView()
                    .modelContainer(ArgusApp.sharedModelContainer)
                    .onAppear {
                        // Set up CloudKit observers when app appears
                        setupCloudKitObservers()

                        // Register background tasks
                        registerBackgroundTasks()

                        // Initialize auto-sync coordinator
                        Task {
                            await AutoSyncCoordinator.shared.scheduleInitialSync()
                        }
                        
                        // Check for performance test mode
                        if ProcessInfo.processInfo.arguments.contains("--performance-test") {
                            Task { @MainActor in
                                await generatePerformanceTestData()
                            }
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            Task { @MainActor in
                                self.appDelegate.cleanupOldArticles()
                                self.appDelegate.removeDuplicateNotifications()

                                // Check CloudKit health on becoming active
                                await performCloudKitHealthCheck()
                            }
                        } else if newPhase == .background {
                            // Schedule background health check
                            scheduleCloudKitHealthCheck()
                        }
                    }
                    .alert("CloudKit Status Change", isPresented: $showCloudKitStatusAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(cloudKitAlertMessage)
                    }
            }
        }
    }
    
    /// Generates test data for performance testing
    @MainActor
    private func generatePerformanceTestData() async {
        AppLogger.database.info("🧪 Generating performance test data...")
        
        let context = ModelContext(ArgusApp.sharedModelContainer)
        
        // Clear existing data first
        do {
            try context.delete(model: ArticleModel.self)
            try context.save()
        } catch {
            AppLogger.database.error("Failed to clear existing data: \(error)")
        }
        
        let topics = [
            "Technology", "Science", "Politics", 
            "Business", "Health", "Sports", "Culture"
        ]
        let articleCounts = [5, 8, 3, 12, 7, 4, 9]
        let qualityLevels = ["Exceptional", "Good", "Fair", "Mediocre", "Poor"]
        
        var articleIndex = 0
        for (topicIndex, topic) in topics.enumerated() {
            let articleCount = articleCounts[topicIndex]
            
            for _ in 0..<articleCount {
                articleIndex += 1
                
                // Every 3rd article is read
                let isRead = (articleIndex % 3 == 0)
                
                // Every 4th article is bookmarked
                let isBookmarked = (articleIndex % 4 == 0)
                
                // Cycle through quality levels
                let qualityString = qualityLevels[articleIndex % qualityLevels.count]
                
                // Map quality string to numeric values
                let qualityMap = ["Poor": 1, "Mediocre": 2, "Fair": 3, "Good": 4, "Exceptional": 5]
                let qualityScore = qualityMap[qualityString] ?? 3
                
                // Create test article with proper initializer
                let article = ArticleModel(
                    id: UUID(),
                    jsonURL: "https://example.com/article\(articleIndex).json",
                    url: "https://source.com/article\(articleIndex)",
                    title: "Test Article \(articleIndex) - \(topic)",  // tiny_title
                    body: "Brief summary of article \(articleIndex) in \(topic)",  // tiny_summary
                    domain: "source.com",
                    articleTitle: "Full Article Title \(articleIndex) - \(topic)",
                    affected: "General Public",
                    publishDate: Date().addingTimeInterval(TimeInterval(-articleIndex * 3600)),
                    addedDate: Date(),
                    topic: topic,
                    isViewed: isRead,
                    isBookmarked: isBookmarked,
                    sourcesQuality: qualityScore,
                    argumentQuality: qualityScore,
                    sourceType: "news",
                    sourceAnalysis: "Source analysis for test article \(articleIndex)",
                    quality: qualityScore
                )
                
                // Add content for detail view testing
                article.tinyTitle = "Tiny: Test Article \(articleIndex) - \(topic)"
                article.tinySummary = "Summary for article \(articleIndex). This is a test summary that should appear quickly."
                article.summary = """
                # Full Summary for \(articleIndex)
                
                This is a comprehensive summary that includes multiple paragraphs of content.
                
                ## Key Points
                - Point 1: Important detail about the article
                - Point 2: Another crucial aspect to consider
                - Point 3: Final key takeaway from the content
                
                ## Conclusion
                The article provides valuable insights into the topic and demonstrates the importance
                of thorough analysis and careful consideration of all aspects.
                """
                
                article.criticalAnalysis = """
                # Critical Analysis for \(articleIndex)
                
                This section provides detailed analysis with multiple components:
                
                1. **First Component**: Detailed explanation of the first aspect
                2. **Second Component**: In-depth look at the second element
                3. **Third Component**: Comprehensive review of the third factor
                
                The content continues with additional paragraphs that provide context
                and supporting information for better understanding.
                """
                
                article.relationToTopic = "This article directly relates to \(topic) by discussing key developments and trends."
                
                article.additionalInsights = """
                # Context & Perspective for \(articleIndex)
                
                This section provides detailed analysis with multiple components:
                
                1. **First Component**: Detailed explanation of the first aspect
                2. **Second Component**: In-depth look at the second element
                3. **Third Component**: Comprehensive review of the third factor
                
                The content continues with additional paragraphs that provide context
                and supporting information for better understanding.
                """
                
                article.eli5 = """
                # Simple Breakdown for \(articleIndex)
                
                This section provides detailed analysis with multiple components:
                
                1. **First Component**: Detailed explanation of the first aspect
                2. **Second Component**: In-depth look at the second element
                3. **Third Component**: Comprehensive review of the third factor
                
                The content continues with additional paragraphs that provide context
                and supporting information for better understanding.
                """
                
                // Add to context
                context.insert(article)
            }
        }
        
        // Save all test articles
        do {
            try context.save()
            AppLogger.database.info("🧪 Successfully generated \(articleIndex) test articles")
            
            // Set default filters for testing: unread only, not bookmarked, Fair+ quality
            UserDefaults.standard.set(true, forKey: "filterUnread")
            UserDefaults.standard.set(false, forKey: "filterBookmarked")
            UserDefaults.standard.set("Fair+", forKey: "qualityFilter")
        } catch {
            AppLogger.database.error("Failed to save test data: \(error)")
        }
    }

    /// Sets up notification observers for CloudKit status changes
    private func setupCloudKitObservers() {
        // Listen for health status changes
        NotificationCenter.default.addObserver(
            forName: .cloudKitHealthStatusChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let status = notification.userInfo?["status"] as? String,
               let previousStatus = notification.userInfo?["previousStatus"] as? String,
               status != previousStatus
            {
                // Only show alert for significant changes
                if status == CloudKitHealthMonitor.HealthStatus.failed.rawValue {
                    cloudKitAlertMessage = "CloudKit sync is currently unavailable. Your data will be stored locally until iCloud is available again."
                    showCloudKitStatusAlert = true
                } else if status == CloudKitHealthMonitor.HealthStatus.healthy.rawValue,
                          previousStatus == CloudKitHealthMonitor.HealthStatus.failed.rawValue
                {
                    cloudKitAlertMessage = "CloudKit sync has been restored. Your data will now sync across your devices."
                    showCloudKitStatusAlert = true
                }
            }
        }

        // Listen for mode changes between CloudKit and local storage
        NotificationCenter.default.addObserver(
            forName: .cloudKitModeChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let containerType = notification.userInfo?["containerType"] as? String {
                let isUsingCloudKit = containerType == "cloudKit"

                cloudKitStatusChange = true
                cloudKitAlertMessage = isUsingCloudKit ?
                    "CloudKit sync has been enabled. Your data will now sync across your devices." :
                    "CloudKit sync is currently disabled. Your data will be stored locally until iCloud is available again."
                showCloudKitStatusAlert = true
            }
        }

        // Also observe account status and network condition changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CKAccountChanged,
            object: nil,
            queue: .main
        ) { _ in
            // Account status changed - check if CloudKit is now available
            Task { @MainActor in
                await attemptCloudKitRecovery()
            }
        }
    }

    /// Performs a health check on CloudKit to update status
    @MainActor
    private func performCloudKitHealthCheck() async {
        await SwiftDataContainer.shared.healthMonitor.performHealthCheck()
    }

    /// Attempts to recover CloudKit functionality
    @MainActor
    private func attemptCloudKitRecovery() async {
        // Only try recovery if we're not already using CloudKit
        let container = SwiftDataContainer.shared

        if container.containerType != .cloudKit, await container.attemptCloudKitRecovery() {
            // Successfully recovered - no need to show alert as .cloudKitModeChanged notification will trigger it
            ModernizationLogger.log(.info, component: .cloudKit,
                                    message: "CloudKit recovery successful")
        }
    }

    /// Registers background tasks for CloudKit health monitoring
    private func registerBackgroundTasks() {
        // Register the background task identifier
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.andrews.Argus.cloudKitHealthCheck",
            using: nil
        ) { task in
            handleCloudKitHealthCheck(task: task as! BGProcessingTask)
        }
    }

    /// Schedules a background health check for CloudKit
    private func scheduleCloudKitHealthCheck() {
        let request = BGProcessingTaskRequest(identifier: "com.andrews.Argus.cloudKitHealthCheck")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Schedule for about 1 hour later
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)

        do {
            try BGTaskScheduler.shared.submit(request)
            ModernizationLogger.log(.debug, component: .cloudKit,
                                    message: "Scheduled CloudKit health check for background execution")
        } catch {
            ModernizationLogger.log(.error, component: .cloudKit,
                                    message: "Failed to schedule CloudKit health check: \(error.localizedDescription)")
        }
    }

    /// Handles the background task for CloudKit health check
    private func handleCloudKitHealthCheck(task: BGProcessingTask) {
        // Create a task to perform the health check
        let healthCheckTask = Task.detached(priority: .background) {
            // Attempt CloudKit recovery
            let container = SwiftDataContainer.shared
            if container.containerType != .cloudKit {
                if await container.healthMonitor.verifyCloudKitAvailability() {
                    let recoverySucceeded = await container.attemptCloudKitRecovery()
                    if recoverySucceeded {
                        ModernizationLogger.log(.info, component: .cloudKit,
                                                message: "CloudKit recovery successful in background task")
                    }
                }
            } else {
                // Just do a health check if already using CloudKit
                await container.healthMonitor.performHealthCheck()
            }
        }

        // Set up a task completion handler
        task.expirationHandler = {
            healthCheckTask.cancel()
        }

        // Set up task completion
        Task {
            await healthCheckTask.value

            // Schedule next health check before marking complete
            scheduleCloudKitHealthCheck()

            task.setTaskCompleted(success: true)
        }
    }

    static func ensureDatabaseIndexes() throws -> Bool {
        // Get the URL from the SwiftDataContainer to ensure consistency
        guard let dbURL = SwiftDataContainer.shared.container.configurations.first?.url else {
            throw DatabaseError.databaseNotFound
        }

        var db: OpaquePointer?
        defer {
            if db != nil {
                sqlite3_close(db)
            }
        }

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            throw DatabaseError.openError(String(cString: sqlite3_errmsg(db)))
        }

        // First check if database is valid and has tables
        let tableCountQuery = """
            SELECT count(*) FROM sqlite_master
            WHERE type='table';
        """

        var statement: OpaquePointer?
        var tableCount = 0

        if sqlite3_prepare_v2(db, tableCountQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                tableCount = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)

        if tableCount == 0 {
            AppLogger.database.warning("Database exists but contains no tables. Will attempt to create required tables.")
            try ensureRequiredTablesExist(db: db)
            return true // Tables should now exist, return true to allow processing to continue
        }

        // Create only current SwiftData schema tables
        AppLogger.database.info("Database tables created and indexes added successfully")

        return true
    }

    /// Ensures that the required database tables exist, creating them if necessary
    private static func ensureRequiredTablesExist(db _: OpaquePointer?) throws {
        AppLogger.database.info("Creating required database tables if needed")

        // Force the recreation of the schema by re-instantiating the model container
        // This should trigger SwiftData's table creation
        AppLogger.database.info("Triggering SwiftData schema processing...")

        // The legacy database tables are no longer needed and have been removed
        AppLogger.database.info("Creating SwiftData schema tables only")
    }

    enum DatabaseError: Error {
        case containerNotFound
        case databaseNotFound
        case openError(String)
        case tableNotFound
    }

    static func logDatabaseTableSizes() {
        Task.detached(priority: .background) {
            let container = await MainActor.run {
                sharedModelContainer
            }
            let backgroundContext = ModelContext(container)

            // Helper function to safely execute count and return 0 on error
            func safeCount<T>(_ descriptor: FetchDescriptor<T>, label: String) -> Int {
                do {
                    let count = try backgroundContext.fetchCount(descriptor)
                    AppLogger.database.debug("📊 Database Stats: \(label) size: \(count) records")
                    return count
                } catch {
                    AppLogger.database.error("Error fetching \(label) count: \(error)")
                    return 0
                }
            }

            // Helper function to safely add with overflow protection
            func safeAdd(_ a: Int, _ b: Int) -> Int {
                let result = a.addingReportingOverflow(b)
                if result.overflow {
                    AppLogger.database.error("Arithmetic overflow detected when adding \(a) and \(b)")
                    return Int.max // Return max value as fallback
                }
                return result.partialValue
            }

            // Get counts safely - use ArticleModel instead of NotificationData
            let articleCount = safeCount(FetchDescriptor<ArticleModel>(), label: "ArticleModel table")
            let seenArticleCount = safeCount(FetchDescriptor<SeenArticleModel>(), label: "SeenArticleModel table")

            // Safely calculate total
            let totalRecords = safeAdd(articleCount, seenArticleCount)
            AppLogger.database.debug("📊 Database Stats: Total records across all tables: \(totalRecords)")

            // Continue with other stats directly for logging - using ArticleModel
            // These counts are only used for logging in safeCount and not needed for further calculations
            _ = safeCount(
                FetchDescriptor<ArticleModel>(predicate: #Predicate { !$0.isViewed }),
                label: "Unviewed articles"
            )

            _ = safeCount(
                FetchDescriptor<ArticleModel>(predicate: #Predicate { $0.isBookmarked }),
                label: "Bookmarked articles"
            )

            // Archive feature removed

            // Only attempt cleanup stats if auto-delete is enabled
            let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
            if daysSetting > 0 {
                let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!
                _ = safeCount(
                    FetchDescriptor<ArticleModel>(
                        predicate: #Predicate { article in
                            article.addedDate < cutoffDate &&
                                !article.isBookmarked
                        }
                    ),
                    label: "Articles eligible for cleanup"
                )
            }
        }
    }
}
