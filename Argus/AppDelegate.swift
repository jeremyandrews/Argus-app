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
            // Use ArticleModel instead of NotificationData to fix PersistentModel conformance issue
            let articles = try context.fetch(FetchDescriptor<ArticleModel>())

            for article in articles {
                // Change json_url to jsonURL to match SeenArticleModel initializer
                let seenArticle = SeenArticle(id: article.id, jsonURL: article.jsonURL, date: article.date)
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
        // Use the correct parameter name for the SeenArticle initializer
        let seenArticle = SeenArticle(id: id, jsonURL: json_url, date: date)

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
                    // Use ArticleModel instead of NotificationData for Swift 6 compliance
                    let articlesToDelete = try context.fetch(
                        FetchDescriptor<ArticleModel>(
                            predicate: #Predicate { article in
                                article.addedDate < cutoffDate &&
                                    !article.isBookmarked
                            }
                        )
                    )

                    guard !articlesToDelete.isEmpty else { return } // No old articles

                    // Delete all fetched articles in a batch
                    for article in articlesToDelete {
                        context.delete(article)
                    }

                    AppLogger.app.debug("Deleted \(articlesToDelete.count) old articles")
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

        // Delegate to ArticleService which has the modern implementation
        // that works with ArticleModel instead of NotificationData
        Task {
            do {
                let removedCount = try await ArticleService.shared.removeDuplicateArticles()
                
                if removedCount > 0 {
                    AppLogger.app.info("✅ Removed \(removedCount) duplicate articles")
                    
                    // Update badge count after cleanup
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                } else {
                    AppLogger.app.info("No duplicate articles found to remove.")
                }
            } catch {
                AppLogger.app.error("Error removing duplicates: \(error)")
            }
            
            // Reset flag when done
            isDuplicateRemovalRunning = false
        }
    }
    
    // Helper function to select best article is no longer needed as
    // ArticleService handles this internally with its own implementation

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
            // Use ArticleModel instead of NotificationData for Swift 6 compliance
            let existingCount = try context.fetchCount(FetchDescriptor<ArticleModel>())
            if existingCount > 0 {
                AppLogger.app.debug("UI Tests: Using \(existingCount) existing articles for testing")
                return
            }

            AppLogger.app.debug("UI Tests: Creating test article data")

            // Create an ArticleModel instead of NotificationData
            let testArticle = ArticleModel(
                id: UUID(),
                jsonURL: "https://example.com/test.json",
                url: "https://example.com/test-article",
                title: "Test Article Title for UI Tests",
                body: "This is a test article body with enough content to display properly in our UI tests.",
                domain: "example.com",
                articleTitle: "Test Article Title for UI Tests",
                affected: "",
                publishDate: Date(),
                addedDate: Date(),
                topic: "Technology",
                isViewed: false,
                isBookmarked: true,
                sourcesQuality: 3,
                argumentQuality: 4,
                sourceType: "News",
                sourceAnalysis: "The source appears to be reputable.",
                quality: 3,
                summary: "This is a summary of the test article.",
                criticalAnalysis: "This is a critical analysis of the article.",
                logicalFallacies: "The article contains some logical fallacies.",
                relationToTopic: "This article is highly relevant to the topic.",
                additionalInsights: "Here are some additional contextual insights.",
                engineStats: nil,
                similarArticles: nil
            )

            context.insert(testArticle)
            try context.save()

            AppLogger.app.debug("UI Tests: Test article data created successfully")
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
        // Use ArticleModel instead of NotificationData for Swift 6 compliance
        guard let article = try? context.fetch(
            FetchDescriptor<ArticleModel>(predicate: #Predicate { $0.jsonURL == jsonURL })
        ).first else {
            AppLogger.app.error("No matching ArticleModel found for jsonURL=\(jsonURL)")
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
            articles: [article],
            allArticles: [article],
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
