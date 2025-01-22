import SwiftData
import SwiftUI

@main
struct ArgusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            NotificationData.self,
            SeenArticle.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(ArgusApp.sharedModelContainer)
        }
    }
}
