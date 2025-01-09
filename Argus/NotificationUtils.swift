import UIKit
import UserNotifications

extension UNUserNotificationCenter {
    func updateBadgeCount(_ count: Int, completion: ((Error?) -> Void)? = nil) {
        if #available(iOS 17.0, *) {
            // Use the new setBadgeCount API
            self.setBadgeCount(count, withCompletionHandler: { error in
                completion?(error)
            })
        } else {
            // Fallback for iOS versions prior to 17
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = count
                completion?(nil)
            }
        }
    }
}
