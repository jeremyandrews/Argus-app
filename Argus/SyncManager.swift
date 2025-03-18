import BackgroundTasks
import Foundation
import Network
import SwiftData
import UIKit

class SyncManager {
    static let shared = SyncManager()

    // Background task identifier
    private let backgroundSyncIdentifier = "com.arguspulse.articlesync"
    private let backgroundFetchIdentifier = "com.arguspulse.articlefetch"

    // Throttling parameters
    private var syncInProgress = false
    private let manualSyncThrottle: TimeInterval = 30
    private var lastManualSyncTime = Date.distantPast

    // Notification names for app state changes
    private let notificationCenter = NotificationCenter.default

    // Network type enum
    private enum NetworkType {
        case wifi
        case cellular
        case other
        case unknown
    }

    // Initialize and register for app lifecycle notifications
    private init() {
        // Register for app lifecycle notifications on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // App will enter foreground
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )

            // App did enter background
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )

            // App did become active
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    // Called when app comes to foreground
    @objc private func appWillEnterForeground() {
        // Schedule a sync after a short delay to ensure network is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task {
                let networkReady = await self.shouldAllowSync()
                if networkReady {
                    AppLogger.sync.debug("Network is ready - triggering foreground sync")
                    await self.sendRecentArticlesToServer()
                } else {
                    AppLogger.sync.error("Network not ready for sync")
                }
            }
        }
    }

    // Called when app becomes active
    @objc private func appDidBecomeActive() {
        AppLogger.sync.debug("App did become active")
        // Process queued items much later to ensure UI is highly responsive
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.startQueueProcessing()
        }
    }

    func startQueueProcessing() {
        // Process queue with lowest priority, ensuring UI stays responsive
        Task.detached(priority: .background) {
            let hasMoreItems = await self.processQueueItems()
            // Schedule background fetch - let the system determine the best time
            await MainActor.run {
                self.scheduleBackgroundFetch()
                // Only if we know there are pending items, we can request expedited processing
                if hasMoreItems {
                    self.requestExpediteBackgroundProcessing()
                }
            }
        }
    }

    // Called when app enters background
    @objc private func appDidEnterBackground() {
        AppLogger.sync.debug("App did enter background - scheduling background tasks")
        scheduleBackgroundSync()
        scheduleBackgroundFetch()
    }

    // Check network condition only when needed - one-time check instead of monitoring
    private func getCurrentNetworkType() async -> NetworkType {
        return await withCheckedContinuation { continuation in
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { path in
                defer {
                    pathMonitor.cancel()
                }

                if path.usesInterfaceType(.wifi) {
                    continuation.resume(returning: .wifi)
                } else if path.usesInterfaceType(.cellular) {
                    continuation.resume(returning: .cellular)
                } else if path.status == .satisfied {
                    continuation.resume(returning: .other)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
            pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    // Check if we should sync based on network type and settings
    private func shouldAllowSync() async -> Bool {
        let networkType = await getCurrentNetworkType()
        switch networkType {
        case .wifi:
            return true
        case .cellular, .other, .unknown:
            return UserDefaults.standard.bool(forKey: "allowCellularSync")
        }
    }

    // Process queue items with a hard 10-second time limit
    private func processQueueItems() async -> Bool {
        let timeLimit = 10.0 // Always limit to 10 seconds
        let startTime = Date()
        var processedCount = 0
        var hasMoreItems = false
        AppLogger.sync.debug("Processing queue items (max \(timeLimit) seconds)")
        do {
            let container = await MainActor.run {
                ArgusApp.sharedModelContainer
            }
            let backgroundContext = ModelContext(container)
            let queueManager = backgroundContext.queueManager()

            // Process items until we hit the time limit or run out of items
            while Date().timeIntervalSince(startTime) < timeLimit {
                // Get a batch of items to process
                let itemsToProcess = try await queueManager.getItemsToProcess(limit: 5)
                if itemsToProcess.isEmpty {
                    break // No more items to process
                }
                AppLogger.sync.debug("Processing batch of \(itemsToProcess.count) queue items")
                var processedItems = [ArticleQueueItem]()

                for item in itemsToProcess {
                    if Task.isCancelled {
                        break
                    }
                    // Check if we've exceeded the time limit
                    if Date().timeIntervalSince(startTime) >= timeLimit {
                        break
                    }

                    // Check if this article is already in the database
                    // This is a critical check to prevent duplicates
                    if await isArticleAlreadyProcessed(jsonURL: item.jsonURL, context: backgroundContext) {
                        AppLogger.sync.debug("Skipping already processed article: \(item.jsonURL)")
                        processedItems.append(item) // Mark as processed so it gets removed
                        continue
                    }

                    do {
                        try await processQueueItem(item, context: backgroundContext)
                        processedItems.append(item)
                        processedCount += 1
                    } catch {
                        AppLogger.sync.error("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                    }
                }

                if !processedItems.isEmpty {
                    try backgroundContext.save()
                    for item in processedItems {
                        try queueManager.removeItem(item)
                    }
                    AppLogger.sync.debug("Successfully processed and saved batch of \(processedItems.count) items")
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                }
            }

            let timeElapsed = Date().timeIntervalSince(startTime)
            AppLogger.sync.debug("Queue processing completed: \(processedCount) items in \(String(format: "%.2f", timeElapsed)) seconds")

            // If we processed items and there might be more, schedule another processing run soon
            if processedCount > 0 {
                let remainingCount = try await queueManager.queueCount()
                if remainingCount > 0 {
                    // We have more items, but we'll let the background task system handle it
                    await MainActor.run {
                        // Signal the system that we'd like to process more items soon
                        scheduleBackgroundFetch()
                    }
                    AppLogger.sync.debug("More items remaining (\(remainingCount)). Background task scheduled.")
                }
            }

            let remainingCount = try await queueManager.queueCount()
            hasMoreItems = remainingCount > 0

            // Return the state
            return hasMoreItems
        } catch {
            AppLogger.sync.error("Queue processing error: \(error.localizedDescription)")
            return false
        }
    }

    // Helper method to check if an article is already processed
    private func isArticleAlreadyProcessed(jsonURL: String, context: ModelContext) async -> Bool {
        // Check in NotificationData
        let notificationFetchRequest = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { notification in
                notification.json_url == jsonURL
            }
        )

        // Check in SeenArticle
        let seenFetchRequest = FetchDescriptor<SeenArticle>(
            predicate: #Predicate<SeenArticle> { seen in
                seen.json_url == jsonURL
            }
        )

        // Execute both fetch requests directly - no need for async let and tasks
        let isNotificationPresent = (try? context.fetch(notificationFetchRequest).first) != nil
        let isSeenPresent = (try? context.fetch(seenFetchRequest).first) != nil

        // Return true if the article exists in either table
        return isNotificationPresent || isSeenPresent
    }

    func registerBackgroundTasks() {
        // Register article fetch task (for processing queue)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundFetchIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }

            let processingTask = Task {
                // First check if the current network state meets the user's requirements
                let networkAllowed = await self.shouldAllowSync()

                if networkAllowed {
                    let didProcess = await self.processQueueItems()
                    appRefreshTask.setTaskCompleted(success: didProcess)
                } else {
                    AppLogger.sync.debug("Background fetch skipped - cellular not allowed by user")
                    appRefreshTask.setTaskCompleted(success: false)
                }
            }

            // Let the system handle task expiration
            appRefreshTask.expirationHandler = {
                processingTask.cancel()
                AppLogger.sync.debug("Background fetch task expired and was cancelled by the system")
            }

            self.scheduleBackgroundFetch()
        }

        // Register the sync task (for syncing with server)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }

            let syncTask = Task {
                // Check network conditions
                let networkAllowed = await self.shouldAllowSync()

                if networkAllowed {
                    await self.sendRecentArticlesToServer()
                    processingTask.setTaskCompleted(success: true)
                } else {
                    AppLogger.sync.debug("Background sync skipped - cellular not allowed by user")
                    processingTask.setTaskCompleted(success: false)
                }
            }

            // Let the system handle task expiration
            processingTask.expirationHandler = {
                syncTask.cancel()
                AppLogger.sync.debug("Background sync task expired and was cancelled by the system")
            }

            self.scheduleBackgroundSync()
        }

        // Schedule initial tasks
        scheduleBackgroundFetch()
        scheduleBackgroundSync()
        AppLogger.sync.debug("Background tasks registered: fetch and sync")
    }

    func scheduleBackgroundFetch() {
        let request = BGProcessingTaskRequest(identifier: backgroundFetchIdentifier)

        // Require network connectivity
        request.requiresNetworkConnectivity = true

        // Only set whether cellular is allowed based on user preferences
        // This allows the system to be smarter about when to schedule the task
        let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")
        request.requiresExternalPower = false

        // Only set a minimum delay, not a fixed schedule
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 5) // 5 minutes minimum

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background fetch scheduled with system optimization (cellular allowed: \(allowCellular))")
        } catch {
            AppLogger.sync.error("Could not schedule background fetch: \(error)")
        }
    }

    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: backgroundSyncIdentifier)

        // Always require network connectivity
        request.requiresNetworkConnectivity = true

        // Set whether cellular is allowed based on user preferences
        let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")

        // No charging requirement in your app's settings
        request.requiresExternalPower = false

        // Use a reasonable minimum delay (30 minutes)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1800)

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background sync scheduled with system optimization (cellular allowed: \(allowCellular))")
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                AppLogger.sync.error("Background sync not permitted: \(error)")
            case .tooManyPendingTaskRequests:
                AppLogger.sync.error("Too many pending background sync tasks: \(error)")
            case .unavailable:
                AppLogger.sync.error("Background sync unavailable: \(error)")
            @unknown default:
                AppLogger.sync.error("Unknown background sync scheduling error: \(error)")
            }
        } catch {
            AppLogger.sync.error("Could not schedule background sync: \(error)")
        }
    }

    func requestExpediteBackgroundProcessing() {
        // Request expedited processing only if truly needed
        let request = BGProcessingTaskRequest(identifier: backgroundFetchIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Consider user cellular preferences
        let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")

        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // Minimum 1 minute
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Expedited processing scheduled (cellular allowed: \(allowCellular))")
        } catch {
            AppLogger.sync.error("Could not schedule expedited processing: \(error)")
        }
    }

    // MARK: - Sync Methods

    // Simplified manual sync method
    func manualSync() async -> Bool {
        // Only throttle explicit user actions
        let now = Date()
        guard now.timeIntervalSince(lastManualSyncTime) > manualSyncThrottle else {
            AppLogger.sync.debug("Manual sync requested too soon")
            return false
        }

        lastManualSyncTime = now
        await sendRecentArticlesToServer()
        return true
    }

    func sendRecentArticlesToServer() async {
        // Simple guard against concurrent execution
        guard !syncInProgress else {
            AppLogger.sync.debug("Sync already in progress, skipping")
            return
        }

        // Check network conditions before proceeding
        guard await shouldAllowSync() else {
            AppLogger.sync.debug("Sync skipped due to network conditions and user preferences")
            return
        }

        // Set flag to prevent concurrent execution
        syncInProgress = true
        defer {
            syncInProgress = false
            // Update last sync time only for throttling manual actions
            lastManualSyncTime = Date()
        }

        AppLogger.sync.debug("Starting server sync...")

        do {
            let recentArticles = await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            // APIClient handles timeouts internally
            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            let payload = ["seen_articles": jsonUrls]

            do {
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)

                if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty {
                    AppLogger.sync.debug("Server returned \(unseenUrls.count) unseen articles - queuing for processing")
                    await queueArticlesForProcessing(urls: unseenUrls)

                    // Start processing immediately if we received new articles
                    startQueueProcessing()
                } else {
                    AppLogger.sync.debug("Server says there are no unseen articles.")
                }
            } catch let error as URLError where error.code == .timedOut {
                AppLogger.sync.error("Sync operation timed out")
            }
        } catch {
            AppLogger.sync.error("Failed to sync articles: \(error)")
        }

        // Always schedule next background sync
        await MainActor.run {
            self.scheduleBackgroundSync()
        }
    }

    // For explicit queue processing with feedback (e.g. from UI)
    func processQueue() async -> Bool {
        return await processQueueItems()
    }

    private func processQueueItem(_ item: ArticleQueueItem, context: ModelContext) async throws {
        let itemJsonURL = item.jsonURL

        // Double-check that we're not creating duplicates
        // This is important as the queue might have been processed already in another context
        if await isArticleAlreadyProcessed(jsonURL: itemJsonURL, context: context) {
            AppLogger.sync.debug("[Warning] Skipping already processed article: \(itemJsonURL)")
            return
        }

        guard let url = URL(string: item.jsonURL) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON URL: \(item.jsonURL)",
            ])
        }

        // Fetch with timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        let (data, _) = try await session.data(from: url)

        guard let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON data in response",
            ])
        }

        var enrichedJson = rawJson
        if enrichedJson["json_url"] == nil {
            enrichedJson["json_url"] = item.jsonURL
        }

        guard let articleJSON = processArticleJSON(enrichedJson) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Failed to process article JSON",
            ])
        }

        // Create engine stats JSON string if the required fields are present in the raw JSON
        var engineStatsJSON: String?
        var engineStatsDict: [String: Any] = [:]

        if let model = enrichedJson["model"] as? String {
            engineStatsDict["model"] = model
        }

        if let elapsedTime = enrichedJson["elapsed_time"] as? Double {
            engineStatsDict["elapsed_time"] = elapsedTime
        }

        if let stats = enrichedJson["stats"] as? String {
            engineStatsDict["stats"] = stats
        }

        if let systemInfo = enrichedJson["system_info"] as? [String: Any] {
            engineStatsDict["system_info"] = systemInfo
        }

        // Only create the JSON if we have some data to include
        if !engineStatsDict.isEmpty {
            if let jsonData = try? JSONSerialization.data(withJSONObject: engineStatsDict),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                engineStatsJSON = jsonString
            }
        }

        // Create similar articles JSON string if available in the raw JSON
        var similarArticlesJSON: String?
        if let similarArticles = enrichedJson["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty {
            if let jsonData = try? JSONSerialization.data(withJSONObject: similarArticles),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                similarArticlesJSON = jsonString
            }
        }

        let date = Date()
        let notificationID = item.notificationID ?? UUID()
        if item.notificationID == nil {
            item.notificationID = notificationID
        }

        // Create NotificationData instance with article_url
        let notification = NotificationData(
            id: notificationID,
            date: date,
            title: articleJSON.title,
            body: articleJSON.body,
            json_url: articleJSON.jsonURL,
            article_url: articleJSON.url, // Use the URL field from articleJSON
            topic: articleJSON.topic,
            article_title: articleJSON.articleTitle,
            affected: articleJSON.affected,
            domain: articleJSON.domain,
            pub_date: articleJSON.pubDate ?? date,
            isViewed: false,
            isBookmarked: false,
            isArchived: false,
            sources_quality: articleJSON.sourcesQuality,
            argument_quality: articleJSON.argumentQuality,
            source_type: articleJSON.sourceType,
            source_analysis: articleJSON.sourceAnalysis,
            quality: articleJSON.quality,
            summary: articleJSON.summary,
            critical_analysis: articleJSON.criticalAnalysis,
            logical_fallacies: articleJSON.logicalFallacies,
            relation_to_topic: articleJSON.relationToTopic,
            additional_insights: articleJSON.additionalInsights,
            engine_stats: engineStatsJSON,
            similar_articles: similarArticlesJSON
        )

        // Create SeenArticle record
        let seenArticle = SeenArticle(
            id: notificationID,
            json_url: articleJSON.jsonURL,
            date: date
        )

        // Insert both the notification and SeenArticle in a transaction to ensure atomicity
        try context.transaction {
            context.insert(notification)
            context.insert(seenArticle)
            _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
            _ = getAttributedString(for: .body, from: notification, createIfMissing: true)
        }

        // Save immediately to prevent race conditions
        try context.save()
    }

    private func fetchRecentArticles() async -> [SeenArticle] {
        await MainActor.run {
            let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
            let context = ArgusApp.sharedModelContainer.mainContext
            return (try? context.fetch(FetchDescriptor<SeenArticle>(
                predicate: #Predicate { $0.date >= oneDayAgo }
            ))) ?? []
        }
    }

    func queueArticlesForProcessing(urls: [String]) async {
        // Get the model container on the main actor
        let container = await MainActor.run {
            ArgusApp.sharedModelContainer
        }

        // Create a background context
        let backgroundContext = ModelContext(container)
        let queueManager = backgroundContext.queueManager()

        // Prepare for batch checking
        var newUrls = [String]()

        // First check which articles need to be queued (not already in system)
        for jsonURL in urls {
            if !(await isArticleAlreadyProcessed(jsonURL: jsonURL, context: backgroundContext)) {
                newUrls.append(jsonURL)
            } else {
                AppLogger.sync.debug("Skipping already processed article: \(jsonURL)")
            }
        }

        // Only queue articles that aren't already processed
        if newUrls.isEmpty {
            AppLogger.sync.debug("No new articles to queue - all are already processed")
            return
        }

        // Process each new URL
        for jsonURL in newUrls {
            do {
                let added = try await queueManager.addArticle(jsonURL: jsonURL)
                if added {
                    AppLogger.sync.debug("Queued article: \(jsonURL)")
                } else {
                    AppLogger.sync.debug("Skipped duplicate article: \(jsonURL)")
                }
            } catch {
                AppLogger.sync.error("Failed to queue article \(jsonURL): \(error)")
            }
        }

        AppLogger.sync.debug("Added \(newUrls.count) new articles to processing queue")
    }
}
