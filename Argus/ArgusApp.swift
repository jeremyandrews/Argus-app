import SQLite3
import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // Flag to show the SwiftData test interface
    @State private var showSwiftDataTest = false

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            // Existing models
            NotificationData.self,
            SeenArticle.self,
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10) {
                do {
                    let _ = try ensureDatabaseIndexes()
                    AppLogger.database.debug("Database indexes created successfully")
                } catch {
                    AppLogger.database.error("Failed to create database indexes: \(error)")
                }
            }
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // Migration coordinator for auto-migration
    @StateObject private var migrationCoordinator = MigrationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Main content
                ContentView()
                    .modelContainer(ArgusApp.sharedModelContainer)
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            Task { @MainActor in
                                self.appDelegate.cleanupOldArticles()
                                self.appDelegate.removeDuplicateNotifications()

                                // Check if migration is needed
                                await checkMigration()
                            }
                        } else if newPhase == .background {
                            // Mark migration as interrupted if app goes to background during migration
                            if migrationCoordinator.isMigrationActive {
                                migrationCoordinator.appWillTerminate()
                            }
                        }
                    }
                    .disabled(migrationCoordinator.isMigrationActive) // Disable all interaction during migration

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

    /// Check and start migration if needed
    private func checkMigration() async {
        // Check if migration is needed
        if await migrationCoordinator.checkMigrationStatus() {
            // Start migration
            _ = await migrationCoordinator.startMigration()
        }
    }

    static func ensureDatabaseIndexes() throws -> Bool {
        guard let dbURL = sharedModelContainer.configurations.first?.url else {
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

        let tableCheckQuery = """
            SELECT name FROM sqlite_master
            WHERE type='table'
            AND (name LIKE '%NOTIFICATIONDATA' OR name LIKE '%SEENARTICLE');
        """

        var statement: OpaquePointer?
        var notificationTableName: String?
        var seenArticleTableName: String?

        if sqlite3_prepare_v2(db, tableCheckQuery, -1, &statement, nil) == SQLITE_OK {
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

        guard let actualNotificationTableName = notificationTableName,
              let actualSeenArticleTableName = seenArticleTableName
        else {
            throw DatabaseError.tableNotFound
        }

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

        let seenArticleIndexes = [
            ("idx_seenarticle_date", "ZDATE"),
            ("idx_seenarticle_id", "ZID"),
            ("idx_seenarticle_json_url", "ZJSON_URL"),
        ]

        for (indexName, column) in notificationIndexes {
            let createIndexQuery = """
            CREATE INDEX IF NOT EXISTS \(indexName)
            ON \(actualNotificationTableName) (\(column));
            """
            if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                if !error.contains("no such column") {
                    AppLogger.database.error("Warning: Failed to create index \(indexName): \(error)")
                }
                continue
            }
        }

        for (indexName, column) in seenArticleIndexes {
            let createIndexQuery = """
            CREATE INDEX IF NOT EXISTS \(indexName)
            ON \(actualSeenArticleTableName) (\(column));
            """
            if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                AppLogger.database.error("Warning: Failed to create index \(indexName): \(String(cString: sqlite3_errmsg(db)))")
                continue
            }
        }

        return true
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
            do {
                let notificationCount = try backgroundContext.fetchCount(FetchDescriptor<NotificationData>())
                AppLogger.database.debug("📊 Database Stats: NotificationData table size: \(notificationCount) records")
                let seenArticleCount = try backgroundContext.fetchCount(FetchDescriptor<SeenArticle>())
                AppLogger.database.debug("📊 Database Stats: SeenArticle table size: \(seenArticleCount) records")
                let totalRecords = notificationCount + seenArticleCount
                AppLogger.database.debug("📊 Database Stats: Total records across all tables: \(totalRecords)")
                let unviewedCount = try backgroundContext.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
                )
                AppLogger.database.debug("📊 Database Stats: Unviewed notifications: \(unviewedCount) records")
                let bookmarkedCount = try backgroundContext.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { $0.isBookmarked })
                )
                AppLogger.database.debug("📊 Database Stats: Bookmarked notifications: \(bookmarkedCount) records")
                let archivedCount = try backgroundContext.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { $0.isArchived })
                )
                AppLogger.database.debug("📊 Database Stats: Archived notifications: \(archivedCount) records")
                let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
                if daysSetting > 0 {
                    let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!
                    let eligibleForCleanupCount = try backgroundContext.fetchCount(
                        FetchDescriptor<NotificationData>(
                            predicate: #Predicate { notification in
                                notification.date < cutoffDate &&
                                    !notification.isBookmarked &&
                                    !notification.isArchived
                            }
                        )
                    )
                    AppLogger.database.debug("📊 Database Stats: Notifications eligible for cleanup: \(eligibleForCleanupCount) records")
                }
            } catch {
                AppLogger.database.error("Error fetching database table sizes: \(error)")
            }
        }
    }
}
