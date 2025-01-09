import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Shared container for the entire app
    static let sharedModelContainer: ModelContainer = {
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
                        Image(systemName: "newspaper")
                        Text("News")
                    }
                    .modelContainer(ArgusApp.sharedModelContainer)

                SubscriptionsView()
                    .tabItem {
                        Image(systemName: "mail")
                        Text("Subscriptions")
                    }
            }
        }
    }
}
