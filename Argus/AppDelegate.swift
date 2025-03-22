import BackgroundTasks
import Network
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    }

    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    private var isDuplicateRemovalRunning = false

    // Background task identifiers
    private let backgroundFetchIdentifier = "com.arguspulse.articlefetch"

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Setup the badge update system
        NotificationUtils.setupBadgeUpdateSystem()

        // Register background tasks MUST happen during app launch
        // This can't be deferred as it triggered the crash
        SyncManager.shared.registerBackgroundTasks()

        // Request notification permissions separately from other app startup routines
        requestNotificationPermissions()

        // Check if we're running UI tests and should set up test data
        if isRunningUITests {
            setupTestDataIfNeeded()
        } else {
            // Schedule non-essential tasks to run after UI is visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.executeDeferredStartupTasks()
            }
        }

        return true
    }

    private func requestNotificationPermissions() {
        // Skip requesting permissions if we're in UI Testing mode
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING_PERMISSIONS_GRANTED") {
            AppLogger.app.debug("UI Testing: Skipping notification permission request")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("NotificationPermissionGranted"), object: nil)
            }
            return
        }

        // Normal permission request for real app usage
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                    NotificationCenter.default.post(name: Notification.Name("NotificationPermissionGranted"), object: nil)
                }
            } else if let error = error {
                AppLogger.app.error("Error requesting notification authorization: \(error)")
            }
        }
    }

    private func executeDeferredStartupTasks() {
        // Use async scheduling instead of sleep
        DispatchQueue.global(qos: .background).async {
            // Initial delay
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
                ArgusApp.logDatabaseTableSizes()

                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                    self.verifyDatabaseIndexes()

                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                        Task(priority: .background) {
                            _ = await SyncManager.shared.processQueue()
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.cleanupOldArticles()
                        }
                    }
                }
            }
        }
    }

    private func verifyDatabaseIndexes() {
        do {
            let success = try ArgusApp.ensureDatabaseIndexes()
            if success {
                AppLogger.app.debug("Database indexes verified successfully")
            }
        } catch {
            AppLogger.app.error("Database index creation failed: \(error)")
        }
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        AppLogger.app.info("Device Token: \(token)")

        // Save the token for later use
        UserDefaults.standard.set(token, forKey: "deviceToken")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLogger.app.error("Failed to register: \(error)")
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Store completion handler in an optional that we'll nil out after first use
        var completion: ((UIBackgroundFetchResult) -> Void)? = completionHandler
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid

        // Helper function to ensure we only complete once
        func finish(_ result: UIBackgroundFetchResult) {
            guard let c = completion else { return }
            completion = nil
            c(result)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask {
            // If we're about to hit the system timeout, clean up and complete
            finish(.failed)
        }

        // 1. Validate push data
        guard
            let aps = userInfo["aps"] as? [String: AnyObject],
            let contentAvailable = aps["content-available"] as? Int,
            contentAvailable == 1,
            let data = userInfo["data"] as? [String: AnyObject],
            let jsonURL = data["json_url"] as? String, !jsonURL.isEmpty
        else {
            finish(.noData)
            return
        }

        // 2. Add to queue without blocking
        Task.detached {
            do {
                // Add to queue
                let context = await ModelContext(ArgusApp.sharedModelContainer)
                let queueManager = context.queueManager()

                // Generate a notification ID for reference
                let notificationID = UUID()

                let added = try await queueManager.addArticleWithNotification(
                    jsonURL: jsonURL,
                    notificationID: notificationID
                )

                if added {
                    // Start processing in the background using our improved method
                    Task.detached(priority: .utility) {
                        // Remove the await here since startQueueProcessing() isn't async
                        SyncManager.shared.startQueueProcessing()
                    }
                    await finish(.newData)
                } else {
                    await finish(.noData)
                }
            } catch {
                AppLogger.app.error("Failed to add article to queue: \(error)")
                await finish(.failed)
            }
        }
    }

    private func populateSeenArticlesFromNotificationData() {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            let notifications = try context.fetch(FetchDescriptor<NotificationData>())

            for notification in notifications {
                let seenArticle = SeenArticle(id: notification.id, json_url: notification.json_url, date: notification.date)
                context.insert(seenArticle)
            }

            do {
                let _ = try context.fetch(FetchDescriptor<SeenArticle>())
            } catch {
                AppLogger.app.error("Failed to fetch SeenArticle entries: \(error)")
            }

            do {
                try context.save()
            } catch {
                AppLogger.app.error("Failed to save context: \(error)")
            }
        } catch {
            AppLogger.app.error("Failed to populate SeenArticle table: \(error)")
        }
    }

    func saveSeenArticle(id: UUID, json_url: String, date: Date) {
        let context = ArgusApp.sharedModelContainer.mainContext
        let seenArticle = SeenArticle(id: id, json_url: json_url, date: date)

        context.insert(seenArticle)

        do {
            try context.save()
        } catch {
            AppLogger.app.error("Failed to save seen article: \(error)")
        }
    }

    func cleanupOldArticles() {
        let daysSetting = UserDefaults.standard.integer(forKey: "autoDeleteDays")
        guard daysSetting > 0 else { return }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSetting, to: Date())!

        // Move database operations to a background context to avoid blocking the UI
        Task {
            await BackgroundContextManager.shared.performBackgroundTask { context in
                do {
                    // Fetch all expired NotificationData in one query
                    let notificationsToDelete = try context.fetch(
                        FetchDescriptor<NotificationData>(
                            predicate: #Predicate { notification in
                                notification.date < cutoffDate &&
                                    !notification.isBookmarked &&
                                    !notification.isArchived
                            }
                        )
                    )

                    guard !notificationsToDelete.isEmpty else { return } // No old notifications

                    // Delete all fetched notifications in a batch
                    for notification in notificationsToDelete {
                        context.delete(notification)
                    }

                    // Save the deletions
                    try context.save()

                    // Update badge count on the main thread
                    Task { @MainActor in
                        NotificationUtils.updateAppBadgeCount()
                    }

                    AppLogger.app.debug("Deleted \(notificationsToDelete.count) old notifications")
                } catch {
                    AppLogger.app.error("Cleanup error: \(error)")
                }
            }
        }
    }

    // removeDuplicateNotifications: Comprehensively identifies and removes duplicate articles
    // from the database to maintain data integrity and prevent UI issues.
    //
    // Duplication criteria:
    // 1. Articles with the same UUID (id) are definite duplicates
    // 2. Articles with the same json_url are content duplicates
    // 3. Articles with the same article_url are content duplicates
    //
    // The function processes each type of duplication in order, using intelligent selection
    // criteria to determine which version to keep:
    // - Prioritizes bookmarked and archived articles
    // - Prefers articles with additional metadata/analysis
    // - Falls back to keeping the newest version when other factors are equal
    //
    // This prevents ForEach UUID collision errors in the UI while ensuring
    // that the most valuable version of each article is preserved.
    func removeDuplicateNotifications() {
        guard !isDuplicateRemovalRunning else {
            AppLogger.app.debug("Duplicate removal already in progress, skipping")
            return
        }

        isDuplicateRemovalRunning = true

        // Move to background task
        Task {
            do {
                // Create a fresh context
                let context = ModelContext(ArgusApp.sharedModelContainer)

                // Fetch all notifications
                let fetchAllDescriptor = FetchDescriptor<NotificationData>()
                let allNotifications = try context.fetch(fetchAllDescriptor)

                AppLogger.app.debug("Starting duplicate scan on \(allNotifications.count) total notifications")

                // DIFFERENT APPROACH: Use direct comparison of raw UUIDs
                // Create a dictionary to track seen IDs
                var seenIds = [String: NotificationData]()
                var duplicatesToRemove = [NotificationData]()

                // First pass: Identify duplicate IDs
                for notification in allNotifications {
                    let idString = notification.id.uuidString

                    if let existing = seenIds[idString] {
                        // Decide which one to keep
                        let keepThis = selectBestArticle(from: [existing, notification])
                        let toRemove = keepThis === notification ? existing : notification

                        // Replace in our tracking dictionary if needed
                        if keepThis === notification {
                            seenIds[idString] = notification
                        }

                        // Mark for removal
                        duplicatesToRemove.append(toRemove)
                        AppLogger.app.debug("Found duplicate with ID \(idString), will keep the better version")
                    } else {
                        // First time seeing this ID
                        seenIds[idString] = notification
                    }
                }

                // Remove duplicates found by ID
                var removedCount = 0
                for dupe in duplicatesToRemove {
                    context.delete(dupe)
                    removedCount += 1
                }

                if removedCount > 0 {
                    try context.save()
                    AppLogger.app.debug("Removed \(removedCount) duplicate notifications by ID")
                }

                // Clear tracking variables to free memory
                seenIds.removeAll()
                duplicatesToRemove.removeAll()

                // SECOND PHASE: Handle json_url duplicates
                // Re-fetch to ensure we have a clean state
                let afterIdDedup = try context.fetch(fetchAllDescriptor)
                AppLogger.app.debug("Starting json_url duplicate scan on \(afterIdDedup.count) notifications")

                // Track seen json_urls
                var seenJsonUrls = [String: NotificationData]()

                // Need to use a new array for the second batch of removals
                var jsonUrlDuplicatesToRemove = [NotificationData]()

                // Filter out empty URLs
                for notification in afterIdDedup where !notification.json_url.isEmpty {
                    let url = notification.json_url

                    if let existing = seenJsonUrls[url] {
                        // Same approach as ID deduplication
                        let keepThis = selectBestArticle(from: [existing, notification])
                        let toRemove = keepThis === notification ? existing : notification

                        // Replace in tracking if needed
                        if keepThis === notification {
                            seenJsonUrls[url] = notification
                        }

                        // Mark for removal
                        jsonUrlDuplicatesToRemove.append(toRemove)
                        AppLogger.app.debug("Found duplicate with json_url \(url), will keep the better version")
                    } else {
                        seenJsonUrls[url] = notification
                    }
                }

                // Remove json_url duplicates
                removedCount = 0
                for dupe in jsonUrlDuplicatesToRemove {
                    context.delete(dupe)
                    removedCount += 1
                }

                if removedCount > 0 {
                    try context.save()
                    AppLogger.app.debug("Removed \(removedCount) duplicate notifications by json_url")
                }

                // Clear tracking variables again
                seenJsonUrls.removeAll()
                jsonUrlDuplicatesToRemove.removeAll()

                // THIRD PHASE: Handle article_url duplicates
                // Re-fetch again
                let afterJsonUrlDedup = try context.fetch(fetchAllDescriptor)
                AppLogger.app.debug("Starting article_url duplicate scan on \(afterJsonUrlDedup.count) notifications")

                // Track seen article_urls
                var seenArticleUrls = [String: NotificationData]()
                var articleUrlDuplicatesToRemove = [NotificationData]()

                // Filter out empty or nil article_urls
                for notification in afterJsonUrlDedup {
                    guard let url = notification.article_url, !url.isEmpty else {
                        continue
                    }

                    if let existing = seenArticleUrls[url] {
                        let keepThis = selectBestArticle(from: [existing, notification])
                        let toRemove = keepThis === notification ? existing : notification

                        if keepThis === notification {
                            seenArticleUrls[url] = notification
                        }

                        articleUrlDuplicatesToRemove.append(toRemove)
                        AppLogger.app.debug("Found duplicate with article_url \(url), will keep the better version")
                    } else {
                        seenArticleUrls[url] = notification
                    }
                }

                // Remove article_url duplicates
                removedCount = 0
                for dupe in articleUrlDuplicatesToRemove {
                    context.delete(dupe)
                    removedCount += 1
                }

                if removedCount > 0 {
                    try context.save()
                    AppLogger.app.debug("Removed \(removedCount) duplicate notifications by article_url")
                }

                // Final verification
                let finalCheck = try context.fetch(fetchAllDescriptor)

                // DIRECT CHECK: Hard scan for any remaining duplicates
                var seenIdsInFinalCheck = Set<String>()
                var remainingDuplicates = 0
                var duplicatedIds = [String]()

                for notification in finalCheck {
                    let idString = notification.id.uuidString
                    if seenIdsInFinalCheck.contains(idString) {
                        remainingDuplicates += 1
                        duplicatedIds.append(idString)
                    } else {
                        seenIdsInFinalCheck.insert(idString)
                    }
                }

                if remainingDuplicates > 0 {
                    // Log the first few duplicate IDs found
                    let uniqueDuplicatedIds = Array(Set(duplicatedIds))
                    let truncatedList = uniqueDuplicatedIds.prefix(5).joined(separator: ", ")

                    AppLogger.app.warning("WARNING: \(remainingDuplicates) duplicate IDs still remain after cleanup.")
                    AppLogger.app.warning("Sample duplicated IDs: \(truncatedList)")

                    // EMERGENCY FALLBACK: Try one more time with direct ID-based removal
                    if uniqueDuplicatedIds.count > 0 {
                        AppLogger.app.debug("Attempting emergency cleanup of remaining duplicates")
                        var emergencyRemovalCount = 0

                        // Group notifications by ID for final cleanup
                        let groupedById = Dictionary(grouping: finalCheck) { $0.id.uuidString }

                        // Process each group of duplicates
                        for (_, group) in groupedById where group.count > 1 {
                            // Keep only the best one
                            let best = selectBestArticle(from: group)
                            let toRemove = group.filter { $0 !== best }

                            // Remove the duplicates
                            for dupe in toRemove {
                                context.delete(dupe)
                                emergencyRemovalCount += 1
                            }
                        }

                        if emergencyRemovalCount > 0 {
                            try context.save()
                            AppLogger.app.debug("Emergency cleanup: removed \(emergencyRemovalCount) remaining duplicates")
                        }
                    }
                }

                // Update badge count
                let totalRemoved = duplicatesToRemove.count + jsonUrlDuplicatesToRemove.count +
                    articleUrlDuplicatesToRemove.count

                if totalRemoved > 0 {
                    AppLogger.app.info("✅ Removed \(totalRemoved) total duplicates")

                    Task { @MainActor in
                        NotificationUtils.updateAppBadgeCount()
                    }
                } else {
                    AppLogger.app.info("No duplicates found to remove.")
                }

            } catch {
                AppLogger.app.error("Error removing duplicates: \(error)")
            }

            // Reset flag when done
            isDuplicateRemovalRunning = false
        }
    }

    // Helper function that implements the article selection logic consistently across all deduplication phases
    private func selectBestArticle(from articles: [NotificationData]) -> NotificationData {
        // Sort the articles by multiple criteria to determine which one to keep
        return articles.sorted { a, b in
            // 1. Bookmarked status (highest priority)
            if a.isBookmarked != b.isBookmarked {
                return a.isBookmarked
            }

            // 2. Archive status
            if a.isArchived != b.isArchived {
                return a.isArchived
            }

            // 3. Read status (prefer unread for better user experience)
            if a.isViewed != b.isViewed {
                return !a.isViewed
            }

            // 4. Metadata completeness
            let aHasAnalysis = a.sources_quality != nil || a.argument_quality != nil ||
                a.source_type != nil || a.quality != nil
            let bHasAnalysis = b.sources_quality != nil || b.argument_quality != nil ||
                b.source_type != nil || b.quality != nil

            if aHasAnalysis != bHasAnalysis {
                return aHasAnalysis
            }

            // 5. Rich text content
            let aHasRichText = a.title_blob != nil || a.body_blob != nil
            let bHasRichText = b.title_blob != nil || b.body_blob != nil

            if aHasRichText != bHasRichText {
                return aHasRichText
            }

            // 6. Content length (prefer more detailed content if available)
            let aContentLength = a.title.count + a.body.count
            let bContentLength = b.title.count + b.body.count

            if aContentLength != bContentLength {
                return aContentLength > bContentLength
            }

            // 7. Finally, publication date (prefer newer content)
            return (a.pub_date ?? a.date) > (b.pub_date ?? b.date)
        }.first!
    }

    @MainActor
    func removeNotificationIfExists(jsonURL: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            // Filter the delivered notifications to find matches
            let matchingIDs = notifications
                .compactMap { delivered -> String? in
                    guard
                        let data = delivered.request.content.userInfo["data"] as? [String: Any],
                        let deliveredURL = data["json_url"] as? String
                    else {
                        return nil
                    }
                    return deliveredURL == jsonURL ? delivered.request.identifier : nil
                }

            // Remove by request identifier
            if !matchingIDs.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matchingIDs)
            }
        }
    }

    private func authenticateDeviceIfNeeded() {
        Task {
            guard UserDefaults.standard.string(forKey: "jwtToken") == nil else { return }
            do {
                let token = try await APIClient.shared.authenticateDevice()
                UserDefaults.standard.set(token, forKey: "jwtToken")
            } catch {
                AppLogger.app.error("Failed to authenticate device: \(error)")
            }
        }
    }

    private func setupTestDataIfNeeded() {
        // Only proceed if the environment variable is set (adds extra safety)
        guard
            isRunningUITests,
            ProcessInfo.processInfo.environment["SETUP_TEST_DATA"] == "1"
        else {
            return
        }

        let context = ArgusApp.sharedModelContainer.mainContext

        // Check if we already have test data
        do {
            let existingCount = try context.fetchCount(FetchDescriptor<NotificationData>())
            if existingCount > 0 {
                // We already have data, no need to create more
                AppLogger.app.debug("UI Tests: Using \(existingCount) existing notifications for testing")
                return
            }

            AppLogger.app.debug("UI Tests: Creating test notification data")

            // Create a sample notification for testing
            let testNotification = NotificationData(
                id: UUID(),
                date: Date(), // Now in correct order
                title: "Test Article Title for UI Tests",
                body: "This is a test article body with enough content to display properly in our UI tests.",
                json_url: "https://example.com/test.json",
                article_url: "https://example.com/test-article",
                topic: "Technology",
                article_title: "Test Article Title for UI Tests",
                affected: "",
                domain: "example.com",
                pub_date: Date(),
                isViewed: false,
                isBookmarked: true,
                isArchived: false,
                sources_quality: 3,
                argument_quality: 4,
                source_type: "News",
                source_analysis: "The source appears to be reputable.",
                quality: 3,
                summary: "This is a summary of the test article.",
                critical_analysis: "This is a critical analysis of the article.",
                logical_fallacies: "The article contains some logical fallacies.",
                relation_to_topic: "This article is highly relevant to the topic.",
                additional_insights: "Here are some additional contextual insights."
            )

            // Add the analysis fields needed for the test
            testNotification.summary = "This is a summary of the test article."
            testNotification.critical_analysis = "This is a critical analysis of the article."
            testNotification.logical_fallacies = "The article contains some logical fallacies."
            testNotification.source_analysis = "The source appears to be reputable."
            testNotification.relation_to_topic = "This article is highly relevant to the topic."
            testNotification.additional_insights = "Here are some additional contextual insights."
            testNotification.source_type = "News"
            testNotification.sources_quality = 3
            testNotification.argument_quality = 4

            // Save to the container
            context.insert(testNotification)
            try context.save()

            AppLogger.app.debug("UI Tests: Test data created successfully")
        } catch {
            AppLogger.app.error("UI Tests: Error setting up test data: \(error)")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Notification.Name {
    static let willDeleteArticle = Notification.Name("willDeleteArticle")
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // If the user actually tapped on a push, parse out the relevant data.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Get json_url, check if priority is "high"
            if
                let data = userInfo["data"] as? [String: AnyObject],
                let jsonURL = data["json_url"] as? String
            {
                // Dispatch onto the main queue to update the UI
                DispatchQueue.main.async {
                    self.presentArticle(jsonURL: jsonURL)
                }
            }
        }

        completionHandler()
    }

    private func presentArticle(jsonURL: String) {
        // 1) Look up the NotificationData:
        let context = ArgusApp.sharedModelContainer.mainContext
        guard let notification = try? context.fetch(
            FetchDescriptor<NotificationData>(predicate: #Predicate { $0.json_url == jsonURL })
        ).first else {
            AppLogger.app.error("No matching NotificationData found for json_url=\(jsonURL)")
            return
        }

        // 2) Dismiss any existing models
        guard
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first,
            let rootVC = window.rootViewController
        else {
            return
        }

        if let presented = rootVC.presentedViewController {
            // If something is already presented (e.g. a NewsDetailView), dismiss it
            presented.dismiss(animated: false)
        }

        // 3) Create and present the NewsDetailView for this article
        let detailView = NewsDetailView(
            notifications: [notification],
            allNotifications: [notification],
            currentIndex: 0
        )
        .environment(\.modelContext, context)

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen
        rootVC.present(hostingController, animated: true, completion: nil)
    }
}
