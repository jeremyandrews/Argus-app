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

        return true
    }

    // Error definitions
    enum DatabaseError: Error {
        case containerNotFound
        case databaseNotFound
        case openError(String)
        case tableNotFound
    }
}
