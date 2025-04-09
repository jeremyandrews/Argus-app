import SwiftData
import UIKit
import UserNotifications

// Custom notification names (moved from SyncManager)
extension Notification.Name {
    static let articleProcessingCompleted = Notification.Name("ArticleProcessingCompleted")
    static let syncStatusChanged = Notification.Name("SyncStatusChanged")
}

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
    private static func hasNotificationPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    @MainActor
    private static func performBadgeUpdate() async {
        updateScheduled = false

        // Check notification permissions first
        guard await hasNotificationPermission() else {
            AppLogger.ui.warning("Cannot update badge: notification permission not granted")
            return
        }

        // Check badge setting
        guard UserDefaults.standard.bool(forKey: "showBadge") else {
            if cachedUnviewedCount != 0 {
                await setBadgeCount(0)
                cachedUnviewedCount = 0
            }
            return
        }

        do {
            // Use ArticleService to query ArticleModel instead of DatabaseCoordinator with NotificationData
            let unviewedCount = try await ArticleService.shared.countUnviewedArticles()

            // Log the query result for diagnostics
            AppLogger.database.debug("Badge count query returned \(unviewedCount) unviewed articles")

            // Only update if the count actually changed
            if unviewedCount != cachedUnviewedCount {
                await setBadgeCount(unviewedCount)
                cachedUnviewedCount = unviewedCount
                AppLogger.database.debug("Badge count updated to \(unviewedCount)")
            }
        } catch {
            AppLogger.database.error("Failed to query unviewed articles: \(error)")
        }
    }

    // Helper function to set badge count using the modern UNUserNotificationCenter API
    @MainActor
    private static func setBadgeCount(_ count: Int) async {
        // Use the proper non-deprecated API from UNUserNotificationCenter
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    AppLogger.ui.error("Failed to update badge count: \(error)")
                } else {
                    AppLogger.ui.debug("Badge count set to \(count)")
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
    // This method is called directly from SettingsView.swift
    func updateBadgeCount(_ count: Int, completion: ((Error?) -> Void)? = nil) {
        // Use the native UNUserNotificationCenter method
        setBadgeCount(count, withCompletionHandler: completion)
    }
}
