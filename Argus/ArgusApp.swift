import SQLite3
import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            NotificationData.self,
            SeenArticle.self,
            ArticleQueueItem.self,
        ])

        // Set up the model configuration with schema versioning
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Delay database index creation significantly but avoid Thread.sleep
            // which can block main-thread-sensitive operations
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(ArgusApp.sharedModelContainer)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            self.appDelegate.cleanupOldArticles()
                            self.appDelegate.removeDuplicateNotifications()
                        }
                    }
                }
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

        // Get the actual table names
        let tableCheckQuery = """
            SELECT name FROM sqlite_master
            WHERE type='table'
            AND (name LIKE '%NOTIFICATIONDATA' OR name LIKE '%SEENARTICLE' OR name LIKE '%ARTICLEQUEUEITEM');
        """

        var statement: OpaquePointer?
        var notificationTableName: String?
        var seenArticleTableName: String?
        var articleQueueTableName: String?

        if sqlite3_prepare_v2(db, tableCheckQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let tableNameCString = sqlite3_column_text(statement, 0) {
                    let tableName = String(cString: tableNameCString)
                    if tableName.contains("NOTIFICATIONDATA") {
                        notificationTableName = tableName
                    } else if tableName.contains("SEENARTICLE") {
                        seenArticleTableName = tableName
                    } else if tableName.contains("ARTICLEQUEUEITEM") {
                        articleQueueTableName = tableName
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

        // Define indexes for NotificationData
        let notificationIndexes = [
            // Main filtering and sorting indexes
            ("idx_notification_date", "ZDATE"),
            ("idx_notification_pubdate", "ZPUB_DATE"),
            ("idx_notification_bookmarked", "ZISBOOKMARKED"),
            ("idx_notification_viewed", "ZISVIEWED"),
            ("idx_notification_archived", "ZISARCHIVED"),
            ("idx_notification_topic", "ZTOPIC"),
            ("idx_notification_id", "ZID"),
            ("idx_notification_json_url", "ZJSON_URL"),

            // Composite indexes for common query combinations
            ("idx_notification_archived_date", "(ZISARCHIVED, ZDATE)"),
            ("idx_notification_viewed_date", "(ZISVIEWED, ZDATE)"),
            ("idx_notification_bookmarked_date", "(ZISBOOKMARKED, ZDATE)"),

            // Composite indexes for topic + filtering combinations (very common in the NewsView)
            ("idx_notification_topic_viewed", "(ZTOPIC, ZISVIEWED)"),
            ("idx_notification_topic_bookmarked", "(ZTOPIC, ZISBOOKMARKED)"),
            ("idx_notification_topic_archived", "(ZTOPIC, ZISARCHIVED)"),
            ("idx_notification_topic_date", "(ZTOPIC, ZDATE)"),
            ("idx_notification_topic_pubdate", "(ZTOPIC, ZPUB_DATE)"),

            // This covers the most common sorting + filtering scenarios
            ("idx_notification_viewed_pubdate", "(ZISVIEWED, ZPUB_DATE)"),
            ("idx_notification_bookmarked_pubdate", "(ZISBOOKMARKED, ZPUB_DATE)"),

            // Additional indexes for detail view operations
            ("idx_notification_domain", "ZDOMAIN"),
            ("idx_notification_title", "ZTITLE"),

            // New indexes for the added fields
            ("idx_notification_sources_quality", "ZSOURCES_QUALITY"),
            ("idx_notification_argument_quality", "ZARGUMENT_QUALITY"),
            ("idx_notification_source_type", "ZSOURCE_TYPE"),
            ("idx_notification_quality", "ZQUALITY"),
        ]

        // Define indexes for SeenArticle
        let seenArticleIndexes = [
            ("idx_seenarticle_date", "ZDATE"),
            ("idx_seenarticle_id", "ZID"),
            ("idx_seenarticle_json_url", "ZJSON_URL"),
        ]

        // Define indexes for ArticleQueueItem
        let articleQueueIndexes = [
            ("idx_articlequeue_createdat", "ZCREATEDAT"),
            ("idx_articlequeue_jsonurl", "ZJSON_URL"),
        ]

        // Create NotificationData indexes
        for (indexName, column) in notificationIndexes {
            let createIndexQuery = """
            CREATE INDEX IF NOT EXISTS \(indexName)
            ON \(actualNotificationTableName) (\(column));
            """

            if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                // Only show an error if it's not about the column not existing
                // This handles the case where we're trying to index a new column that doesn't exist yet
                if !error.contains("no such column") {
                    AppLogger.database.error("Warning: Failed to create index \(indexName): \(error)")
                }
                continue
            }
        }

        // Create SeenArticle indexes
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

        // Create ArticleQueueItem indexes if the table exists
        if let actualQueueTableName = articleQueueTableName {
            // Create ArticleQueueItem indexes using the same loop pattern as the other tables
            for (indexName, column) in articleQueueIndexes {
                let isUnique = indexName.contains("jsonurl") // Make the jsonURL index unique

                let createIndexQuery = """
                CREATE \(isUnique ? "UNIQUE " : "")INDEX IF NOT EXISTS \(indexName)
                ON \(actualQueueTableName) (\(column));
                """

                if sqlite3_exec(db, createIndexQuery, nil, nil, nil) != SQLITE_OK {
                    AppLogger.database.error("Warning: Failed to create index \(indexName): \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        } else {
            AppLogger.database.error("ArticleQueueItem table not found - will skip creating indexes for it")
        }

        return true
    }

    // Error definitions
    enum DatabaseError: Error {
        case containerNotFound
        case databaseNotFound
        case openError(String)
        case tableNotFound
    }

    static func logDatabaseTableSizes() {
        Task.detached(priority: .background) {
            // Access the container on the main actor first
            let container = await MainActor.run {
                sharedModelContainer
            }

            // Create a new background context instead of using the main context
            let backgroundContext = ModelContext(container)

            do {
                // Count NotificationData entries
                let notificationCount = try backgroundContext.fetchCount(FetchDescriptor<NotificationData>())
                AppLogger.database.debug("📊 Database Stats: NotificationData table size: \(notificationCount) records")

                // Count SeenArticle entries
                let seenArticleCount = try backgroundContext.fetchCount(FetchDescriptor<SeenArticle>())
                AppLogger.database.debug("📊 Database Stats: SeenArticle table size: \(seenArticleCount) records")

                // Count ArticleQueueItem entries
                let queueItemCount = try backgroundContext.fetchCount(FetchDescriptor<ArticleQueueItem>())
                AppLogger.database.debug("📊 Database Stats: ArticleQueueItem table size: \(queueItemCount) records")

                // Calculate total records
                let totalRecords = notificationCount + seenArticleCount + queueItemCount
                AppLogger.database.debug("📊 Database Stats: Total records across all tables: \(totalRecords)")

                // Log additional stats about viewed/unviewed status
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

                // Calculate statistics for articles eligible for cleanup
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
