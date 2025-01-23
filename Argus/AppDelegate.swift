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

        return true
    }

    func applicationWillEnterForeground(_: UIApplication) {
        Task {
            await SyncManager.shared.sendRecentArticlesToServer()
        }
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
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let contentAvailable = aps["content-available"] as? Int, contentAvailable == 1
        else {
            completionHandler(.noData)
            return
        }

        // Extract data payload
        let data = userInfo["data"] as? [String: AnyObject]
        let json_url = data?["json_url"] as? String
        let topic = data?["topic"] as? String

        // Extract alert details, or fallback to data if alert is nil
        let alert = aps["alert"] as? [String: String]
        let title = alert?["title"] ?? (data?["title"] as? String ?? "[no title]")
        let body = alert?["body"] ?? (data?["body"] as? String ?? "[no body]")
        let articleTitle = data?["article_title"] as? String ?? "[no article title]"
        let affected = data?["affected"] as? String ?? ""
        // Extract additional data from the `data` field
        let domain = data?["domain"] as? String

        // Save the notification with all extracted details
        saveNotification(
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain // Pass domain here
        )
        completionHandler(.newData)
        NotificationUtils.updateAppBadgeCount()
    }

    private func handleRemoteNotification(userInfo: [String: AnyObject]) {
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let alert = aps["alert"] as? [String: String],
              let title = alert["title"],
              let body = alert["body"]
        else {
            return
        }

        // Extract additional data from the `data` field
        let data = userInfo["data"] as? [String: AnyObject]
        let json_url = data?["json_url"] as? String
        let topic = data?["topic"] as? String
        let articleTitle = data?["article_title"] as? String ?? "[no article title]"
        let affected = data?["affected"] as? String ?? ""
        let domain = data?["domain"] as? String ?? "[unknown]"

        // Save the notification with all extracted details
        saveNotification(
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain
        )
    }

    private func saveNotification(title: String, body: String, json_url: String?, topic: String?, articleTitle: String, affected: String, domain: String?) {
        SyncManager.shared.saveNotification(
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain
        )
    }

    func saveJSONLocally(notification: NotificationData) {
        guard let jsonURL = notification.json_url, let url = URL(string: jsonURL) else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let fileURL = getLocalFileURL(for: notification)
                try data.write(to: fileURL)
                print("Saved JSON locally at: \(fileURL)")
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
                print("Deleted local JSON at: \(fileURL)")
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
            print("SeenArticle table is ready.")
        } catch {
            print("SeenArticle table missing. Creating and populating it.")
            populateSeenArticlesFromNotificationData()
        }
    }

    private func populateSeenArticlesFromNotificationData() {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            let notifications = try context.fetch(FetchDescriptor<NotificationData>())
            print("Notifications fetched: \(notifications)")

            for notification in notifications {
                guard let json_url = notification.json_url else {
                    print("Skipping notification with missing json_url: \(notification)")
                    continue
                }

                let seenArticle = SeenArticle(id: notification.id, json_url: json_url, date: notification.date)
                context.insert(seenArticle)
                print("Inserted SeenArticle: \(seenArticle)")
            }

            do {
                let articles = try context.fetch(FetchDescriptor<SeenArticle>())
                print("SeenArticle entries after population: \(articles)")
            } catch {
                print("Failed to fetch SeenArticle entries: \(error)")
            }

            do {
                try context.save()
                print("Context saved successfully.")
            } catch {
                print("Failed to save context: \(error)")
            }
            print("SeenArticle table populated from NotificationData.")
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
            print("Seen article saved: \(seenArticle)")
        } catch {
            print("Failed to save seen article: \(error)")
        }
    }

    func cleanupOldArticles() {
        let context = ArgusApp.sharedModelContainer.mainContext
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()

        do {
            let oldArticles = try context.fetch(
                FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.date < threeDaysAgo })
            )

            for article in oldArticles {
                context.delete(article)
            }

            try context.save()
            print("Old articles cleaned up.")
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
                print("Device authenticated and token stored.")
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
    @Attribute var id: UUID
    @Attribute var date: Date
    @Attribute var title: String
    @Attribute var body: String
    @Attribute var isViewed: Bool
    @Attribute var isBookmarked: Bool
    @Attribute var isArchived: Bool = false
    @Attribute var json_url: String?
    @Attribute var topic: String?
    @Attribute var article_title: String
    @Attribute var affected: String
    @Attribute var domain: String?

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        body: String,
        json_url: String? = nil,
        topic: String? = nil,
        article_title: String,
        affected: String,
        domain: String? = nil,
        isViewed: Bool = false,
        isBookmarked: Bool = false
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
    }
}

@Model
class SeenArticle {
    @Attribute var id: UUID
    @Attribute var json_url: String
    @Attribute var date: Date

    init(id: UUID, json_url: String, date: Date) {
        self.id = id
        self.json_url = json_url
        self.date = date
    }
}
