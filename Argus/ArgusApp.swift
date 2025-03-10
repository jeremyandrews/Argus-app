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

            // Create database indexes after container is set up
            Task {
                do {
                    let _ = try ensureDatabaseIndexes()
                    print("Database indexes created successfully")
                } catch {
                    print("Failed to create database indexes: \(error)")
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
                        }
                        Task {
                            await SyncManager.shared.sendRecentArticlesToServer()
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
            ("idx_notification_topic_date", "(ZTOPIC, ZDATE)"),

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
                // Only print an error if it's not about the column not existing
                // This handles the case where we're trying to index a new column that doesn't exist yet
                if !error.contains("no such column") {
                    print("Warning: Failed to create index \(indexName): \(error)")
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
                print("Warning: Failed to create index \(indexName): \(String(cString: sqlite3_errmsg(db)))")
                continue
            }
        }

        // Create ArticleQueueItem indexes if the table exists
        if let actualQueueTableName = articleQueueTableName {
            // Get column names for the ArticleQueueItem table
            let columnQuery = "PRAGMA table_info(\(actualQueueTableName))"
            var columnStatement: OpaquePointer?
            var jsonURLColumnName: String?

            if sqlite3_prepare_v2(db, columnQuery, -1, &columnStatement, nil) == SQLITE_OK {
                while sqlite3_step(columnStatement) == SQLITE_ROW {
                    if let columnNameCString = sqlite3_column_text(columnStatement, 1) {
                        let columnName = String(cString: columnNameCString)
                        // Look for column that contains "jsonURL" or "JSON_URL" (case insensitive)
                        if columnName.lowercased().contains("jsonurl") || columnName.lowercased().contains("json_url") {
                            jsonURLColumnName = columnName
                            break
                        }
                    }
                }
            }
            sqlite3_finalize(columnStatement)

            // Now use the actual column name
            if let jsonURLColumn = jsonURLColumnName {
                let createUniqueIndexQuery = """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_articlequeue_jsonurl
                ON \(actualQueueTableName) (\(jsonURLColumn));
                """

                if sqlite3_exec(db, createUniqueIndexQuery, nil, nil, nil) != SQLITE_OK {
                    print("Warning: Failed to create index idx_articlequeue_jsonurl: \(String(cString: sqlite3_errmsg(db)))")
                }
            } else {
                print("Could not find jsonURL column in \(actualQueueTableName)")
            }

            // Create the normal createdat index as before
            let createDateIndexQuery = """
            CREATE INDEX IF NOT EXISTS idx_articlequeue_createdat
            ON \(actualQueueTableName) (ZCREATEDAT);
            """

            if sqlite3_exec(db, createDateIndexQuery, nil, nil, nil) != SQLITE_OK {
                print("Warning: Failed to create index idx_articlequeue_createdat: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("ArticleQueueItem table not found - will skip creating indexes for it")
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
        Task { @MainActor in
            let context = sharedModelContainer.mainContext

            do {
                // Count NotificationData entries
                let notificationCount = try context.fetchCount(FetchDescriptor<NotificationData>())
                print("📊 Database Stats: NotificationData table size: \(notificationCount) records")

                // Count SeenArticle entries
                let seenArticleCount = try context.fetchCount(FetchDescriptor<SeenArticle>())
                print("📊 Database Stats: SeenArticle table size: \(seenArticleCount) records")

                // Count ArticleQueueItem entries
                let queueItemCount = try context.fetchCount(FetchDescriptor<ArticleQueueItem>())
                print("📊 Database Stats: ArticleQueueItem table size: \(queueItemCount) records")

                // Calculate total records
                let totalRecords = notificationCount + seenArticleCount + queueItemCount
                print("📊 Database Stats: Total records across all tables: \(totalRecords)")

                // Log additional stats about viewed/unviewed status
                let unviewedCount = try context.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
                )
                print("📊 Database Stats: Unviewed notifications: \(unviewedCount) records")

                let bookmarkedCount = try context.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { $0.isBookmarked })
                )
                print("📊 Database Stats: Bookmarked notifications: \(bookmarkedCount) records")

                let archivedCount = try context.fetchCount(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { $0.isArchived })
                )
                print("📊 Database Stats: Archived notifications: \(archivedCount) records")

                // Calculate statistics for articles eligible for cleanup
                let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
                if daysSetting > 0 {
                    let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!

                    let eligibleForCleanupCount = try context.fetchCount(
                        FetchDescriptor<NotificationData>(
                            predicate: #Predicate { notification in
                                notification.date < cutoffDate &&
                                    !notification.isBookmarked &&
                                    !notification.isArchived
                            }
                        )
                    )
                    print("📊 Database Stats: Notifications eligible for cleanup: \(eligibleForCleanupCount) records")
                }
            } catch {
                print("Error fetching database table sizes: \(error)")
            }
        }
    }
}
