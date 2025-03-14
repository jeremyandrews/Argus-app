import SwiftData
import UIKit
import UserNotifications

class NotificationUtils {
    // Badge count caching
    private static var cachedUnviewedCount: Int = -1
    private static var updateScheduled: Bool = false
    private static var observer: NSObjectProtocol?

    // Setup notification observer when app launches
    static func setupBadgeUpdateSystem() {
        // Remove any existing observer to prevent duplicates
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }

        // Register a single observer for when app moves to background
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await performBadgeUpdate()
            }
        }
    }

    @MainActor
    static func updateAppBadgeCount() {
        // Simply mark that an update is needed
        updateScheduled = true

        // For immediate visual feedback in settings, also perform update
        // when explicitly called (this handles the settings toggle case)
        Task {
            await performBadgeUpdate()
        }
    }

    @MainActor
    private static func performBadgeUpdate() async {
        updateScheduled = false

        // Check badge setting
        guard UserDefaults.standard.bool(forKey: "showBadge") else {
            if cachedUnviewedCount != 0 {
                await setBadgeCount(0)
                cachedUnviewedCount = 0
            }
            return
        }

        do {
            let context = ArgusApp.sharedModelContainer.mainContext
            let unviewedCount = try context.fetch(
                FetchDescriptor<NotificationData>(
                    predicate: #Predicate { !$0.isViewed && !$0.isArchived }
                )
            ).count

            // Only update if the count actually changed
            if unviewedCount != cachedUnviewedCount {
                await setBadgeCount(unviewedCount)
                cachedUnviewedCount = unviewedCount
            }
        } catch {
            print("Failed to fetch unviewed notifications: \(error)")
        }
    }

    // Helper function to set badge count using the modern API
    @MainActor
    private static func setBadgeCount(_ count: Int) async {
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    print("Failed to update badge count: \(error)")
                }
                continuation.resume()
            }
        }
    }

    // For critical cases where an immediate update is truly necessary
    @MainActor
    static func forceImmediateBadgeUpdate() async {
        await performBadgeUpdate()
    }
}

// Extension to maintain compatibility with SettingsView
extension UNUserNotificationCenter {
    func updateBadgeCount(_ count: Int, completion: ((Error?) -> Void)? = nil) {
        // Use the modern API for iOS 18.3+
        setBadgeCount(count) { error in
            completion?(error)
        }
    }
}
