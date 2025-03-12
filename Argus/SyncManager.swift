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
    private init() {
        // Initialize timer when SyncManager is created
        setupQueueProcessingTimer()
    }

    private var syncInProgress = false
    private var lastSyncTime: Date = .distantPast
    private let minimumSyncInterval: TimeInterval = 60
    private var queueProcessingTimer: Timer?

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

    // Set up a timer to process the queue periodically (every 15 minutes)
    private func setupQueueProcessingTimer() {
        // Cancel any existing timer
        queueProcessingTimer?.invalidate()

        // Create a new timer that fires every 15 minutes
        queueProcessingTimer = Timer.scheduledTimer(
            withTimeInterval: 15 * 60, // 15 minutes
            repeats: true
        ) { [weak self] _ in
            Task {
                await self?.processQueueItems()
            }
        }

        // Make sure timer runs even when scrolling
        RunLoop.current.add(queueProcessingTimer!, forMode: .common)

        print("Queue processing timer set up - will run every 15 minutes")
    }

    // Schedule an extra processing run after a short delay (for when we know there are more items)
    private func scheduleExtraQueueProcessing() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            Task {
                await self?.processQueueItems()
            }
        }
    }

    // Start a background task to process queue items periodically
    func startQueueProcessing() {
        // Process queue immediately when called.
        Task.detached(priority: .utility) {
            await self.processQueueItems()
        }
    }

    // For explicit queue processing with feedback (e.g. from UI)
    func processQueue() async -> Bool {
        return await processQueueItems()
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
}
