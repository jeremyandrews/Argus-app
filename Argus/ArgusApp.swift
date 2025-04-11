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

    // Migration coordinator for auto-migration
    @StateObject private var migrationCoordinator = MigrationCoordinator.shared

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

                                // Check if migration is needed
                                await checkMigration()

                                // Check CloudKit health on becoming active
                                await performCloudKitHealthCheck()
                            }
                        } else if newPhase == .background {
                            // Mark migration as interrupted if app goes to background during migration
                            if migrationCoordinator.isMigrationActive {
                                migrationCoordinator.appWillTerminate()
                            }

                            // Schedule background health check
                            scheduleCloudKitHealthCheck()
                        }
                    }
                    .disabled(migrationCoordinator.isMigrationActive) // Disable all interaction during migration
                    .alert("CloudKit Status Change", isPresented: $showCloudKitStatusAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(cloudKitAlertMessage)
                    }

                // Migration modal with highest z-index when active
                if migrationCoordinator.isMigrationActive {
                    FullScreenBlockingView {
                        MigrationModalView(coordinator: migrationCoordinator)
                    }
                    .transition(.opacity)
                    .zIndex(100) // Ensure it's on top
                }
            }
            .task {
                // Check migration on app launch
                await checkMigration()
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

    /// Check and start migration if needed
    private func checkMigration() async {
        // Check if migration is needed
        if await migrationCoordinator.checkMigrationStatus() {
            AppLogger.database.info("Starting migration process")

            // Add verification to check if we need to mark migration as complete
            // even if old tables are not accessible
            if await verifyDatabaseTablesExist() == false {
                AppLogger.database.warning("Migration may be incomplete - source tables not found. Marking as completed.")
                migrationCoordinator.markMigrationCompleted()
                return
            }

            // Start migration
            _ = await migrationCoordinator.startMigration()
        }
    }

    /// Helper to verify if source database tables exist
    private func verifyDatabaseTablesExist() async -> Bool {
        // Using SQLite directly to check if the old tables exist
        guard let dbURL = ArgusApp.sharedModelContainer.configurations.first?.url else {
            return false
        }

        var db: OpaquePointer?
        defer {
            if db != nil {
                sqlite3_close(db)
            }
        }

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return false
        }

        let tableCheckQuery = """
            SELECT count(*) FROM sqlite_master
            WHERE type='table' AND (name LIKE '%NOTIFICATIONDATA' OR name LIKE '%SEENARTICLE');
        """

        var statement: OpaquePointer?
        var tableCount = 0

        if sqlite3_prepare_v2(db, tableCheckQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                tableCount = Int(sqlite3_column_int(statement, 0))
            }
            sqlite3_finalize(statement)

            // If we found both tables, return true
            return tableCount >= 2
        }

        // Default to false if anything goes wrong
        return false
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

        // Now search for our specific tables
        let specificTableCheckQuery = """
            SELECT name FROM sqlite_master
            WHERE type='table'
            AND (name LIKE '%NOTIFICATIONDATA' OR name LIKE '%SEENARTICLE');
        """

        var notificationTableName: String?
        var seenArticleTableName: String?

        if sqlite3_prepare_v2(db, specificTableCheckQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let tableNameCString = sqlite3_column_text(statement, 0) {
                    let tableName = String(cString: tableNameCString)
                    if tableName.contains("NOTIFICATIONDATA") {
                        notificationTableName = tableName
                    } else if tableName.contains("SEENARTICLE") {
                        seenArticleTableName = tableName
                    }
                }
            }
        }
        sqlite3_finalize(statement)

        // If tables are missing, create them
        var tablesCreated = false
        if notificationTableName == nil || seenArticleTableName == nil {
            AppLogger.database.warning("Required tables missing - will create them now")
            try ensureRequiredTablesExist(db: db)
            tablesCreated = true

            // Re-query to get the actual table names after creation
            if sqlite3_prepare_v2(db, specificTableCheckQuery, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let tableNameCString = sqlite3_column_text(statement, 0) {
                        let tableName = String(cString: tableNameCString)
                        if tableName.contains("NOTIFICATIONDATA") {
                            notificationTableName = tableName
                        } else if tableName.contains("SEENARTICLE") {
                            seenArticleTableName = tableName
                        }
                    }
                }
            }
            sqlite3_finalize(statement)
        }

        // Only proceed with index creation if tables exist
        if let actualNotificationTableName = notificationTableName {
            createNotificationIndexes(db: db, tableName: actualNotificationTableName)
        } else {
            AppLogger.database.error("NotificationData table still not found after creation attempt")
        }

        if let actualSeenArticleTableName = seenArticleTableName {
            createSeenArticleIndexes(db: db, tableName: actualSeenArticleTableName)
        } else {
            AppLogger.database.error("SeenArticle table still not found after creation attempt")
        }

        if tablesCreated {
            AppLogger.database.info("Database tables created and indexes added successfully")
        }

        return true
    }

    /// Ensures that the required database tables exist, creating them if necessary
    private static func ensureRequiredTablesExist(db: OpaquePointer?) throws {
        AppLogger.database.info("Creating required database tables if needed")

        // The SwiftData model container should handle table creation, but in case that's
        // not working properly, we'll directly create the legacy tables that are needed for migration

        // Force the recreation of the schema by re-instantiating the model container
        // This should trigger SwiftData's table creation
        AppLogger.database.info("Triggering SwiftData schema processing...")

        // As a fallback, directly create tables using SQLite
        // This is a defensive measure to ensure tables exist even if SwiftData fails

        // First try to drop any malformed tables
        let dropNotificationTable = """
        DROP TABLE IF EXISTS ZNOTIFICATIONDATA;
        """

        let dropSeenArticleTable = """
        DROP TABLE IF EXISTS ZSEENARTICLE;
        """

        if sqlite3_exec(db, dropNotificationTable, nil, nil, nil) != SQLITE_OK ||
            sqlite3_exec(db, dropSeenArticleTable, nil, nil, nil) != SQLITE_OK
        {
            AppLogger.database.warning("Error dropping tables, will proceed with creation anyway")
        }

        // Create NotificationData table
        let createNotificationDataTable = """
        CREATE TABLE IF NOT EXISTS ZNOTIFICATIONDATA (
            Z_PK INTEGER PRIMARY KEY AUTOINCREMENT,
            Z_ENT INTEGER,
            Z_OPT INTEGER,
            ZID TEXT NOT NULL,
            ZDATE TIMESTAMP NOT NULL,
            ZTITLE TEXT NOT NULL,
            ZBODY TEXT NOT NULL,
            ZISVIEWED INTEGER NOT NULL DEFAULT 0,
            ZISBOOKMARKED INTEGER NOT NULL DEFAULT 0,
            ZISARCHIVED INTEGER NOT NULL DEFAULT 0,
            ZJSON_URL TEXT NOT NULL,
            ZARTICLE_URL TEXT,
            ZTOPIC TEXT,
            ZARTICLE_TITLE TEXT,
            ZAFFECTED TEXT,
            ZDOMAIN TEXT,
            ZPUB_DATE TIMESTAMP,
            ZSOURCES_QUALITY INTEGER,
            ZARGUMENT_QUALITY INTEGER,
            ZSOURCE_TYPE TEXT,
            ZQUALITY INTEGER,
            ZSUMMARY TEXT,
            ZCRITICAL_ANALYSIS TEXT,
            ZLOGICAL_FALLACIES TEXT,
            ZSOURCE_ANALYSIS TEXT,
            ZRELATION_TO_TOPIC TEXT,
            ZADDITIONAL_INSIGHTS TEXT,
            ZTITLE_BLOB BLOB,
            ZBODY_BLOB BLOB,
            ZSUMMARY_BLOB BLOB,
            ZCRITICAL_ANALYSIS_BLOB BLOB,
            ZLOGICAL_FALLACIES_BLOB BLOB,
            ZSOURCE_ANALYSIS_BLOB BLOB,
            ZRELATION_TO_TOPIC_BLOB BLOB,
            ZADDITIONAL_INSIGHTS_BLOB BLOB,
            ZENGINE_STATS TEXT,
            ZSIMILAR_ARTICLES TEXT
        );
        """

        // Create SeenArticle table
        let createSeenArticleTable = """
        CREATE TABLE IF NOT EXISTS ZSEENARTICLE (
            Z_PK INTEGER PRIMARY KEY AUTOINCREMENT,
            Z_ENT INTEGER,
            Z_OPT INTEGER,
            ZID TEXT NOT NULL,
            ZJSON_URL TEXT NOT NULL,
            ZDATE TIMESTAMP NOT NULL
        );
        """

        // Execute create table statements
        if sqlite3_exec(db, createNotificationDataTable, nil, nil, nil) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(db))
            AppLogger.database.error("Failed to create NotificationData table: \(error)")
            throw DatabaseError.tableNotFound
        }

        if sqlite3_exec(db, createSeenArticleTable, nil, nil, nil) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(db))
            AppLogger.database.error("Failed to create SeenArticle table: \(error)")
            throw DatabaseError.tableNotFound
        }

        AppLogger.database.info("Legacy tables created successfully")
    }

    // Helper method to create notification indexes
    private static func createNotificationIndexes(db: OpaquePointer?, tableName: String) {
        let notificationIndexes = [
            ("idx_notification_date", "ZDATE"),
            ("idx_notification_pubdate", "ZPUB_DATE"),
            ("idx_notification_bookmarked", "ZISBOOKMARKED"),
            ("idx_notification_viewed", "ZISVIEWED"),
            ("idx_notification_archived", "ZISARCHIVED"),
            ("idx_notification_topic", "ZTOPIC"),
            ("idx_notification_id", "ZID"),
            ("idx_notification_json_url", "ZJSON_URL"),
            ("idx_notification_archived_date", "ZISARCHIVED, ZDATE"),
            ("idx_notification_viewed_date", "ZISVIEWED, ZDATE"),
            ("idx_notification_bookmarked_date", "ZISBOOKMARKED, ZDATE"),
            ("idx_notification_topic_viewed", "ZTOPIC, ZISVIEWED"),
            ("idx_notification_topic_bookmarked", "ZTOPIC, ZISBOOKMARKED"),
            ("idx_notification_topic_archived", "ZTOPIC, ZISARCHIVED"),
            ("idx_notification_topic_date", "ZTOPIC, ZDATE"),
            ("idx_notification_topic_pubdate", "ZTOPIC, ZPUB_DATE"),
            ("idx_notification_viewed_pubdate", "ZISVIEWED, ZPUB_DATE"),
            ("idx_notification_bookmarked_pubdate", "ZISBOOKMARKED, ZPUB_DATE"),
            ("idx_notification_domain", "ZDOMAIN"),
            ("idx_notification_title", "ZTITLE"),
            ("idx_notification_sources_quality", "ZSOURCES_QUALITY"),
            ("idx_notification_argument_quality", "ZARGUMENT_QUALITY"),
            ("idx_notification_source_type", "ZSOURCE_TYPE"),
            ("idx_notification_quality", "ZQUALITY"),
        ]

        for (indexName, column) in notificationIndexes {
            let createIndexQuery = """
            CREATE INDEX IF NOT EXISTS \(indexName)
            ON \(tableName) (\(column));
            """
            if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                if !error.contains("no such column") {
                    AppLogger.database.error("Warning: Failed to create index \(indexName): \(error)")
                }
                continue
            }
        }
    }

    // Helper method to create seen article indexes
    private static func createSeenArticleIndexes(db: OpaquePointer?, tableName: String) {
        let seenArticleIndexes = [
            ("idx_seenarticle_date", "ZDATE"),
            ("idx_seenarticle_id", "ZID"),
            ("idx_seenarticle_json_url", "ZJSON_URL"),
        ]

        for (indexName, column) in seenArticleIndexes {
            let createIndexQuery = """
            CREATE INDEX IF NOT EXISTS \(indexName)
            ON \(tableName) (\(column));
            """
            if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                AppLogger.database.error("Warning: Failed to create index \(indexName): \(String(cString: sqlite3_errmsg(db)))")
                continue
            }
        }
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
