import BackgroundTasks
import Foundation
import SwiftData
import UIKit

class SyncManager {
    static let shared = SyncManager()

    private var syncInProgress = false
    private var lastSyncTime: Date = .distantPast
    private let minimumSyncInterval: TimeInterval = 60

    // Process queue items with a hard 10-second time limit
    private func processQueueItems() async -> Bool {
        let timeLimit = 10.0 // Always limit to 10 seconds
        let startTime = Date()
        var processedCount = 0

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
                    // If there are more items to process, schedule another run soon
                    scheduleExtraQueueProcessing()
                }
            }

            return processedCount > 0

        } catch {
            print("Queue processing error: \(error.localizedDescription)")
            return false
        }
    }

    func registerBackgroundTasks() {
        // Register the background task identifier
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.arguspulse.articlefetch", using: nil) { task in
            // Cast the task to app refresh task
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }

            // Create a task that processes the queue
            let processingTask = Task {
                let didProcess = await self.processQueueItems()
                // Complete the background task
                appRefreshTask.setTaskCompleted(success: didProcess)
            }

            // Set up a task cancellation handler
            appRefreshTask.expirationHandler = {
                processingTask.cancel()
            }

            // Schedule the next background task when this one completes
            self.scheduleBackgroundFetch()
        }

        // Schedule the first background fetch
        scheduleBackgroundFetch()
        print("Background task registration complete")
    }

    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: "com.arguspulse.articlefetch")

        // Set this to run at least 15 minutes from now (similar to your original timer)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background fetch scheduled")
        } catch {
            print("Could not schedule background fetch: \(error)")
        }
    }

    // Start a background task to process queue items (called when app launches/becomes active)
    func startQueueProcessing() {
        // Process queue immediately when called.
        Task.detached(priority: .utility) {
            _ = await self.processQueueItems()

            // Always schedule the next background fetch
            await MainActor.run {
                self.scheduleBackgroundFetch()
            }
        }
    }

    // For backward compatibility with iOS 12 and earlier
    func handleBackgroundFetch(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let didProcess = await processQueueItems()
            completion(didProcess ? .newData : .noData)

            // Schedule the next background fetch
            await MainActor.run {
                self.scheduleBackgroundFetch()
            }
        }
    }

    // Schedule an extra processing run after a short delay (for when we know there are more items)
    private func scheduleExtraQueueProcessing() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            Task {
                await self?.processQueueItems()
            }
        }
    }

    // For explicit queue processing with feedback (e.g. from UI)
    func processQueue() async -> Bool {
        return await processQueueItems()
    }

    private func processQueueItem(_ item: ArticleQueueItem, context: ModelContext) async throws {
        let itemJsonURL = item.jsonURL

        // Check if we've already seen this article
        let seenFetchRequest = FetchDescriptor<SeenArticle>(predicate: #Predicate<SeenArticle> { seen in
            seen.json_url == itemJsonURL
        })
        if let _ = try? context.fetch(seenFetchRequest).first {
            print("[Warning] Skipping already seen article: \(item.jsonURL)")
            return
        }

        // Check if the article has already been processed as a notification
        let notificationFetchRequest = FetchDescriptor<NotificationData>(predicate: #Predicate<NotificationData> { notification in
            notification.json_url == itemJsonURL
        })
        if let _ = try? context.fetch(notificationFetchRequest).first {
            print("[Warning] Skipping duplicate notification: \(item.jsonURL)")
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
            engine_stats: articleJSON.engineStats,
            similar_articles: articleJSON.similarArticles
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

    func sendRecentArticlesToServer() async {
        guard !syncInProgress else {
            print("Sync is already in progress. Skipping this call.")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) > minimumSyncInterval else {
            // Sync called too soon; skipping.
            return
        }

        syncInProgress = true
        defer { syncInProgress = false }
        lastSyncTime = now

        do {
            let recentArticles = await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            // APIClient handles timeouts internally
            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            let payload = ["seen_articles": jsonUrls]

            do {
                // APIClient handles timeouts internally
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)

                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)
                if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty {
                    // Queue the unseen articles instead of fetching them immediately
                    await queueArticlesForProcessing(urls: unseenUrls)
                } else {
                    print("Server says there are no unseen articles.")
                }
            } catch let error as URLError where error.code == .timedOut {
                // Handle timeout specifically
                print("Sync operation timed out")
            }
        } catch {
            print("Failed to sync articles: \(error)")
        }
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

        // Process each URL in the background
        for jsonURL in urls {
            do {
                // Try to add the article to the queue
                // The addArticle method will check for duplicates and ignore them
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
    }
}
