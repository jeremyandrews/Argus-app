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
                }
            } else if let error = error {
                print("Error requesting notification authorization: \(error)")
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
        } catch {
            print("Failed to fetch unviewed notifications: \(error)")
            completionHandler(.failed)
        }
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Device Token: \(token)")
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

        // Extract alert details
        let alert = aps["alert"] as? [String: String]
        let title = alert?["title"] ?? "[no title]"
        let body = alert?["body"] ?? "[no body]"

        // Save the notification with extracted details
        saveNotification(title: title, body: body, json_url: json_url, topic: topic)
        completionHandler(.newData)
    }

    private func handleRemoteNotification(userInfo: [String: AnyObject]) {
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let alert = aps["alert"] as? [String: String],
              let title = alert["title"],
              let body = alert["body"]
        else {
            return
        }

        // Extract the `json_url` and `topic` from the `data` field
        let data = userInfo["data"] as? [String: AnyObject]
        let json_url = data?["json_url"] as? String
        let topic = data?["topic"] as? String

        saveNotification(title: title, body: body, json_url: json_url, topic: topic)
    }

    private func saveNotification(title: String, body: String, json_url: String?, topic: String?) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let newNotification = NotificationData(
            date: Date(),
            title: title,
            body: body,
            json_url: json_url,
            topic: topic // Add topic here
        )
        context.insert(newNotification)

        do {
            try context.save()
            print("Notification saved: \(newNotification)")

            // Update badge count
            let unviewedCount = try context.fetch(
                FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
            ).count
            UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
                if let error = error {
                    print("Failed to set badge count: \(error)")
                }
            }
        } catch {
            print("Failed to save notification: \(error)")
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
    @Attribute var json_url: String?
    @Attribute var topic: String? // Add this

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        body: String,
        json_url: String? = nil,
        topic: String? = nil, // Add this
        isViewed: Bool = false,
        isBookmarked: Bool = false
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
        self.json_url = json_url
        self.topic = topic // Add this
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
    }
}
