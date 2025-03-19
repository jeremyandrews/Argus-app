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

        // Use shorter time limit if user is active to avoid UI lag
        let timeLimit = appActive ? 3.0 : 10.0

        let startTime = Date()
        var processedCount = 0
        var hasMoreItems = false

        AppLogger.sync.debug("Processing queue items (max \(timeLimit) seconds, app \(appActive ? "active" : "inactive"))")

        // Get the model container on the main actor
        let container = await MainActor.run {
            ArgusApp.sharedModelContainer
        }

        // Use Task.detached to ensure we're off the main thread
        return await Task.detached {
            let backgroundContext = ModelContext(container)
            let queueManager = backgroundContext.queueManager()

            do {
                // Process items until we hit the time limit or run out of items
                while Date().timeIntervalSince(startTime) < timeLimit {
                    // Check if task was cancelled
                    if Task.isCancelled {
                        AppLogger.sync.debug("Queue processing cancelled")
                        break
                    }

                    // Get a batch of items to process - smaller batch in active mode
                    let batchSize = appActive ? 2 : 5
                    let itemsToProcess = try await queueManager.getItemsToProcess(limit: batchSize)

                    if itemsToProcess.isEmpty {
                        break // No more items to process
                    }

                    AppLogger.sync.debug("Processing batch of \(itemsToProcess.count) queue items")
                    var processedItems = [ArticleQueueItem]()

                    // Use a cooperative approach to check time more frequently when app is active
                    let timeCheckInterval = appActive ? 1 : 3
                    var itemsProcessedSinceTimeCheck = 0

                    for item in itemsToProcess {
                        if Task.isCancelled {
                            break
                        }

                        // More frequent time checks when app is active
                        itemsProcessedSinceTimeCheck += 1
                        if appActive && itemsProcessedSinceTimeCheck >= timeCheckInterval {
                            itemsProcessedSinceTimeCheck = 0
                            if Date().timeIntervalSince(startTime) >= timeLimit {
                                break
                            }
                        }

                        // Check if this article is already in the database
                        // This is a critical check to prevent duplicates
                        if await self.isArticleAlreadyProcessed(jsonURL: item.jsonURL, context: backgroundContext) {
                            AppLogger.sync.debug("Skipping already processed article: \(item.jsonURL)")
                            processedItems.append(item) // Mark as processed so it gets removed
                            continue
                        }

                        do {
                            // Use a lower timeout when app is active
                            try await self.processQueueItem(item, context: backgroundContext)
                            processedItems.append(item)
                            processedCount += 1
                        } catch {
                            AppLogger.sync.error("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                        }

                        // If app is active, yield to main thread more frequently
                        if appActive && processedCount % 2 == 0 {
                            try await Task.sleep(nanoseconds: 10_000_000) // 10ms pause
                        }
                    }

                    if !processedItems.isEmpty {
                        try backgroundContext.save()
                        for item in processedItems {
                            try queueManager.removeItem(item)
                        }
                        AppLogger.sync.debug("Successfully processed and saved batch of \(processedItems.count) items")

                        // Update badge count if we processed any items
                        if processedCount > 0 {
                            await MainActor.run {
                                NotificationUtils.updateAppBadgeCount()
                            }
                        }
                    }

                    // If app is active, yield after each batch
                    if appActive {
                        try await Task.sleep(nanoseconds: 20_000_000) // 20ms pause
                    }
                }

                let timeElapsed = Date().timeIntervalSince(startTime)
                AppLogger.sync.debug("Queue processing completed: \(processedCount) items in \(String(format: "%.2f", timeElapsed)) seconds")

                // Check if there are more items to process
                let remainingCount = try await queueManager.queueCount()
                hasMoreItems = remainingCount > 0

                // Update metrics for future scheduling decisions
                UserDefaults.standard.set(remainingCount, forKey: "currentQueueSize")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "queueSizeLastUpdate")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastQueueProcessingTime")

                if hasMoreItems {
                    await MainActor.run {
                        // Signal the system that we'd like to process more items
                        self.scheduleBackgroundFetch()
                    }
                    AppLogger.sync.debug("More items remaining (\(remainingCount)). Background task scheduled.")
                }

                return hasMoreItems
            } catch {
                AppLogger.sync.error("Error during queue processing: \(error)")
                return false
            }
        }.value
    }

    // Checks if an article has already been processed by looking for its URL in both
    // NotificationData and SeenArticle tables.
    // Prevents duplicate processing of the same article content.
    // Returns true if article exists in either table, false otherwise.
    func isArticleAlreadyProcessed(jsonURL: String, context: ModelContext) async -> Bool {
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
        let itemJsonURL = item.jsonURL

        // Double-check that we're not creating duplicates by using a fresh fetch
        // This is more reliable than using the cached check from earlier
        var notificationDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { $0.json_url == itemJsonURL }
        )
        notificationDescriptor.fetchLimit = 1

        var seenDescriptor = FetchDescriptor<SeenArticle>(
            predicate: #Predicate<SeenArticle> { $0.json_url == itemJsonURL }
        )
        seenDescriptor.fetchLimit = 1

        // Check BEFORE trying to insert - critical for avoiding duplicates
        if (try? context.fetch(notificationDescriptor).first) != nil ||
            (try? context.fetch(seenDescriptor).first) != nil
        {
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
