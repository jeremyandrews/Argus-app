import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Request permission to send push notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("Error requesting push notification authorization: \(error)")
            } else if granted {
                print("Push notification permission granted.")
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else {
                print("Push notification permission denied.")
            }
        }

        UNUserNotificationCenter.current().delegate = self

        window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        window?.rootViewController = viewController
        window?.makeKeyAndVisible()

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Successfully registered for notifications with token: \(token)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
    
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("Notification received while app is in foreground: \(notification.request.content.userInfo)")
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        print("Notification opened: \(response.notification.request.content.userInfo)")
        completionHandler()
    }
}

