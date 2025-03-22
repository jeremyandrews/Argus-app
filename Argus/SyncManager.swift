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

    // Initializes the SyncManager singleton and registers for app lifecycle notifications.
    // Sets up observers for foreground, background, and active state transitions
    // to ensure sync operations happen at appropriate times.
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

    // Cleans up by removing all notification observers when the SyncManager is deallocated.
    deinit {
        notificationCenter.removeObserver(self)
    }

    // Handles app returning to foreground by triggering a sync operation after a short delay.
    // The delay ensures that network connectivity is established before attempting to sync.
    // Only proceeds with sync if the network conditions meet user preferences.
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

    // Responds to the app becoming active by scheduling queue processing with a delay.
    // The delay ensures UI responsiveness during app launch/resume by deferring background work.
    @objc private func appDidBecomeActive() {
        AppLogger.sync.debug("App did become active")
        // Process queued items much later to ensure UI is highly responsive
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.startQueueProcessing()
        }
    }

    // Initiates background processing of the article queue with lowest priority.
    // Ensures UI remains responsive by using background priority for the task.
    // Schedules further background processing if more items remain in the queue.
    // May request expedited processing for pending items.
    func startQueueProcessing() {
        // Queue the entire operation on a background thread
        Task.detached(priority: .utility) {
            // First check if the current network state meets requirements
            let networkAllowed = await self.shouldAllowSync()

            if !networkAllowed {
                AppLogger.sync.debug("Queue processing skipped - network conditions not suitable")
                return
            }

            AppLogger.sync.debug("Beginning queue processing in background")
            let hasMoreItems = await self.processQueueItems()

            // Schedule follow-up tasks appropriately
            await MainActor.run {
                self.scheduleBackgroundFetch()
                if hasMoreItems {
                    self.requestExpediteBackgroundProcessing()
                }
            }
        }
    }

    // Prepares for app entering background state by scheduling background tasks.
    // Ensures both sync and fetch operations will continue even when app is not active.
    @objc private func appDidEnterBackground() {
        AppLogger.sync.debug("App did enter background - scheduling background tasks")
        scheduleBackgroundSync()
        scheduleBackgroundFetch()
    }

    // Performs a one-time check of the current network connectivity type.
    // Returns an enum value indicating wifi, cellular, or other connectivity status.
    // Uses continuation to make the NWPathMonitor callback-based API compatible with async/await.
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

    // Determines if sync should be allowed based on current network conditions and user preferences.
    // Returns true if on WiFi or if cellular sync is explicitly allowed by user settings.
    // Used as a gatekeeper before initiating any network operations.
    private func shouldAllowSync() async -> Bool {
        let networkType = await getCurrentNetworkType()
        switch networkType {
        case .wifi:
            return true
        case .cellular, .other, .unknown:
            return UserDefaults.standard.bool(forKey: "allowCellularSync")
        }
    }

    // Processes pending items in the article queue within time constraints.
    // Adjusts processing behavior based on whether the app is active or in background.
    // Uses cooperative time-checking to ensure UI responsiveness when app is active.
    // Avoids processing duplicate articles through explicit duplicate checking.
    // Updates metrics and schedules follow-up tasks if needed.
    // Returns whether more items remain in the queue.
    private func processQueueItems() async -> Bool {
        // Check if app is in foreground - if so, use shorter time limit
        let appActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }

        // Get the model container on the main actor
        let container = await MainActor.run {
            ArgusApp.sharedModelContainer
        }

        AppLogger.sync.debug("Starting queue processing (app \(appActive ? "active" : "inactive"))")

        return await Task.detached {
            let backgroundContext = ModelContext(container)
            let queueManager = backgroundContext.queueManager()

            do {
                // Get total queue count for progress tracking
                let totalQueueCount = try await queueManager.queueCount()
                if totalQueueCount == 0 {
                    return false // No items to process
                }

                AppLogger.sync.debug("Found \(totalQueueCount) items in queue")

                // Process in batches of 25 (or fewer if active)
                let batchSize = appActive ? 15 : 25
                var processedCount = 0

                // First fetch all items we'll process in this batch
                let itemsToProcess = try await queueManager.getItemsToProcess(limit: batchSize)
                if itemsToProcess.isEmpty {
                    return false
                }

                // Track processed URLs to avoid duplicates within this batch
                var processedURLsInBatch = Set<String>()
                var successfullyProcessedItems = [ArticleQueueItem]()
                var failedItems = [ArticleQueueItem]()

                // PRE-CHECK: First identify duplicates in database (do this in batch for better performance)
                var urlsToProcess = [String]()
                for item in itemsToProcess {
                    urlsToProcess.append(item.jsonURL)
                }

                // Do batch duplicate checking - get all existing articles in one query
                let existingArticlesSet = try await self.getExistingArticles(jsonURLs: urlsToProcess, context: backgroundContext)

                // Process each unique item in the batch
                for item in itemsToProcess {
                    // Skip if this URL is already in the database
                    if existingArticlesSet.contains(item.jsonURL) {
                        AppLogger.sync.debug("Skipping duplicate article: \(item.jsonURL)")
                        successfullyProcessedItems.append(item) // Mark as processed so we remove it
                        continue
                    }

                    // Skip if we've already processed this URL in the current batch
                    if processedURLsInBatch.contains(item.jsonURL) {
                        AppLogger.sync.debug("Skipping duplicate in current batch: \(item.jsonURL)")
                        successfullyProcessedItems.append(item)
                        continue
                    }

                    do {
                        try await self.processQueueItem(item, context: backgroundContext)
                        successfullyProcessedItems.append(item)
                        processedURLsInBatch.insert(item.jsonURL)
                        processedCount += 1
                    } catch {
                        AppLogger.sync.error("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                        failedItems.append(item)
                    }
                }

                // Batch save successful items (by removing them from the queue)
                if !successfullyProcessedItems.isEmpty {
                    try backgroundContext.save()

                    for item in successfullyProcessedItems {
                        try queueManager.removeItem(item)
                    }

                    AppLogger.sync.debug("Successfully processed \(processedCount) articles")
                }

                // Update badge count on main thread if needed
                if processedCount > 0 {
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                }

                // Check if there are more items
                let remainingCount = try await queueManager.queueCount()
                let hasMoreItems = remainingCount > 0

                // Update metrics
                UserDefaults.standard.set(remainingCount, forKey: "currentQueueSize")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "queueSizeLastUpdate")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastQueueProcessingTime")

                if hasMoreItems {
                    AppLogger.sync.debug("More items remaining (\(remainingCount))")
                }

                return hasMoreItems
            } catch {
                AppLogger.sync.error("Error during queue processing: \(error)")
                return false
            }
        }.value
    }

    // New helper method to check existing articles in batch
    private func getExistingArticles(jsonURLs: [String], context: ModelContext) async throws -> Set<String> {
        var result = Set<String>()

        // Check for already processed articles in one query
        let notificationDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { notification in
                jsonURLs.contains(notification.json_url)
            }
        )

        let seenDescriptor = FetchDescriptor<SeenArticle>(
            predicate: #Predicate<SeenArticle> { seen in
                jsonURLs.contains(seen.json_url)
            }
        )

        // Execute both queries and combine results
        let existingNotifications = try context.fetch(notificationDescriptor)
        for notification in existingNotifications {
            result.insert(notification.json_url)
        }

        let existingSeenArticles = try context.fetch(seenDescriptor)
        for seen in existingSeenArticles {
            result.insert(seen.json_url)
        }

        return result
    }

    // Checks if an article has already been processed by looking for its URL in both
    // NotificationData and SeenArticle tables.
    // Prevents duplicate processing of the same article content.
    // Returns true if article exists in either table, false otherwise.
    func isArticleAlreadyProcessed(jsonURL: String, context: ModelContext) async -> Bool {
        // Use a single combined query with fetchCount for better performance
        let notificationFetchDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { notification in
                notification.json_url == jsonURL
            }
        )

        // First check NotificationData - most direct and common case
        let notificationCount = (try? context.fetchCount(notificationFetchDescriptor)) ?? 0
        if notificationCount > 0 {
            return true
        }

        // Only if not found in NotificationData, check SeenArticle
        let seenFetchDescriptor = FetchDescriptor<SeenArticle>(
            predicate: #Predicate<SeenArticle> { seen in
                seen.json_url == jsonURL
            }
        )

        let seenCount = (try? context.fetchCount(seenFetchDescriptor)) ?? 0
        return seenCount > 0
    }

    // Registers the app's background tasks with the system for queue processing and server sync.
    // Sets up handlers for both BGAppRefreshTask (article fetch) and BGProcessingTask (sync).
    // Includes proper task cancellation handling and scheduling of follow-up tasks.
    // Schedules initial background tasks after registration.
    func registerBackgroundTasks() {
        // Register article fetch task (for processing queue)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundFetchIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }

            // Create a cancellable task
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

            // Handle task expiration cleanly
            appRefreshTask.expirationHandler = {
                processingTask.cancel()
                AppLogger.sync.debug("Background fetch task expired and was cancelled by the system")
            }

            // Schedule the next fetch after this completes
            Task {
                // Wait for the task to complete without throwing errors
                _ = await processingTask.value

                await MainActor.run {
                    self.scheduleBackgroundFetch()
                }
            }
        }

        // Register the sync task (for syncing with server)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }

            // Create a cancellable task
            let syncTask = Task {
                // Check network conditions before proceeding
                let networkAllowed = await self.shouldAllowSync()

                if networkAllowed {
                    await self.sendRecentArticlesToServer()
                    processingTask.setTaskCompleted(success: true)
                } else {
                    AppLogger.sync.debug("Background sync skipped - cellular not allowed by user")
                    processingTask.setTaskCompleted(success: false)
                }
            }

            // Handle task expiration cleanly
            processingTask.expirationHandler = {
                syncTask.cancel()
                AppLogger.sync.debug("Background sync task expired and was cancelled by the system")
            }

            // Schedule the next sync after this completes
            Task {
                // Wait for the task to complete without throwing errors
                _ = await syncTask.value

                await MainActor.run {
                    self.scheduleBackgroundSync()
                }
            }
        }

        // Schedule initial tasks - let the system determine when to run them
        scheduleBackgroundFetch()
        scheduleBackgroundSync()
        AppLogger.sync.debug("Background tasks registered: fetch and sync")
    }

    // Schedules a background app refresh task for processing the article queue.
    // Dynamically adjusts scheduling delay based on recency of app usage.
    // Uses BGAppRefreshTaskRequest which has limited configuration options but can run
    // in more restrictive conditions than processing tasks.
    func scheduleBackgroundFetch() {
        // For app refresh tasks, we need to use BGAppRefreshTaskRequest
        let request = BGAppRefreshTaskRequest(identifier: backgroundFetchIdentifier)

        // BGAppRefreshTaskRequest doesn't have network connectivity or power requirements settings
        // We can only set the earliest begin date for this type of request

        // Adjust the delay based on app usage patterns - longer delay if user just used app
        let lastActiveTime = UserDefaults.standard.double(forKey: "lastAppActiveTimestamp")
        let currentTime = Date().timeIntervalSince1970
        let minutesSinceActive = (currentTime - lastActiveTime) / 60

        // More dynamic scheduling - if recently used, delay more
        let delayMinutes = minutesSinceActive < 30 ? 15 : 5
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * Double(delayMinutes))

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background fetch scheduled in approximately \(delayMinutes) minutes")
        } catch {
            AppLogger.sync.error("Could not schedule background fetch: \(error)")
        }
    }

    // Schedules a background processing task for syncing with the server.
    // Dynamically sets power requirements based on queue size and time since last processing.
    // Ensures sync will happen eventually even if optimal conditions aren't met after 24 hours.
    // Requires network connectivity but adapts power requirements based on needs.
    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: backgroundSyncIdentifier)
        request.requiresNetworkConnectivity = true

        // Get the cached queue size
        let queueSize = UserDefaults.standard.integer(forKey: "currentQueueSize")
        let lastQueueUpdateTime = UserDefaults.standard.double(forKey: "queueSizeLastUpdate")
        let currentTime = Date().timeIntervalSince1970

        // Only use queue size for power requirements if the data is recent (last 6 hours)
        if currentTime - lastQueueUpdateTime < 6 * 60 * 60 {
            // Require power for large queues
            request.requiresExternalPower = queueSize > 10
        } else {
            // If we don't have recent data, be conservative
            request.requiresExternalPower = false
        }

        // Add a timeout mechanism - if the queue hasn't been processed in 24 hours,
        // schedule it to run regardless of power state
        let lastProcessingTime = UserDefaults.standard.double(forKey: "lastQueueProcessingTime")
        if currentTime - lastProcessingTime > 24 * 60 * 60 {
            request.requiresExternalPower = false
        }

        // Schedule with appropriate timing
        request.earliestBeginDate = Date(timeIntervalSinceNow: queueSize > 10 ? 900 : 1800) // 15 or 30 mins

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background sync scheduled with power requirement: \(request.requiresExternalPower)")
        } catch {
            AppLogger.sync.error("Could not schedule background sync: \(error)")
        }
    }

    // Requests expedited background processing when needed.
    // Creates a minimal-requirements background task request to run as soon as possible.
    // Used when the system needs to process queue items with higher priority.
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

    // Initiates a user-requested manual sync operation with throttling protection.
    // Prevents excessive sync operations by enforcing a minimum time between manual syncs.
    // Returns a boolean indicating whether the sync was started or skipped due to throttling.
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

    // Syncs recent article history with the server and retrieves unseen articles.
    // Uses a flag to prevent concurrent execution of multiple sync operations.
    // Checks network conditions before proceeding.
    // Sends recently seen article URLs to the server and processes any unseen articles returned.
    // Schedules the next background sync regardless of operation outcome.
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

    // Public method to explicitly process the article queue, typically from UI actions.
    // Provides feedback about whether processing was completed and if more items remain.
    // Simply delegates to the main queue processing function.
    func processQueue() async -> Bool {
        return await processQueueItems()
    }

    // Processes a single article queue item by:
    // 1. Verifying it's not already processed
    // 2. Fetching the article JSON from the provided URL
    // 3. Processing the JSON into structured article data
    // 4. Extracting engine stats and similar articles if available
    // 5. Creating NotificationData and SeenArticle records in the database
    // 6. Generating and storing attributed strings for title and body
    // Uses transaction for atomicity and immediately saves to prevent race conditions.
    private func processQueueItem(_ item: ArticleQueueItem, context: ModelContext) async throws {
        guard let url = URL(string: item.jsonURL) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON URL: \(item.jsonURL)",
            ])
        }

        // Fetch with optimized timeout settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
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

        // Extract engine stats and similar articles JSON
        let engineStatsJSON = extractEngineStats(from: enrichedJson)
        let similarArticlesJSON = extractSimilarArticles(from: enrichedJson)

        let date = Date()
        let notificationID = item.notificationID ?? UUID()

        // Create NotificationData and SeenArticle in a single transaction
        let notification = NotificationData(
            id: notificationID,
            date: date,
            title: articleJSON.title,
            body: articleJSON.body,
            json_url: articleJSON.jsonURL,
            article_url: articleJSON.url,
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

        let seenArticle = SeenArticle(
            id: notificationID,
            json_url: articleJSON.jsonURL,
            date: date
        )

        // Insert both records in a single transaction
        try context.transaction {
            context.insert(notification)
            context.insert(seenArticle)

            // Pre-generate and store rich text (only for the most critical fields)
            _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
            _ = getAttributedString(for: .body, from: notification, createIfMissing: true)
        }
    }

    private func extractEngineStats(from json: [String: Any]) -> String? {
        var engineStatsDict: [String: Any] = [:]

        if let model = json["model"] as? String {
            engineStatsDict["model"] = model
        }

        if let elapsedTime = json["elapsed_time"] as? Double {
            engineStatsDict["elapsed_time"] = elapsedTime
        }

        if let stats = json["stats"] as? String {
            engineStatsDict["stats"] = stats
        }

        if let systemInfo = json["system_info"] as? [String: Any] {
            engineStatsDict["system_info"] = systemInfo
        }

        if engineStatsDict.isEmpty {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: engineStatsDict), encoding: .utf8)
    }

    private func extractSimilarArticles(from json: [String: Any]) -> String? {
        guard let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty else {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: similarArticles), encoding: .utf8)
    }

    // Retrieves article records from the last 24 hours.
    // Used to build the list of seen articles to send to the server during sync.
    // Executes on the main actor to access the shared model container.
    private func fetchRecentArticles() async -> [SeenArticle] {
        await MainActor.run {
            let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
            let context = ArgusApp.sharedModelContainer.mainContext
            return (try? context.fetch(FetchDescriptor<SeenArticle>(
                predicate: #Predicate { $0.date >= oneDayAgo }
            ))) ?? []
        }
    }

    // Adds articles to the processing queue that aren't already in the system.
    // Performs duplicate checking to avoid queuing already processed articles.
    // Takes an array of article JSON URLs and adds each to the queue if new.
    // Reports progress via logs.
    func queueArticlesForProcessing(urls: [String]) async {
        // Get the model container on the main actor
        let container = await MainActor.run {
            ArgusApp.sharedModelContainer
        }

        // Use Task.detached to ensure we're off the main thread
        await Task.detached {
            let backgroundContext = ModelContext(container)
            let queueManager = backgroundContext.queueManager()

            // Prepare for batch checking
            var newUrls = [String]()

            // First check which articles need to be queued (not already in system)
            for jsonURL in urls {
                if !(await self.isArticleAlreadyProcessed(jsonURL: jsonURL, context: backgroundContext)) {
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
        }.value
    }
}
