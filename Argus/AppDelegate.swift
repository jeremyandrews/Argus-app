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
    private var currentNetworkType: NetworkType = .unknown

    // Background task identifiers
    private let backgroundFetchIdentifier = "com.arguspulse.backgroundFetch"

    // Enum to track network connection type
    private enum NetworkType {
        case wifi
        case cellular
        case other
        case unknown
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Start monitoring network type
        startNetworkMonitoring()

        // Set up background refresh
        setupBackgroundRefresh()

        // Request notification permissions
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationUtils.updateAppBadgeCount()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do {
                let success = try ArgusApp.ensureDatabaseIndexes()
                if success {
                    print("Database indexes verified successfully")
                }
            } catch {
                print("Database index creation failed: \(error)")
            }
        }

        // Auto-sync with the server when the application launches, but only if network conditions allow
        Task {
            if shouldAllowSync() {
                await SyncManager.shared.sendRecentArticlesToServer()
            } else {
                print("Skipping initial sync - waiting for WiFi or user permission for cellular data")
            }
        }

        // Call cleanup in the background, but use Task to perform the SwiftData
        // work on the main actor.
        DispatchQueue.global(qos: .background).async {
            Task { @MainActor in
                self.cleanupOldArticles()
            }
        }

        return true
    }

    func application(_: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            do {
                // Check if we should sync based on network conditions
                if !shouldAllowSync() {
                    print("Skipping background fetch - waiting for WiFi or user permission for cellular data")
                    completionHandler(.noData)
                    return
                }

                let context = ArgusApp.sharedModelContainer.mainContext
                // Fetch unviewed notifications
                let unviewedCount = try context.fetch(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
                ).count

                // Use the existing sync function
                await SyncManager.shared.sendRecentArticlesToServer()

                // Update the app's badge count
                UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
                    if let error = error {
                        print("Failed to update badge count during background fetch: \(error)")
                        completionHandler(.failed)
                        return
                    }
                }

                // Indicate successful background fetch
                completionHandler(.newData)
                NotificationUtils.updateAppBadgeCount()
            } catch {
                print("Failed to fetch unviewed notifications: \(error)")
                completionHandler(.failed)
                NotificationUtils.updateAppBadgeCount()
            }
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
            let jsonURL = data["json_url"] as? String,
            !jsonURL.isEmpty
        else {
            finish(.noData)
            return
        }

        // 2. Extract optional fields
        let topic = data["topic"] as? String
        let alert = aps["alert"] as? [String: String]
        let title = alert?["title"] ?? (data["title"] as? String ?? "[no title]")
        let body = alert?["body"] ?? (data["body"] as? String ?? "[no body]")
        let articleTitle = data["article_title"] as? String ?? "[no article title]"
        let affected = data["affected"] as? String ?? ""
        let domain = data["domain"] as? String
        var pubDate: Date? = nil
        if let pubDateString = data["pub_date"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            pubDate = isoFormatter.date(from: pubDateString)
        }

        // Set a manual timeout that's shorter than the system watchdog
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000) // 10 seconds
            finish(.failed)
        }

        // 3. Perform async processing
        Task { @MainActor in
            do {
                try await withTimeout(seconds: 10) {
                    try await SyncManager.shared.addOrUpdateArticle(
                        title: title,
                        body: body,
                        jsonURL: jsonURL,
                        topic: topic,
                        articleTitle: articleTitle,
                        affected: affected,
                        domain: domain,
                        pubDate: pubDate
                    )
                    NotificationUtils.updateAppBadgeCount()
                }

                // Cancel timeout task since we completed successfully
                timeoutTask.cancel()
                finish(.newData)
            } catch is TimeoutError {
                print("Background processing timed out after 10 seconds")
                finish(.failed)
            } catch {
                print("Background task failed: \(error)")
                finish(.failed)
            }
        }
    }

    // Set up background refresh capabilities
    private func setupBackgroundRefresh() {
        if #available(iOS 13.0, *) {
            // Register for background tasks (iOS 13+)
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundFetchIdentifier, using: nil) { task in
                self.handleBackgroundFetch(task: task as! BGAppRefreshTask)
            }

            // Schedule the initial background task
            scheduleAppRefresh()
        } else {
            // Legacy approach for iOS 12 and earlier
            UIApplication.shared.setMinimumBackgroundFetchInterval(3600) // 1 hour
        }
    }

    // Schedule the app refresh task
    @available(iOS 13.0, *)
    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundFetchIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // 1 hour from now

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled app refresh task for background sync")
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }

    // Handle the app refresh task
    @available(iOS 13.0, *)
    private func handleBackgroundFetch(task: BGAppRefreshTask) {
        // Schedule the next refresh before doing work
        scheduleAppRefresh()

        // Create a task to handle the sync
        let syncTask = Task {
            // Check if we should sync based on network conditions
            if shouldAllowSync() {
                // Use the existing sync function
                await SyncManager.shared.sendRecentArticlesToServer()
                NotificationUtils.updateAppBadgeCount()
                task.setTaskCompleted(success: true)
            } else {
                print("Skipping background fetch - waiting for WiFi or user permission for cellular data")
                task.setTaskCompleted(success: false)
            }
        }

        // Set up task expiration handler
        task.expirationHandler = {
            syncTask.cancel()
        }
    }

    // Start monitoring network type
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            if path.usesInterfaceType(.wifi) {
                self.currentNetworkType = .wifi

                // If we've switched to WiFi, trigger a sync
                DispatchQueue.main.async {
                    Task {
                        await SyncManager.shared.sendRecentArticlesToServer()
                    }
                }
            } else if path.usesInterfaceType(.cellular) {
                self.currentNetworkType = .cellular
            } else if path.status == .satisfied {
                self.currentNetworkType = .other
            } else {
                self.currentNetworkType = .unknown
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }

    // Check if we should sync based on network type and settings
    private func shouldAllowSync() -> Bool {
        switch currentNetworkType {
        case .wifi:
            return true
        case .cellular:
            return UserDefaults.standard.bool(forKey: "allowCellularSync")
        case .other, .unknown:
            // For other connection types (like ethernet) or unknown,
            // we'll use the same setting as cellular
            return UserDefaults.standard.bool(forKey: "allowCellularSync")
        }
    }

    private func handleRemoteNotification(userInfo: [String: AnyObject]) {
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let alert = aps["alert"] as? [String: String],
              let title = alert["title"],
              let body = alert["body"],
              let data = userInfo["data"] as? [String: AnyObject],
              let json_url = data["json_url"] as? String, !json_url.isEmpty
        else {
            print("Error: Missing required fields in push notification (title, body, or json_url)")
            return
        }

        let topic = data["topic"] as? String
        let articleTitle = data["article_title"] as? String ?? "[no article title]"
        let affected = data["affected"] as? String ?? ""
        let domain = data["domain"] as? String ?? "[unknown]"

        // Extract pub_date
        var pubDate: Date? = nil
        if let pubDateString = data["pub_date"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            pubDate = isoFormatter.date(from: pubDateString)
        }

        // Save the notification with all extracted details
        saveNotification(
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain,
            pubDate: pubDate
        )
    }

    private func saveNotification(
        title: String,
        body: String,
        json_url: String,
        topic: String?,
        articleTitle: String,
        affected: String,
        domain: String?,
        pubDate: Date? = nil,
        suppressBadgeUpdate: Bool = false
    ) {
        Task {
            do {
                try await SyncManager.shared.addOrUpdateArticle(
                    title: title,
                    body: body,
                    jsonURL: json_url,
                    topic: topic,
                    articleTitle: articleTitle,
                    affected: affected,
                    domain: domain,
                    pubDate: pubDate,
                    suppressBadgeUpdate: suppressBadgeUpdate
                )
            } catch {
                print("Failed to save notification: \(error)")
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

@Model
class NotificationData {
    @Attribute var id: UUID = UUID()
    @Attribute var date: Date = Date()
    @Attribute var title: String = ""
    @Attribute var body: String = ""
    @Attribute var isViewed: Bool = false
    @Attribute var isBookmarked: Bool = false
    @Attribute var isArchived: Bool = false
    @Attribute var json_url: String = ""
    @Attribute var topic: String?
    @Attribute var article_title: String = ""
    @Attribute var affected: String = ""
    @Attribute var domain: String?
    @Attribute var pub_date: Date?

    // New fields for analytics and content
    @Attribute var sources_quality: Int?
    @Attribute var argument_quality: Int?
    @Attribute var source_type: String?
    @Attribute var quality: Int?

    // New fields for content converted from markdown
    @Attribute var summary: String?
    @Attribute var critical_analysis: String?
    @Attribute var logical_fallacies: String?
    @Attribute var source_analysis: String?
    @Attribute var relation_to_topic: String?
    @Attribute var additional_insights: String?

    // Engine statistics and similar articles stored as JSON strings
    @Attribute var engine_stats: String?
    @Attribute var similar_articles: String?

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        body: String,
        json_url: String,
        topic: String? = nil,
        article_title: String,
        affected: String,
        domain: String? = nil,
        pub_date: Date? = nil,
        isViewed: Bool = false,
        isBookmarked: Bool = false,
        isArchived: Bool = false,
        sources_quality: Int? = nil,
        argument_quality: Int? = nil,
        source_type: String? = nil,
        source_analysis: String? = nil,
        quality: Int? = nil,
        summary: String? = nil,
        critical_analysis: String? = nil,
        logical_fallacies: String? = nil,
        relation_to_topic: String? = nil,
        additional_insights: String? = nil,
        engine_stats: String? = nil,
        similar_articles: String? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
        self.json_url = json_url
        self.topic = topic
        self.article_title = article_title
        self.affected = affected
        self.domain = domain
        self.pub_date = pub_date
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
        self.isArchived = isArchived
        self.sources_quality = sources_quality
        self.argument_quality = argument_quality
        self.source_type = source_type
        self.source_analysis = source_analysis
        self.quality = quality
        self.summary = summary
        self.critical_analysis = critical_analysis
        self.logical_fallacies = logical_fallacies
        self.relation_to_topic = relation_to_topic
        self.additional_insights = additional_insights
        self.engine_stats = engine_stats
        self.similar_articles = similar_articles
    }
}

// Extension to provide computed property for effective date
extension NotificationData {
    var effectiveDate: Date {
        return pub_date ?? date
    }
}

@Model
class SeenArticle {
    @Attribute var id: UUID = UUID()
    @Attribute var json_url: String = ""
    @Attribute var date: Date = Date()

    init(id: UUID, json_url: String, date: Date) {
        self.id = id
        self.json_url = json_url
        self.date = date
    }
}
