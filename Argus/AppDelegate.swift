import FirebaseCore
import FirebaseMessaging
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        FirebaseApp.configure()

        // Request notification permissions
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("Error requesting notification permissions: \(error.localizedDescription)")
            } else {
                print("Notification permissions granted: \(granted)")
            }
        }

        // Register for remote notifications
        application.registerForRemoteNotifications()
        print("App registered for remote notifications")

        // Be sure our badge count is correct at startup time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.updateBadgeCount()
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
            updateBadgeCount()
        } catch {
            print("Failed to fetch unviewed notifications: \(error)")
            completionHandler(.failed)
            updateBadgeCount()
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
        if let messageID = userInfo["gcm.message_id"] as? String {
            // Firebase notification
            print("Firebase Notification received with ID: \(messageID)")
            Messaging.messaging().appDidReceiveMessage(userInfo)
            completionHandler(.newData)
        } else {
            // Direct notification from your backend
            print("Direct notification received: \(userInfo)")
            handleRemoteNotification(userInfo: userInfo)
            completionHandler(.newData)
        }
    }

    func messaging(_: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token: \(String(describing: fcmToken))")

        // TODO: save the registration token or perform any other necessary actions
    }

    private func handleRemoteNotification(userInfo: [AnyHashable: Any]) {
        print("Notification interaction received: \(userInfo)")

        // Extract custom data from userInfo
        let json_url = userInfo["json_url"] as? String
        let topic = userInfo["topic"] as? String
        let articleTitle = userInfo["article_title"] as? String ?? "[no article title]"
        let affected = userInfo["affected"] as? String ?? ""
        let domain = userInfo["domain"] as? String
        let titleFromData = userInfo["title"] as? String
        let bodyFromData = userInfo["body"] as? String

        // Extract APS payload (optional)
        let aps = userInfo["aps"] as? [String: AnyObject]
        if aps == nil {
            print("APS payload is missing or malformed")
        }
        let alert = aps?["alert"] as? [String: String]
        let titleFromAlert = alert?["title"]
        let bodyFromAlert = alert?["body"]

        // Determine notification title and body
        let title = titleFromAlert ?? titleFromData ?? "[no title]"
        let body = bodyFromAlert ?? bodyFromData ?? "[no body]"

        // Debug extracted values
        print("Extracted values:")
        print("- Title: \(title)")
        print("- Body: \(body)")
        print("- json_url: \(String(describing: json_url))")
        print("- Topic: \(String(describing: topic))")
        print("- Article Title: \(articleTitle)")
        print("- Affected: \(affected)")
        print("- Domain: \(String(describing: domain))")

        // Save notification
        print("Attempting to save notification...")
        saveNotification(
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain
        )
        print("Notification save process completed.")

        // Update badge count
        updateBadgeCount()
        print("Badge count updated.")
    }

    private func saveNotification(title: String, body: String, json_url: String?, topic: String?, articleTitle: String, affected: String, domain: String?) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let newNotification = NotificationData(
            date: Date(),
            title: title,
            body: body,
            json_url: json_url,
            topic: topic,
            article_title: articleTitle,
            affected: affected,
            domain: domain // Add domain here
        )
        context.insert(newNotification)

        do {
            try context.save()
            print("Notification saved: \(newNotification)")
            updateBadgeCount()
        } catch {
            print("Failed to save notification: \(error)")
        }
    }

    func updateBadgeCount() {
        do {
            let context = ArgusApp.sharedModelContainer.mainContext
            let unviewedCount = try context.fetch(
                FetchDescriptor<NotificationData>(predicate: #Predicate { !$0.isViewed })
            ).count
            UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
                if let error = error {
                    print("Failed to set badge count: \(error)")
                }
            }
        } catch {
            print("Failed to fetch unviewed notifications: \(error)")
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["gcm.message_id"] != nil {
            // Firebase notification
            print("Firebase Messaging received message: \(userInfo)")
        } else {
            // Direct notification
            handleRemoteNotification(userInfo: userInfo)
        }
        completionHandler()
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        print("Notification interaction received: \(userInfo)")

        if userInfo["gcm.message_id"] != nil {
            // Firebase notification
            completionHandler([.badge, .sound])
            handleRemoteNotification(userInfo: userInfo)
        } else {
            // Direct notification
            completionHandler([.badge, .sound])
            handleRemoteNotification(userInfo: userInfo)
        }
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
