import UIKit
import UserNotifications
import SwiftData

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var notifications: [NotificationData] = [] // Store notifications

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
        let viewController = NotificationsViewController() // Update to use NotificationsViewController
        window?.rootViewController = UINavigationController(rootViewController: viewController)
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
        saveNotification(notification: notification)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        print("Notification opened: \(response.notification.request.content.userInfo)")
        saveNotification(notification: response.notification)
        completionHandler()
    }

    private func saveNotification(notification: UNNotification) {
        let content = notification.request.content
        let newNotification = NotificationData(date: Date(), title: content.title, body: content.body)
        notifications.append(newNotification)
        print("Notification saved: \(newNotification)")
    }
}

struct NotificationData: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let body: String
}

class NotificationsViewController: UITableViewController {
    private var notifications: [NotificationData] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notifications"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return notifications.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let notification = notifications[indexPath.row]
        cell.textLabel?.text = "\(notification.title) - \(notification.body)"
        return cell
    }

    func updateNotifications(_ newNotifications: [NotificationData]) {
        notifications = newNotifications
        tableView.reloadData()
    }
}

