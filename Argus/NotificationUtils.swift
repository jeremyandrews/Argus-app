import SwiftData
import UIKit
import UserNotifications

class NotificationUtils {
    @MainActor
    static func updateAppBadgeCount() {
        guard UserDefaults.standard.bool(forKey: "showBadge") else {
            UNUserNotificationCenter.current().updateBadgeCount(0)
            return
        }

        do {
            let context = ArgusApp.sharedModelContainer.mainContext
            let unviewedCount = try context.fetch(
                FetchDescriptor<NotificationData>(
                    predicate: #Predicate { !$0.isViewed && !$0.isArchived }
                )
            ).count

            // Use the UNUserNotificationCenter extension to set the badge
            UNUserNotificationCenter.current().updateBadgeCount(unviewedCount) { error in
                if let error = error {
                    print("Failed to set badge count: \(error)")
                }
            }
        } catch {
            print("Failed to fetch unviewed notifications: \(error)")
        }
    }
}

extension UNUserNotificationCenter {
    func updateBadgeCount(_ count: Int, completion: ((Error?) -> Void)? = nil) {
        if #available(iOS 17.0, *) {
            self.setBadgeCount(count) { error in
                completion?(error)
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = count
                completion?(nil)
            }
        }
    }
}
