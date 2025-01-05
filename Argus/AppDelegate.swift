import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var modelContext: ModelContext?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else if let error = error {
                print("Error requesting notification authorization: \(error)")
            }
        }

        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Device Token: \(token)")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register: \(error)")
    }

    private func saveNotification(_ notification: UNNotification) {
        guard let modelContext = modelContext else {
            print("ModelContext is not available.")
            return
        }

        let content = notification.request.content
        let newNotification = NotificationData(date: Date(), title: content.title, body: content.body)
        modelContext.insert(newNotification)
        print("Notification saved: \(newNotification)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        saveNotification(notification)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        saveNotification(response.notification)
        completionHandler()
    }
}

@Model
class NotificationData {
    @Attribute var id: UUID
    @Attribute var date: Date
    @Attribute var title: String
    @Attribute var body: String

    // Required initializer for SwiftData
    init(id: UUID = UUID(), date: Date, title: String, body: String) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
    }
}

struct NotificationsView: View {
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    var body: some View {
        NavigationView {
            List(notifications) { notification in
                NavigationLink(destination: NotificationDetailView(notification: notification)) {
                    VStack(alignment: .leading) {
                        Text(notification.title)
                            .font(.headline)
                        Text(notification.body)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(notification.date, style: .date)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Notifications")
        }
    }
}

struct NotificationDetailView: View {
    var notification: NotificationData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(notification.title)
                .font(.title)
                .bold()
            Text(notification.body)
                .font(.body)
            Text(notification.date, style: .date)
                .font(.footnote)
                .foregroundColor(.gray)
            Spacer()
        }
        .padding()
        .navigationTitle("Detail")
    }
}
