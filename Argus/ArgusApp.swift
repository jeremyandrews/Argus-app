import SwiftUI
import SwiftData

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

    init() {
        appDelegate.modelContext = sharedModelContainer.mainContext
    }

    var body: some Scene {
        WindowGroup {
            NotificationsView()
                .modelContainer(sharedModelContainer)
        }
    }
}

