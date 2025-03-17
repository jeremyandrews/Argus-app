import BackgroundTasks
import Network
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    }

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

        // Check if we're running UI tests and should set up test data
        if isRunningUITests {
            setupTestDataIfNeeded()
        } else {
            // Only execute deferred startup tasks when not running tests
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.executeDeferredStartupTasks()
            }
        }

        return true
    }

    private func requestNotificationPermissions() {
        // Skip requesting permissions if we're in UI Testing mode
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING_PERMISSIONS_GRANTED") {
            AppLogger.app.info("UI Testing: Skipping notification permission request")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("NotificationPermissionGranted"), object: nil)
            }
            return
        }

        // Normal permission request for real app usage
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                    NotificationCenter.default.post(name: Notification.Name("NotificationPermissionGranted"), object: nil)
                }
            } else if let error = error {
                AppLogger.app.error("Error requesting notification authorization: \(error)")
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
                AppLogger.app.info("Database indexes verified successfully")
            }
        } catch {
            AppLogger.app.error("Database index creation failed: \(error)")
        }
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        AppLogger.app.info("Device Token: \(token)")

        // Save the token for later use
        UserDefaults.standard.set(token, forKey: "deviceToken")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLogger.app.error("Failed to register: \(error)")
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
                    AppLogger.app.info("Added article to processing queue: \(jsonURL)")
                    try context.save()
                    finish(.newData)
                } else {
                    AppLogger.app.info("Article already in queue: \(jsonURL)")
                    finish(.noData)
                }
            } catch {
                AppLogger.app.error("Failed to add article to queue: \(error)")
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
                AppLogger.app.error("Failed to fetch SeenArticle entries: \(error)")
            }

            do {
                try context.save()
            } catch {
                AppLogger.app.error("Failed to save context: \(error)")
            }
        } catch {
            AppLogger.app.error("Failed to populate SeenArticle table: \(error)")
        }
    }

    func saveSeenArticle(id: UUID, json_url: String, date: Date) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let seenArticle = SeenArticle(id: id, json_url: json_url, date: date)

        context.insert(seenArticle)

        do {
            try context.save()
        } catch {
            AppLogger.app.error("Failed to save seen article: \(error)")
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
                AppLogger.app.error("Cleanup error: \(error)")
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
                AppLogger.app.info("Keeping \(toKeep.json_url), removing \(toDelete.count) duplicates...")

                for dupe in toDelete {
                    context.delete(dupe)
                }
            }

            try context.save()
            AppLogger.app.info("Duplicates removed successfully.")
        } catch {
            AppLogger.app.error("Error removing duplicates: \(error)")
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
                AppLogger.app.error("Failed to authenticate device: \(error)")
            }
        }
    }

    private func setupTestDataIfNeeded() {
        // Only proceed if the environment variable is set (adds extra safety)
        guard
            isRunningUITests,
            ProcessInfo.processInfo.environment["SETUP_TEST_DATA"] == "1"
        else {
            return
        }

        let context = ArgusApp.sharedModelContainer.mainContext

        // Check if we already have test data
        do {
            let existingCount = try context.fetchCount(FetchDescriptor<NotificationData>())
            if existingCount > 0 {
                // We already have data, no need to create more
                AppLogger.app.info("UI Tests: Using \(existingCount) existing notifications for testing")
                return
            }

            AppLogger.app.info("UI Tests: Creating test notification data")

            // Create a sample notification for testing
            let testNotification = NotificationData(
                id: UUID(),
                date: Date(), // Now in correct order
                title: "Test Article Title for UI Tests",
                body: "This is a test article body with enough content to display properly in our UI tests.",
                json_url: "https://example.com/test.json",
                article_url: "https://example.com/test-article",
                topic: "Technology",
                article_title: "Test Article Title for UI Tests",
                affected: "",
                domain: "example.com",
                pub_date: Date(),
                isViewed: false,
                isBookmarked: true,
                isArchived: false,
                sources_quality: 3,
                argument_quality: 4,
                source_type: "News",
                source_analysis: "The source appears to be reputable.",
                quality: 3,
                summary: "This is a summary of the test article.",
                critical_analysis: "This is a critical analysis of the article.",
                logical_fallacies: "The article contains some logical fallacies.",
                relation_to_topic: "This article is highly relevant to the topic.",
                additional_insights: "Here are some additional contextual insights."
            )

            // Add the analysis fields needed for the test
            testNotification.summary = "This is a summary of the test article."
            testNotification.critical_analysis = "This is a critical analysis of the article."
            testNotification.logical_fallacies = "The article contains some logical fallacies."
            testNotification.source_analysis = "The source appears to be reputable."
            testNotification.relation_to_topic = "This article is highly relevant to the topic."
            testNotification.additional_insights = "Here are some additional contextual insights."
            testNotification.source_type = "News"
            testNotification.sources_quality = 3
            testNotification.argument_quality = 4

            // Save to the container
            context.insert(testNotification)
            try context.save()

            AppLogger.app.info("UI Tests: Test data created successfully")
        } catch {
            AppLogger.app.error("UI Tests: Error setting up test data: \(error)")
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
            AppLogger.app.error("No matching NotificationData found for json_url=\(jsonURL)")
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
