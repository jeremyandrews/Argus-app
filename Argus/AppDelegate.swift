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

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Device Token: \(token)")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register: \(error)")
    }

    func application(_: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let contentAvailable = aps["content-available"] as? Int, contentAvailable == 1
        else {
            completionHandler(.noData)
            return
        }

        if let alert = aps["alert"] as? [String: String],
           let title = alert["title"],
           let body = alert["body"]
        {
            saveNotification(title: title, body: body)
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }

    private func handleRemoteNotification(userInfo: [String: AnyObject]) {
        guard let aps = userInfo["aps"] as? [String: AnyObject],
              let alert = aps["alert"] as? [String: String],
              let title = alert["title"],
              let body = alert["body"]
        else {
            return
        }
        saveNotification(title: title, body: body)
    }

    private func saveNotification(title: String, body: String) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let newNotification = NotificationData(date: Date(), title: title, body: body)
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
    @Attribute var isBookmarked: Bool // New attribute

    init(id: UUID = UUID(), date: Date, title: String, body: String, isViewed: Bool = false, isBookmarked: Bool = false) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
    }
}
