import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([NotificationData.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TabView {
                NewsView()
                    .tabItem {
                        Label("News", systemImage: "list.bullet")
                    }
                BookmarkedView()
                    .tabItem {
                        Label("Bookmarked", systemImage: "bookmark.fill")
                    }
            }
            .modelContainer(sharedModelContainer)
        }
    }
}
