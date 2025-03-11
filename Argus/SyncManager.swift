import Foundation
import SwiftData
import UIKit

extension Task where Success == Never, Failure == Never {
    static func timeout(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw TimeoutError()
    }
}

struct TimeoutError: Error {}

func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.timeout(seconds: seconds)
            fatalError("Timeout task should never complete normally")
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

class SyncManager {
    static let shared = SyncManager()
    private init() {}

    private var syncInProgress = false
    private var lastSyncTime: Date = .distantPast
    private let minimumSyncInterval: TimeInterval = 60

    // Start a background task to process queue items
    func startQueueProcessing() {
        Task.detached(priority: .background) {
            await self.processQueueItems()
        }
    }

    // Main processing loop that runs continuously in the background
    private func processQueueItems() async {
        print("Starting background queue processing")

        let container = await MainActor.run {
            ArgusApp.sharedModelContainer
        }
        let backgroundContext = ModelContext(container)

        while true {
            do {
                let queueManager = backgroundContext.queueManager()

                let itemsToProcess = try await queueManager.getItemsToProcess(limit: 10)

                if itemsToProcess.isEmpty {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                    continue
                }

                print("Processing batch of \(itemsToProcess.count) queue items")

                var processedItems = [ArticleQueueItem]()

                for item in itemsToProcess {
                    if Task.isCancelled {
                        break
                    }

                    do {
                        try await processQueueItem(item, context: backgroundContext)
                        processedItems.append(item)
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

                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            } catch {
                print("Queue processing error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds pause on error
            }
        }
    }

    private func processQueueItem(_ item: ArticleQueueItem, context: ModelContext) async throws {
        let itemJsonURL = item.jsonURL

        // Check if the article has already been processed as a notification
        let notificationFetchRequest = FetchDescriptor<NotificationData>(predicate: #Predicate<NotificationData> { notification in
            notification.json_url == itemJsonURL
        })
        if let _ = try? context.fetch(notificationFetchRequest).first {
            print("[Warning] Skipping duplicate article: \(item.jsonURL)")
            return
        }

        guard let url = URL(string: item.jsonURL) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON URL: \(item.jsonURL)",
            ])
        }

        // Fetch with timeout
        let (data, _) = try await withTimeout(seconds: 10) {
            try await URLSession.shared.data(from: url)
        }

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

        // Create NotificationData instance
        let notification = NotificationData(
            id: notificationID,
            date: date,
            title: articleJSON.title,
            body: articleJSON.body,
            json_url: articleJSON.jsonURL,
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
            additional_insights: articleJSON.additionalInsights
        )

        // Insert notification
        context.insert(notification)

        _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
        _ = getAttributedString(for: .body, from: notification, createIfMissing: true)

        // Insert SeenArticle record
        let seenArticle = SeenArticle(
            id: notificationID,
            json_url: articleJSON.jsonURL,
            date: date
        )
        context.insert(seenArticle)
    }

    func processQueueWithTimeout(seconds: Double) async -> Bool {
        print("Starting time-constrained queue processing (max \(seconds) seconds)")

        let startTime = Date()
        var processedCount = 0
        var hasMoreItems = true

        do {
            // Create a background context for queue operations
            let container = await MainActor.run {
                ArgusApp.sharedModelContainer
            }
            let backgroundContext = ModelContext(container)
            let queueManager = backgroundContext.queueManager()

            // Process items until we hit the time limit or run out of items
            while hasMoreItems && Date().timeIntervalSince(startTime) < seconds {
                // Get a small batch (3 items) to process
                let itemsToProcess = try await queueManager.getItemsToProcess(limit: 3)

                if itemsToProcess.isEmpty {
                    hasMoreItems = false
                    break
                }

                // Track successfully processed items
                var processedItems = [ArticleQueueItem]()

                // Process each item in the batch
                for item in itemsToProcess {
                    // Check if we've exceeded the time limit
                    if Date().timeIntervalSince(startTime) >= seconds {
                        break
                    }

                    do {
                        // Process the item
                        try await processQueueItem(item, context: backgroundContext)
                        processedItems.append(item)
                        processedCount += 1
                    } catch {
                        print("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                    }
                }

                // Save and clean up processed items
                if !processedItems.isEmpty {
                    try backgroundContext.save()

                    // Remove processed items from the queue
                    for item in processedItems {
                        try queueManager.removeItem(item)
                    }

                    print("Successfully processed \(processedItems.count) items in time-constrained mode")

                    // Notify the main context that new data is available
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                }

                // Check if there might be more items
                let remainingCount = try await queueManager.queueCount()
                hasMoreItems = processedCount < remainingCount
            }

            let timeElapsed = Date().timeIntervalSince(startTime)
            print("Time-constrained processing completed: \(processedCount) items in \(String(format: "%.2f", timeElapsed)) seconds")
            return processedCount > 0

        } catch {
            print("Queue processing error during time-constrained execution: \(error.localizedDescription)")
            return false
        }
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

            try await withTimeout(seconds: 10) {
                let url = URL(string: "https://api.arguspulse.com/articles/sync")!
                let payload = ["seen_articles": jsonUrls]
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)

                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)
                if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty {
                    // Queue the unseen articles instead of fetching them immediately
                    await self.queueArticlesForProcessing(urls: unseenUrls)
                } else {
                    print("Server says there are no unseen articles.")
                }
            }
        } catch is TimeoutError {
            print("Sync operation timed out after 10 seconds.")
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

    private func applyRichTextBlobs(notification: NotificationData, richTextBlobs: [String: Data]) {
        // Apply each blob to the corresponding field
        if let titleBlob = richTextBlobs["title"] {
            notification.title_blob = titleBlob
        }

        if let bodyBlob = richTextBlobs["body"] {
            notification.body_blob = bodyBlob
        }

        if let summaryBlob = richTextBlobs["summary"] {
            notification.summary_blob = summaryBlob
        }

        if let criticalAnalysisBlob = richTextBlobs["critical_analysis"] {
            notification.critical_analysis_blob = criticalAnalysisBlob
        }

        if let logicalFallaciesBlob = richTextBlobs["logical_fallacies"] {
            notification.logical_fallacies_blob = logicalFallaciesBlob
        }

        if let sourceAnalysisBlob = richTextBlobs["source_analysis"] {
            notification.source_analysis_blob = sourceAnalysisBlob
        }

        if let relationToTopicBlob = richTextBlobs["relation_to_topic"] {
            notification.relation_to_topic_blob = relationToTopicBlob
        }

        if let additionalInsightsBlob = richTextBlobs["additional_insights"] {
            notification.additional_insights_blob = additionalInsightsBlob
        }
    }

    private func updateNotificationFields(notification: NotificationData, extendedInfo: (
        sourcesQuality: Int?,
        argumentQuality: Int?,
        sourceType: String?,
        sourceAnalysis: String?,
        quality: Int?,
        summary: String?,
        criticalAnalysis: String?,
        logicalFallacies: String?,
        relationToTopic: String?,
        additionalInsights: String?,
        engineStats: String?,
        similarArticles: String?
    )) {
        // Update all fields that are present
        if let sourcesQuality = extendedInfo.sourcesQuality {
            notification.sources_quality = sourcesQuality
        }

        if let argumentQuality = extendedInfo.argumentQuality {
            notification.argument_quality = argumentQuality
        }

        if let sourceType = extendedInfo.sourceType {
            notification.source_type = sourceType
        }

        if let sourceAnalysis = extendedInfo.sourceAnalysis {
            notification.source_analysis = sourceAnalysis
        }

        if let quality = extendedInfo.quality {
            notification.quality = quality
        }

        if let summary = extendedInfo.summary {
            notification.summary = summary
        }

        if let criticalAnalysis = extendedInfo.criticalAnalysis {
            notification.critical_analysis = criticalAnalysis
        }

        if let logicalFallacies = extendedInfo.logicalFallacies {
            notification.logical_fallacies = logicalFallacies
        }

        if let relationToTopic = extendedInfo.relationToTopic {
            notification.relation_to_topic = relationToTopic
        }

        if let additionalInsights = extendedInfo.additionalInsights {
            notification.additional_insights = additionalInsights
        }

        if let engineStats = extendedInfo.engineStats {
            notification.engine_stats = engineStats
        }

        if let similarArticles = extendedInfo.similarArticles {
            notification.similar_articles = similarArticles
        }
    }
}
