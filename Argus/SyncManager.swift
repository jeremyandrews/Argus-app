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
    private var syncInProgressTimestamp: Date?
    private var lastSyncTime: Date = .distantPast
    private let minimumSyncInterval: TimeInterval = 60
    private let syncTimeoutInterval: TimeInterval = 300 // 5 minutes timeout

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
        print("App will enter foreground - checking sync status")
        checkAndResetSyncIfStuck()

        // Schedule a sync after a short delay to ensure network is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task {
                let networkReady = await self.shouldAllowSync()
                if networkReady {
                    print("Network is ready - triggering foreground sync")
                    await self.triggerForegroundSync()
                } else {
                    print("Network not ready for sync")
                }
            }
        }
    }

    // Called when app becomes active
    @objc private func appDidBecomeActive() {
        print("App did become active")
        // Process queued items when app becomes active
        startQueueProcessing()
    }

    // Called when app enters background
    @objc private func appDidEnterBackground() {
        print("App did enter background - scheduling background tasks")
        scheduleBackgroundSync()
        scheduleBackgroundFetch()
    }

    // Check if sync is stuck and reset if necessary
    private func checkAndResetSyncIfStuck() {
        if syncInProgress,
           let timestamp = syncInProgressTimestamp,
           Date().timeIntervalSince(timestamp) > syncTimeoutInterval
        {
            print("Sync appears stuck (running > \(Int(syncTimeoutInterval)) seconds). Resetting status.")
            syncInProgress = false
            syncInProgressTimestamp = nil
        }
    }

    // Trigger a foreground sync with appropriate throttling
    private func triggerForegroundSync() async {
        // Shorter throttle for foreground syncs
        let now = Date()
        let foregroundSyncInterval: TimeInterval = 30 // 30 seconds for foreground

        if now.timeIntervalSince(lastSyncTime) > foregroundSyncInterval {
            print("Triggering foreground sync")
            await sendRecentArticlesToServer()
        } else {
            print("Foreground sync skipped - last sync was \(Int(now.timeIntervalSince(lastSyncTime))) seconds ago")
        }
    }

    // Check network condition only when needed
    private func getCurrentNetworkType() async -> NetworkType {
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                defer {
                    monitor.cancel()
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
            monitor.start(queue: DispatchQueue.global(qos: .utility))
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
        print("Processing queue items (max \(timeLimit) seconds)")
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
                print("Processing batch of \(itemsToProcess.count) queue items")
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
                        print("Skipping already processed article: \(item.jsonURL)")
                        processedItems.append(item) // Mark as processed so it gets removed
                        continue
                    }

                    do {
                        try await processQueueItem(item, context: backgroundContext)
                        processedItems.append(item)
                        processedCount += 1
                    } catch {
                        print("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                    }
                }

                if !processedItems.isEmpty {
                    try backgroundContext.save()
                    for item in processedItems {
                        try queueManager.removeItem(item)
                    }
                    print("Successfully processed and saved batch of \(processedItems.count) items")
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                }
            }

            let timeElapsed = Date().timeIntervalSince(startTime)
            print("Queue processing completed: \(processedCount) items in \(String(format: "%.2f", timeElapsed)) seconds")

            // If we processed items and there might be more, schedule another processing run soon
            if processedCount > 0 {
                let remainingCount = try await queueManager.queueCount()
                if remainingCount > 0 {
                    // We have more items, but we'll let the background task system handle it
                    await MainActor.run {
                        // Signal the system that we'd like to process more items soon
                        scheduleBackgroundFetch()
                    }
                    print("More items remaining (\(remainingCount)). Background task scheduled.")
                }
            }

            let remainingCount = try await queueManager.queueCount()
            hasMoreItems = remainingCount > 0

            // Return the state
            return hasMoreItems
        } catch {
            print("Queue processing error: \(error.localizedDescription)")
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
                let didProcess = await self.processQueueItems()
                appRefreshTask.setTaskCompleted(success: didProcess)
            }
            appRefreshTask.expirationHandler = {
                processingTask.cancel()
            }
            self.scheduleBackgroundFetch()
        }
        // Register the sync task (for syncing with server)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            let syncTask = Task {
                await self.sendRecentArticlesToServer()
                appRefreshTask.setTaskCompleted(success: true)
            }
            appRefreshTask.expirationHandler = {
                syncTask.cancel()
            }
            self.scheduleBackgroundSync()
        }
        // Schedule initial tasks
        scheduleBackgroundFetch()
        scheduleBackgroundSync()
        print("Background tasks registered: fetch and sync")
    }

    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundFetchIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background fetch scheduled")
        } catch {
            print("Could not schedule background fetch: \(error)")
        }
    }

    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundSyncIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // 30 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background sync scheduled")
        } catch {
            print("Could not schedule background sync: \(error)")
        }
    }

    func startQueueProcessing() {
        // Process queue once, then rely on scheduled background tasks
        Task.detached(priority: .utility) {
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

    func requestExpediteBackgroundProcessing() {
        // Request expedited processing only if truly needed
        let request = BGProcessingTaskRequest(identifier: backgroundFetchIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // Minimum 1 minute
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule expedited processing: \(error)")
        }
    }

    // MARK: - Sync Methods

    // Manual trigger with throttling - for UI "pull to refresh" or explicit user action
    func manualSync() async -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) > minimumSyncInterval else {
            print("Manual sync requested too soon (last sync was \(Int(now.timeIntervalSince(lastSyncTime))) seconds ago)")
            return false
        }
        await sendRecentArticlesToServer()
        return true
    }

    func sendRecentArticlesToServer() async {
        // Check for a stuck sync operation first
        checkAndResetSyncIfStuck()

        guard !syncInProgress else {
            print("Sync is already in progress. Skipping this call.")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) > minimumSyncInterval else {
            print("Sync throttled - last sync was \(Int(now.timeIntervalSince(lastSyncTime))) seconds ago")
            return
        }

        // Check network conditions before proceeding
        guard await shouldAllowSync() else {
            print("Sync skipped due to network conditions and user preferences")
            return
        }

        syncInProgress = true
        syncInProgressTimestamp = now // Record when sync started
        defer {
            syncInProgress = false
            syncInProgressTimestamp = nil
        }

        lastSyncTime = now
        print("Starting server sync...")

        do {
            let recentArticles = await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            // APIClient handles timeouts internally
            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            let payload = ["seen_articles": jsonUrls]

            do {
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)

                if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty { print("Server returned \(unseenUrls.count) unseen articles - queuing for processing")
                    await queueArticlesForProcessing(urls: unseenUrls)

                    // Start processing immediately if we received new articles
                    startQueueProcessing()
                } else {
                    print("Server says there are no unseen articles.")
                }
            } catch let error as URLError where error.code == .timedOut {
                print("Sync operation timed out")
            }
        } catch {
            print("Failed to sync articles: \(error)")
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
            print("[Warning] Skipping already processed article: \(itemJsonURL)")
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
                print("Skipping already processed article: \(jsonURL)")
            }
        }

        // Only queue articles that aren't already processed
        if newUrls.isEmpty {
            print("No new articles to queue - all are already processed")
            return
        }

        // Process each new URL
        for jsonURL in newUrls {
            do {
                let added = try await queueManager.addArticle(jsonURL: jsonURL)
                if added {
                    print("Queued article: \(jsonURL)")
                } else {
                    print("Skipped duplicate article: \(jsonURL)")
                }
            } catch {
                print("Failed to queue article \(jsonURL): \(error)")
            }
        }

        print("Added \(newUrls.count) new articles to processing queue")
    }
}
