import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self

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

        ensureDatabaseTablesCreated()

        // Auto-sync with the server when the application launches.
        Task {
            await SyncManager.shared.sendRecentArticlesToServer()
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
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            // Fetch unviewed notifications
            let unviewedCount = try context.fetch(
                FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
            ).count

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
        var taskID: UIBackgroundTaskIdentifier = .invalid

        taskID = UIApplication.shared.beginBackgroundTask(withName: "SyncData") { [taskID] in
            UIApplication.shared.endBackgroundTask(taskID)
        }

        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let contentAvailable = aps["content-available"] as? Int, contentAvailable == 1
        else {
            completionHandler(.noData)
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        // Extract data payload
        guard let data = userInfo["data"] as? [String: AnyObject],
              let json_url = data["json_url"] as? String, !json_url.isEmpty
        else {
            print("Error: Missing or invalid json_url in push notification")
            completionHandler(.failed)
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        let topic = data["topic"] as? String
        // Extract alert details, or fallback to data if alert is nil
        let alert = aps["alert"] as? [String: String]
        let title = alert?["title"] ?? (data["title"] as? String ?? "[no title]")
        let body = alert?["body"] ?? (data["body"] as? String ?? "[no body]")
        let articleTitle = data["article_title"] as? String ?? "[no article title]"
        let affected = data["affected"] as? String ?? ""
        let domain = data["domain"] as? String

        // Extract pub_date
        var pubDate: Date? = nil
        if let pubDateString = data["pub_date"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            pubDate = isoFormatter.date(from: pubDateString)
        }

        // Create timeout task
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 25_000_000_000) // 25 seconds
            completionHandler(.failed)
            UIApplication.shared.endBackgroundTask(taskID)
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

        Task { @MainActor in
            NotificationUtils.updateAppBadgeCount()
            timeoutTask.cancel()
            completionHandler(.newData)
            UIApplication.shared.endBackgroundTask(taskID)
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

    private func saveNotification(title: String, body: String, json_url: String, topic: String?, articleTitle: String, affected: String, domain: String?, pubDate: Date? = nil, suppressBadgeUpdate _: Bool = false) {
        let context = ArgusApp.sharedModelContainer.mainContext

        // Check for existing notification with same json_url
        do {
            let existingNotifications = try context.fetch(
                FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { $0.json_url == json_url }
                )
            )

            if existingNotifications.isEmpty {
                // Only save if no existing notification found
                SyncManager.shared.saveNotification(
                    title: title,
                    body: body,
                    json_url: json_url,
                    topic: topic,
                    articleTitle: articleTitle,
                    affected: affected,
                    domain: domain,
                    pubDate: pubDate ?? Date()
                )
            }
        } catch {
            print("Error checking for existing notification: \(error)")
        }
    }

    func saveJSONLocally(notification: NotificationData) {
        let jsonURL = notification.json_url // No need for optional binding

        guard let url = URL(string: jsonURL) else {
            print("Error: Invalid URL string \(jsonURL)")
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let fileURL = getLocalFileURL(for: notification)
                try data.write(to: fileURL)
            } catch {
                print("Failed to save JSON locally: \(error)")
            }
        }
    }

    func deleteLocalJSON(notification: NotificationData) {
        let fileURL = getLocalFileURL(for: notification)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                print("Failed to delete local JSON: \(error)")
            }
        }
    }

    func getLocalFileURL(for notification: NotificationData) -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDirectory.appendingPathComponent("\(notification.id).json")
    }

    private func ensureDatabaseTablesCreated() {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            // Check if the SeenArticle table exists by attempting a fetch
            _ = try context.fetch(FetchDescriptor<SeenArticle>())
        } catch {
            print("SeenArticle table missing. Creating and populating it.")
            populateSeenArticlesFromNotificationData()
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

    @MainActor
    func cleanupOldArticles() {
        let context = ArgusApp.sharedModelContainer.mainContext

        // Read user's auto-delete preference (0 = disabled)
        let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
        guard daysSetting > 0 else { return }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date()) ?? Date()

        do {
            // Fetch old SeenArticles
            let oldSeenArticles = try context.fetch(
                FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.date < cutoffDate })
            )

            for seenArticle in oldSeenArticles {
                let oldID = seenArticle.id

                let matchingNotifications = try context.fetch(
                    FetchDescriptor<NotificationData>(
                        predicate: #Predicate { $0.id == oldID }
                    )
                )

                guard let notification = matchingNotifications.first else {
                    // No NotificationData? Just remove the old SeenArticle
                    context.delete(seenArticle)
                    continue
                }

                // Skip if bookmarked or archived
                if notification.isBookmarked || notification.isArchived {
                    continue
                }

                // Otherwise, remove both the NotificationData & SeenArticle
                context.delete(notification)
                context.delete(seenArticle)
            }

            try context.save()
            print("Cleanup complete. Removed old, unbookmarked/unarchived articles.")
        } catch {
            print("Error cleaning up old articles: \(error)")
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive _: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // No saving here, as the notification should already be saved in the background
        completionHandler()
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
        isViewed: Bool = false,
        isBookmarked: Bool = false,
        pub_date: Date? = nil
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
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
        self.pub_date = pub_date
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
