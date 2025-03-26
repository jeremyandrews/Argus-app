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

    // Debounce timer for badge updates
    private static var badgeUpdateWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.5 // Half second debounce

    @MainActor
    static func updateAppBadgeCount() {
        // Cancel any pending update
        badgeUpdateWorkItem?.cancel()

        // Simply mark that an update is needed
        updateScheduled = true

        // Create a new debounced update
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                await performBadgeUpdate()
            }
        }
        badgeUpdateWorkItem = workItem

        // Schedule after a short delay for debouncing
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
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

        // Use DatabaseCoordinator for thread-safe database access
        let unviewedCount = await DatabaseCoordinator.shared.countArticles(
            matching: #Predicate<NotificationData> { article in
                !article.isViewed && !article.isArchived
            }
        )

        // Only update if the count actually changed
        if unviewedCount != cachedUnviewedCount {
            await setBadgeCount(unviewedCount)
            cachedUnviewedCount = unviewedCount
            AppLogger.database.debug("Badge count updated to \(unviewedCount)")
        }
    }

    // Helper function to set badge count using the modern API
    @MainActor
    private static func setBadgeCount(_ count: Int) async {
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    AppLogger.ui.error("Failed to update badge count: \(error)")
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
