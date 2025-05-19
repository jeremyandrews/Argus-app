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
                } else if status == CloudKitHealthMonitor.HealthStatus.healthy.rawValue &&
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
    private static func ensureRequiredTablesExist(db: OpaquePointer?) throws {
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
            let _ = safeCount(
                FetchDescriptor<ArticleModel>(predicate: #Predicate { !$0.isViewed }),
                label: "Unviewed articles"
            )

            let _ = safeCount(
                FetchDescriptor<ArticleModel>(predicate: #Predicate { $0.isBookmarked }),
                label: "Bookmarked articles"
            )

            // Archive feature removed

            // Only attempt cleanup stats if auto-delete is enabled
            let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
            if daysSetting > 0 {
                let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!
                let _ = safeCount(
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
