import BackgroundTasks
import CloudKit
import Network
import SQLite3
import SwiftData
import SwiftUI
import UserNotifications

#if canImport(UIKit)
    import UIKit
#endif

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
        BackgroundTaskManager.shared.registerBackgroundTasks()

        // Register CloudKit health check background task
        registerCloudKitHealthCheckTask()

        // Request notification permissions
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

        // Set up CloudKit notification observer for account changes
        setupCloudKitNotificationObservers()

        // Check for and resume any in-progress migrations
        checkAndResumeMigration()

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

    private func executeDeferredStartupTasks() {
        Task.detached(priority: .background) {
            // Initial delay (1 second)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Log database sizes
            await ArgusApp.logDatabaseTableSizes()

            // Verify database indexes (after 2 second delay)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.verifyDatabaseIndexes()

            // Check CloudKit health status
            await self.checkCloudKitHealth()

            // Perform maintenance (after another 2 second delay)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Use ArticleService for quick maintenance operations
            do {
                try await ArticleService.shared.performQuickMaintenance(timeLimit: 10)
            } catch {
                AppLogger.app.error("Error performing startup maintenance: \(error)")
            }

            // Clean up old articles
            await MainActor.run {
                self.cleanupOldArticles()
            }
        }
    }

    /// Registers the background task for CloudKit health check
    private func registerCloudKitHealthCheckTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.andrews.Argus.cloudKitHealthCheck",
            using: nil
        ) { task in
            self.handleCloudKitHealthCheck(task: task as! BGProcessingTask)
        }

        AppLogger.app.debug("CloudKit health check background task registered")
    }

    /// Schedules a background task for CloudKit health check
    private func scheduleCloudKitHealthCheck() {
        let request = BGProcessingTaskRequest(identifier: "com.andrews.Argus.cloudKitHealthCheck")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Schedule for 1 hour later, system will optimize the exact timing
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)

        do {
            try BGTaskScheduler.shared.submit(request)
            ModernizationLogger.log(.debug, component: .cloudKit,
                                    message: "Scheduled CloudKit health check for background execution")
        } catch {
            ModernizationLogger.log(.error, component: .cloudKit,
                                    message: "Failed to schedule CloudKit health check: \(error.localizedDescription)")
        }
    }

    /// Handles the background task for CloudKit health check
    private func handleCloudKitHealthCheck(task: BGProcessingTask) {
        // Create a task to perform the health check
        let healthCheckTask = Task.detached(priority: .background) {
            // Attempt CloudKit recovery
            await self.checkCloudKitHealth()
        }

        // Set up task expiration handler
        task.expirationHandler = {
            healthCheckTask.cancel()
        }

        // Set up task completion
        Task {
            await healthCheckTask.value

            // Schedule next health check before marking complete
            scheduleCloudKitHealthCheck()

            task.setTaskCompleted(success: true)
        }
    }

    /// Performs a health check on CloudKit and attempts recovery if needed
    private func checkCloudKitHealth() async {
        let container = SwiftDataContainer.shared

        // Perform health check to update status
        await container.healthMonitor.performHealthCheck()

        // Attempt recovery if not using CloudKit
        if container.containerType != .cloudKit {
            if await container.attemptCloudKitRecovery() {
                ModernizationLogger.log(.info, component: .cloudKit,
                                        message: "CloudKit recovery successful in background task")
            }
        }
    }

    /// Set up notification observers for CloudKit account status changes
    private func setupCloudKitNotificationObservers() {
        // Observe CloudKit account changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudKitAccountDidChange),
            name: .CKAccountChanged,
            object: nil
        )

        // Listen for network availability changes - use Path monitor instead of notification
        networkMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                // Only check when network becomes available
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    await self.checkCloudKitHealth()
                }
            }
        }

        // Start monitoring network
        networkMonitor.start(queue: monitorQueue)
    }

    /// Handle CloudKit account changes
    @objc private func cloudKitAccountDidChange(_: Notification) {
        AppLogger.app.info("CloudKit account status changed")

        // Schedule a health check
        Task.detached(priority: .background) {
            await self.checkCloudKitHealth()
        }
    }

    /// Handle network availability changes
    @objc private func networkAvailabilityDidChange(_: Notification) {
        // Only check CloudKit if network becomes available
        if networkMonitor.currentPath.status == .satisfied {
            AppLogger.app.info("Network became available, checking CloudKit status")

            Task.detached(priority: .background) {
                await self.checkCloudKitHealth()
            }
        }
    }

    /// Standard application delegate method called when app will enter foreground
    func applicationWillEnterForeground(_: UIApplication) {
        // Auto-cleanup duplicates when app comes to foreground
        Task {
            do {
                let removedCount = try await ArticleService.shared.removeDuplicateArticles()
                if removedCount > 0 {
                    AppLogger.app.info("Auto-cleanup: Removed \(removedCount) duplicate articles on app foreground")
                }
            } catch {
                AppLogger.app.error("Error during automatic duplicate cleanup: \(error)")
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
        func finish(_ result: UIBackgroundFetchResult) async {
            guard let c = completion else { return }
            completion = nil
            c(result)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask {
            Task { @MainActor in
                await finish(.failed)
            }
        }

        // 1. Validate push data
        guard
            let aps = userInfo["aps"] as? [String: AnyObject],
            let contentAvailable = aps["content-available"] as? Int,
            contentAvailable == 1,
            let data = userInfo["data"] as? [String: AnyObject],
            let jsonURL = data["json_url"] as? String, !jsonURL.isEmpty
        else {
            Task { @MainActor in
                await finish(.noData)
            }
            return
        }

        // 2. Process the article using modern API
        Task.detached {
            do {
                // Fetch the article data using APIClient
                let articleData = try await APIClient.shared.fetchArticleByURL(jsonURL: jsonURL)

                // Process it using ArticleService (safely unwrap optional)
                if let articleData = articleData {
                    _ = try await ArticleService.shared.processArticleData([articleData])
                } else {
                    ModernizationLogger.log(.warning, component: .apiClient,
                                            message: "Remote notification contained no article data for URL: \(jsonURL)")
                    throw NSError(domain: "com.argus", code: 404, userInfo: [NSLocalizedDescriptionKey: "No article data found"])
                }

                // Success
                await finish(.newData)
            } catch {
                AppLogger.app.error("Failed to process push notification article: \(error)")
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

        // Use the DatabaseCoordinator for more efficient cleanup
        Task {
            do {
                try await DatabaseCoordinator.shared.performTransaction { _, context in
                    // Fetch all expired NotificationData in one query
                    let notificationsToDelete = try context.fetch(
                        FetchDescriptor<NotificationData>(
                            predicate: #Predicate { notification in
                                notification.date < cutoffDate &&
                                    !notification.isBookmarked
                            }
                        )
                    )

                    guard !notificationsToDelete.isEmpty else { return } // No old notifications

                    // Delete all fetched notifications in a batch
                    for notification in notificationsToDelete {
                        context.delete(notification)
                    }

                    AppLogger.app.debug("Deleted \(notificationsToDelete.count) old notifications")
                }

                // Update badge count on the main thread
                await MainActor.run {
                    NotificationUtils.updateAppBadgeCount()
                }
            } catch {
                AppLogger.app.error("Cleanup error: \(error)")
            }
        }
    }

    func removeDuplicateNotifications() {
        guard !isDuplicateRemovalRunning else {
            AppLogger.app.debug("Duplicate removal already in progress, skipping")
            return
        }

        isDuplicateRemovalRunning = true

        // Move to background task using DatabaseCoordinator for improved concurrency
        Task {
            // This operation will be delegated to the DatabaseCoordinator in future updates
            // For now we'll maintain the current implementation but run it through a transaction

            do {
                try await DatabaseCoordinator.shared.performTransaction { _, context in
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
                            let keepThis = await self.selectBestArticle(from: [existing, notification])
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
                            let keepThis = await self.selectBestArticle(from: [existing, notification])
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
                            let keepThis = await self.selectBestArticle(from: [existing, notification])
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
                                let best = await self.selectBestArticle(from: group)
                                let toRemove = group.filter { $0 !== best }

                                // Remove the duplicates
                                for dupe in toRemove {
                                    context.delete(dupe)
                                    emergencyRemovalCount += 1
                                }
                            }

                            if emergencyRemovalCount > 0 {
                                AppLogger.app.debug("Emergency cleanup: removed \(emergencyRemovalCount) remaining duplicates")
                            }
                        }
                    }

                    let totalRemoved = duplicatesToRemove.count + jsonUrlDuplicatesToRemove.count +
                        articleUrlDuplicatesToRemove.count

                    if totalRemoved > 0 {
                        AppLogger.app.info("✅ Removing \(totalRemoved) total duplicates")
                    } else {
                        AppLogger.app.info("No duplicates found to remove.")
                    }
                }

                // Update badge count after transaction completes
                await MainActor.run {
                    NotificationUtils.updateAppBadgeCount()
                }

            } catch {
                AppLogger.app.error("Error removing duplicates: \(error)")
            }

            // Reset flag when done
            isDuplicateRemovalRunning = false
        }
    }

    private func selectBestArticle(from articles: [NotificationData]) -> NotificationData {
        return articles.sorted { a, b in
            if a.isBookmarked != b.isBookmarked {
                return a.isBookmarked
            }
            if a.isViewed != b.isViewed {
                return !a.isViewed
            }
            let aHasAnalysis = a.sources_quality != nil || a.argument_quality != nil ||
                a.source_type != nil || a.quality != nil
            let bHasAnalysis = b.sources_quality != nil || b.argument_quality != nil ||
                b.source_type != nil || b.quality != nil

            if aHasAnalysis != bHasAnalysis {
                return aHasAnalysis
            }
            let aHasRichText = a.title_blob != nil || a.body_blob != nil
            let bHasRichText = b.title_blob != nil || b.body_blob != nil

            if aHasRichText != bHasRichText {
                return aHasRichText
            }
            let aContentLength = a.title.count + a.body.count
            let bContentLength = b.title.count + b.body.count

            if aContentLength != bContentLength {
                return aContentLength > bContentLength
            }
            return (a.pub_date ?? a.date) > (b.pub_date ?? b.date)
        }.first!
    }

    @MainActor
    func removeNotificationIfExists(jsonURL: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
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

    private func checkAndResumeMigration() {
        // Check if migration was in progress
        guard let data = UserDefaults.standard.data(forKey: "migrationProgress"),
              let progress = try? JSONDecoder().decode(MigrationProgress.self, from: data),
              progress.state == .inProgress
        else {
            return
        }

        // If migration was in progress, notify the user it will resume
        let notification = UNMutableNotificationContent()
        notification.title = "Data Migration"
        notification.body = "Your data migration was interrupted and will resume when you open the app."
        notification.sound = .default

        let request = UNNotificationRequest(
            identifier: "migration-resume",
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)

        // The actual resumption will happen in the MigrationView when it appears
        AppLogger.app.info("Data migration needs to be resumed - will continue in MigrationView")
    }

    private func setupTestDataIfNeeded() {
        guard
            isRunningUITests,
            ProcessInfo.processInfo.environment["SETUP_TEST_DATA"] == "1"
        else {
            return
        }

        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            let existingCount = try context.fetchCount(FetchDescriptor<NotificationData>())
            if existingCount > 0 {
                AppLogger.app.debug("UI Tests: Using \(existingCount) existing notifications for testing")
                return
            }

            AppLogger.app.debug("UI Tests: Creating test notification data")

            let testNotification = NotificationData(
                id: UUID(),
                date: Date(),
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

            testNotification.summary = "This is a summary of the test article."
            testNotification.critical_analysis = "This is a critical analysis of the article."
            testNotification.logical_fallacies = "The article contains some logical fallacies."
            testNotification.source_analysis = "The source appears to be reputable."
            testNotification.relation_to_topic = "This article is highly relevant to the topic."
            testNotification.additional_insights = "Here are some additional contextual insights."
            testNotification.source_type = "News"
            testNotification.sources_quality = 3
            testNotification.argument_quality = 4

            context.insert(testNotification)
            try context.save()

            AppLogger.app.debug("UI Tests: Test data created successfully")
        } catch {
            AppLogger.app.error("UI Tests: Error setting up test data: \(error)")
        }
    }
}

// Array chunking is now defined in ArrayExtensions.swift

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

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if
                let data = userInfo["data"] as? [String: AnyObject],
                let jsonURL = data["json_url"] as? String
            {
                DispatchQueue.main.async {
                    self.presentArticle(jsonURL: jsonURL)
                }
            }
        }

        completionHandler()
    }

    private func presentArticle(jsonURL: String) {
        let context = ArgusApp.sharedModelContainer.mainContext
        guard let notification = try? context.fetch(
            FetchDescriptor<NotificationData>(predicate: #Predicate { $0.json_url == jsonURL })
        ).first else {
            AppLogger.app.error("No matching NotificationData found for json_url=\(jsonURL)")
            return
        }

        guard
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first,
            let rootVC = window.rootViewController
        else {
            return
        }

        if let presented = rootVC.presentedViewController {
            presented.dismiss(animated: false)
        }

        // Create a view model with the appropriate parameters
        let viewModel = NewsDetailViewModel(
            articles: [notification],
            allArticles: [notification],
            currentIndex: 0,
            initiallyExpandedSection: "Summary"
        )

        // Use the new initializer with the viewModel
        let detailView = NewsDetailView(viewModel: viewModel)
            .environment(\.modelContext, context)

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen
        rootVC.present(hostingController, animated: true, completion: nil)
    }
}
