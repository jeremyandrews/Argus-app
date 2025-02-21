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
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            // Ensure indexes are created at launch
            ensureDatabaseIndexes()

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
                        Task {
                            await SyncManager.shared.sendRecentArticlesToServer()
                        }
                    }
                }
        }
    }
}

// MARK: - SQLite Index Creation

func ensureDatabaseIndexes() {
    guard let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        print("Failed to get application support directory")
        return
    }

    let databaseURL = containerURL.appendingPathComponent("Argus.sqlite") // Ensure this is your correct SQLite filename

    var db: OpaquePointer?

    if sqlite3_open(databaseURL.path, &db) == SQLITE_OK {
        let createIndexesQuery = """
        CREATE INDEX IF NOT EXISTS idx_notification_date ON NotificationData(date);
        CREATE INDEX IF NOT EXISTS idx_notification_bookmarked ON NotificationData(isBookmarked);
        CREATE INDEX IF NOT EXISTS idx_notification_viewed ON NotificationData(isViewed);
        CREATE INDEX IF NOT EXISTS idx_notification_archived ON NotificationData(isArchived);
        CREATE INDEX IF NOT EXISTS idx_notification_topic ON NotificationData(topic);
        """

        if sqlite3_exec(db, createIndexesQuery, nil, nil, nil) == SQLITE_OK {
            print("Database indexes created successfully")
        } else {
            print("Failed to create indexes: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_close(db)
    } else {
        print("Failed to open database: \(String(cString: sqlite3_errmsg(db ?? nil)))")
    }
}
