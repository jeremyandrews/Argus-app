import BackgroundTasks
import Network
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    // Background task identifiers
    private let backgroundFetchIdentifier = "com.arguspulse.articlefetch"

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Setup the badge update system
        NotificationUtils.setupBadgeUpdateSystem()

        // Register background tasks
        SyncManager.shared.registerBackgroundTasks()

        // Request notification permissions separately from other app startup routines
        requestNotificationPermissions()

        // Defer non-crucial tasks to minimize startup freeze
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.executeDeferredStartupTasks()
        }

        return true
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                    NotificationCenter.default.post(name: Notification.Name("NotificationPermissionGranted"), object: nil)
                }
            } else if let error = error {
                print("Error requesting notification authorization: \(error)")
            }
        }
    }

    private func executeDeferredStartupTasks() {
        // Single dispatch with sequential timing
        DispatchQueue.global(qos: .utility).async {
            ArgusApp.logDatabaseTableSizes()

            Thread.sleep(forTimeInterval: 0.3)
            self.verifyDatabaseIndexes()

            Thread.sleep(forTimeInterval: 0.5)
            // Instead of starting indefinite processing, just queue one cycle
            Task {
                _ = await SyncManager.shared.processQueue()
            }

            Thread.sleep(forTimeInterval: 0.5)

            DispatchQueue.main.async {
                self.cleanupOldArticles()
                self.removeDuplicateNotifications()
            }
        }
    }

    private func verifyDatabaseIndexes() {
        do {
            let success = try ArgusApp.ensureDatabaseIndexes()
            if success {
                print("Database indexes verified successfully")
            }
        } catch {
            print("Database index creation failed: \(error)")
        }
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Device Token: \(token)")

        // Save the token for later use
        UserDefaults.standard.set(token, forKey: "deviceToken")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register: \(error)")
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Store completion handler in an optional that we'll nil out after first use
        var completion: ((UIBackgroundFetchResult) -> Void)? = completionHandler
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid

        // Helper function to ensure we only complete once
        func finish(_ result: UIBackgroundFetchResult) {
            guard let c = completion else { return }
            completion = nil
            c(result)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask {
            // If we're about to hit the system timeout, clean up and complete
            finish(.failed)
        }

        // 1. Validate push data
        guard
            let aps = userInfo["aps"] as? [String: AnyObject],
            let contentAvailable = aps["content-available"] as? Int,
            contentAvailable == 1,
            let data = userInfo["data"] as? [String: AnyObject],
            let jsonURL = data["json_url"] as? String, !jsonURL.isEmpty
        else {
            finish(.noData)
            return
        }

        // 2. Simply add to queue without additional processing
        Task {
            do {
                // Add to queue
                let context = ArgusApp.sharedModelContainer.mainContext
                let queueManager = context.queueManager()

                // Generate a notification ID for reference
                let notificationID = UUID()

                let added = try await queueManager.addArticleWithNotification(
                    jsonURL: jsonURL,
                    notificationID: notificationID
                )

                if added {
                    print("Added article to processing queue: \(jsonURL)")
                    try context.save()
                    finish(.newData)
                } else {
                    print("Article already in queue: \(jsonURL)")
                    finish(.noData)
                }
            } catch {
                print("Failed to add article to queue: \(error)")
                finish(.failed)
            }
        }
    }

    private func populateSeenArticlesFromNotificationData() {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            let notifications = try context.fetch(FetchDescriptor<NotificationData>())

            for notification in notifications {
                let seenArticle = SeenArticle(id: notification.id, json_url: notification.json_url, date: notification.date)
                context.insert(seenArticle)
            }

            do {
                let _ = try context.fetch(FetchDescriptor<SeenArticle>())
            } catch {
                print("Failed to fetch SeenArticle entries: \(error)")
            }

            do {
                try context.save()
            } catch {
                print("Failed to save context: \(error)")
            }
        } catch {
            print("Failed to populate SeenArticle table: \(error)")
        }
    }

    func saveSeenArticle(id: UUID, json_url: String, date: Date) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let seenArticle = SeenArticle(id: id, json_url: json_url, date: date)

        context.insert(seenArticle)

        do {
            try context.save()
        } catch {
            print("Failed to save seen article: \(error)")
        }
    }

    func cleanupOldArticles() {
        let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
        guard daysSetting > 0 else { return }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!

        Task { @MainActor in // Ensure everything runs in the MainActor context
            let context = ArgusApp.sharedModelContainer.mainContext

            do {
                // **Fetch all expired NotificationData in one query**
                let notificationsToDelete = try context.fetch(
                    FetchDescriptor<NotificationData>(
                        predicate: #Predicate { notification in
                            notification.date < cutoffDate &&
                                !notification.isBookmarked &&
                                !notification.isArchived
                        }
                    )
                )

                guard !notificationsToDelete.isEmpty else { return } // No old notifications

                // **Delete all fetched notifications in a batch**
                for notification in notificationsToDelete {
                    context.delete(notification)
                }

                // **Save the deletions**
                try context.save()

                // **Update badge count**
                NotificationUtils.updateAppBadgeCount()

            } catch {
                print("Cleanup error: \(error)")
            }
        }
    }

    func removeDuplicateNotifications() {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            // Fetch all notifications:
            let allNotes = try context.fetch(FetchDescriptor<NotificationData>())

            // Group them by their json_url
            let grouped = Dictionary(grouping: allNotes, by: { $0.json_url })

            for (_, group) in grouped {
                // If group has 1 or 0, no duplicates
                guard group.count > 1 else { continue }

                // Sort them, e.g. keep the earliest one (or keep the latest)
                // Then delete the rest
                let sorted = group.sorted { a, b in
                    (a.pub_date ?? a.date) < (b.pub_date ?? b.date)
                }
                let toKeep = sorted.first!
                let toDelete = sorted.dropFirst() // everything after the first
                print("Keeping \(toKeep.json_url), removing \(toDelete.count) duplicates...")

                for dupe in toDelete {
                    context.delete(dupe)
                }
            }

            try context.save()
            print("Duplicates removed successfully.")
        } catch {
            print("Error removing duplicates: \(error)")
        }
    }

    @MainActor
    func removeNotificationIfExists(jsonURL: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            // Filter the delivered notifications to find matches
            let matchingIDs = notifications
                .compactMap { delivered -> String? in
                    guard
                        let data = delivered.request.content.userInfo["data"] as? [String: Any],
                        let deliveredURL = data["json_url"] as? String
                    else {
                        return nil
                    }
                    return deliveredURL == jsonURL ? delivered.request.identifier : nil
                }

            // Remove by request identifier
            if !matchingIDs.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matchingIDs)
            }
        }
    }

    private func authenticateDeviceIfNeeded() {
        Task {
            guard UserDefaults.standard.string(forKey: "jwtToken") == nil else { return }
            do {
                let token = try await APIClient.shared.authenticateDevice()
                UserDefaults.standard.set(token, forKey: "jwtToken")
            } catch {
                print("Failed to authenticate device: \(error)")
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Notification.Name {
    static let willDeleteArticle = Notification.Name("willDeleteArticle")
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // If the user actually tapped on a push, parse out the relevant data.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Get json_url, check if priority is "high"
            if
                let data = userInfo["data"] as? [String: AnyObject],
                let jsonURL = data["json_url"] as? String
            {
                // Dispatch onto the main queue to update the UI
                DispatchQueue.main.async {
                    self.presentArticle(jsonURL: jsonURL)
                }
            }
        }

        completionHandler()
    }

    private func presentArticle(jsonURL: String) {
        // 1) Look up the NotificationData:
        let context = ArgusApp.sharedModelContainer.mainContext
        guard let notification = try? context.fetch(
            FetchDescriptor<NotificationData>(predicate: #Predicate { $0.json_url == jsonURL })
        ).first else {
            print("No matching NotificationData found for json_url=\(jsonURL)")
            return
        }

        // 2) Dismiss any existing models
        guard
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first,
            let rootVC = window.rootViewController
        else {
            return
        }

        if let presented = rootVC.presentedViewController {
            // If something is already presented (e.g. a NewsDetailView), dismiss it
            presented.dismiss(animated: false)
        }

        // 3) Create and present the NewsDetailView for this article
        let detailView = NewsDetailView(
            notifications: [notification],
            allNotifications: [notification],
            currentIndex: 0
        )
        .environment(\.modelContext, context)

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen
        rootVC.present(hostingController, animated: true, completion: nil)
    }
}
