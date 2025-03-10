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

        while true {
            do {
                // Create a background context for queue operations
                let container = await MainActor.run {
                    ArgusApp.sharedModelContainer
                }
                let backgroundContext = ModelContext(container)
                let queueManager = backgroundContext.queueManager()

                // Get items to process (larger batch for better efficiency)
                let itemsToProcess = try await queueManager.getItemsToProcess(limit: 10)

                if itemsToProcess.isEmpty {
                    // If no items to process, wait before checking again
                    try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                    continue
                }

                print("Processing batch of \(itemsToProcess.count) queue items")

                // Track successfully processed items
                var processedItems = [ArticleQueueItem]()

                // Process each item in the batch - ALL IN BACKGROUND CONTEXT
                for item in itemsToProcess {
                    if Task.isCancelled {
                        break
                    }

                    do {
                        // Process the item in the BACKGROUND context
                        try await processQueueItem(item, context: backgroundContext)
                        processedItems.append(item)
                    } catch {
                        print("Error processing queue item \(item.jsonURL): \(error.localizedDescription)")
                    }
                }

                // Only save once after the entire batch is processed
                if !processedItems.isEmpty {
                    try backgroundContext.save()

                    // After saving, remove the processed items from the queue
                    for item in processedItems {
                        try queueManager.removeItem(item)
                    }

                    print("Successfully processed and saved batch of \(processedItems.count) items")

                    // OPTIONAL: Notify the main context that new data is available
                    // Only do this if you need the UI to update immediately
                    await MainActor.run {
                        NotificationUtils.updateAppBadgeCount()
                    }
                }

                // Short pause between batches
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            } catch {
                print("Queue processing error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds pause on error
            }
        }
    }

    // Process a single queue item - downloads and saves the article data
    private func processQueueItem(_ item: ArticleQueueItem, context: ModelContext) async throws {
        guard let url = URL(string: item.jsonURL) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON URL: \(item.jsonURL)",
            ])
        }

        // Fetch with timeout - doing network operations in the background
        let (data, _) = try await withTimeout(seconds: 10) {
            try await URLSession.shared.data(from: url)
        }

        guard let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON data in response",
            ])
        }

        // Ensure the json_url is in the processed data - still in background
        var enrichedJson = rawJson
        if enrichedJson["json_url"] == nil {
            enrichedJson["json_url"] = item.jsonURL
        }

        // Process article data - still in background
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

        // Create all objects we need in the background
        let date = Date()
        let notificationID = item.notificationID ?? UUID()

        // If the item didn't already have a notification ID, update it
        if item.notificationID == nil {
            item.notificationID = notificationID
            // Don't save context here, will be saved in batch
        }

        // Create the notification object in the background context
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
            additional_insights: articleJSON.additionalInsights,
            engine_stats: engineStatsJSON, // Use the JSON string we created
            similar_articles: similarArticlesJSON // Use the JSON string for similar articles
        )

        // Insert the notification into the BACKGROUND context
        context.insert(notification)

        // Create and insert the SeenArticle record in the BACKGROUND context
        let seenArticle = SeenArticle(
            id: notificationID,
            json_url: articleJSON.jsonURL,
            date: date
        )
        context.insert(seenArticle)
        // No context save here - it will be saved in batch
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

    func fetchAndSaveUnseenArticles(from urls: [String]) async {
        let fetchedArticles = await withTaskGroup(of: (String, Data?).self) { group -> [(String, Data?)] in
            for urlString in urls {
                group.addTask {
                    guard let url = URL(string: urlString) else {
                        return (urlString, nil)
                    }
                    do {
                        let (data, _) = try await withTimeout(seconds: 10) {
                            try await URLSession.shared.data(from: url)
                        }
                        return (urlString, data)
                    } catch {
                        print("Network request failed for \(urlString): \(error)")
                        return (urlString, nil)
                    }
                }
            }

            var results: [(String, Data?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let processed = fetchedArticles.compactMap { urlString, data -> ArticleJSON? in
            guard let data,
                  let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("Failed to parse JSON for \(urlString)")
                return nil
            }
            var enrichedJson = rawJson
            if enrichedJson["json_url"] == nil {
                enrichedJson["json_url"] = urlString
            }
            return processArticleJSON(enrichedJson)
        }

        let preparedArticles = await withTaskGroup(of: PreparedArticle?.self) { group -> [PreparedArticle] in
            for article in processed {
                group.addTask {
                    convertToPreparedArticle(article)
                }
            }

            var results: [PreparedArticle] = []
            for await result in group {
                if let r = result {
                    results.append(r)
                }
            }
            return results
        }

        do {
            try await savePreparedArticles(preparedArticles)
        } catch {
            print("Failed to save articles: \(error)")
        }
    }

    func addOrUpdateArticle(
        title: String,
        body: String,
        jsonURL: String,
        topic: String?,
        articleTitle: String,
        affected: String,
        domain: String?,
        pubDate: Date? = nil,
        suppressBadgeUpdate: Bool = false
    ) async throws {
        try await addOrUpdateArticles([(
            title: title,
            body: body,
            jsonURL: jsonURL,
            topic: topic,
            articleTitle: articleTitle,
            affected: affected,
            domain: domain,
            pubDate: pubDate
        )], suppressBadgeUpdate: suppressBadgeUpdate)
    }

    func addOrUpdateArticles(_ articles: [(
        title: String,
        body: String,
        jsonURL: String,
        topic: String?,
        articleTitle: String,
        affected: String,
        domain: String?,
        pubDate: Date?
    )], suppressBadgeUpdate: Bool = false) async throws {
        // Process the data off-thread and then apply changes on main thread
        let articlesToProcess = articles // Make a local copy to avoid capturing

        return try await Task.detached { @MainActor in
            // First, fetch existing URLs
            let context = ArgusApp.sharedModelContainer.mainContext
            let existingURLs = (try? context.fetch(FetchDescriptor<NotificationData>()))?.map { $0.json_url } ?? []
            let existingSeenURLs = (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []

            // Process the data and build the insert arrays
            var newNotifications: [NotificationData] = []
            var newSeenArticles: [SeenArticle] = []

            for article in articlesToProcess {
                if !existingURLs.contains(article.jsonURL), !existingSeenURLs.contains(article.jsonURL) {
                    let notification = NotificationData(
                        date: Date(),
                        title: article.title,
                        body: article.body,
                        json_url: article.jsonURL,
                        topic: article.topic,
                        article_title: article.articleTitle,
                        affected: article.affected,
                        domain: article.domain,
                        pub_date: article.pubDate ?? Date()
                    )

                    let seenArticle = SeenArticle(
                        id: notification.id,
                        json_url: article.jsonURL,
                        date: notification.date
                    )

                    newNotifications.append(notification)
                    newSeenArticles.append(seenArticle)
                }
            }

            // Do all database work on main actor
            if !newNotifications.isEmpty {
                try context.transaction {
                    for notification in newNotifications {
                        context.insert(notification)
                    }

                    for seenArticle in newSeenArticles {
                        context.insert(seenArticle)
                    }
                }
            }

            if !suppressBadgeUpdate {
                NotificationUtils.updateAppBadgeCount()
            }
        }.value
    }

    func savePreparedArticles(_ articles: [PreparedArticle]) async throws {
        // 1. Do the heavy processing work off the main thread
        let articlesToSave = await Task.detached(priority: .utility) { () -> [(NotificationData, SeenArticle)] in
            // Process each article and create the notifications
            return articles.map { article in
                let notification = NotificationData(
                    date: Date(),
                    title: article.title,
                    body: article.body,
                    json_url: article.jsonURL,
                    topic: article.topic,
                    article_title: article.articleTitle,
                    affected: article.affected,
                    domain: article.domain,
                    pub_date: article.pubDate ?? Date(),
                    isViewed: false,
                    isBookmarked: false,
                    isArchived: false
                )

                let seenArticle = SeenArticle(
                    id: notification.id,
                    json_url: article.jsonURL,
                    date: notification.date
                )

                return (notification, seenArticle)
            }
        }.value

        // 2. Only use the MainActor for the actual database work
        return try await MainActor.run {
            let context = ArgusApp.sharedModelContainer.mainContext

            // Fetch existing URLs (must be done on MainActor since it uses SwiftData)
            let existingSeenURLs = Set(
                (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []
            )

            // Filter out articles we've already seen
            let newArticles = articlesToSave.filter { !existingSeenURLs.contains($0.0.json_url) }
            guard !newArticles.isEmpty else {
                print("No new articles to insert/update. Skipping transaction.")
                return
            }

            // Execute the actual database transaction
            try context.transaction {
                for (notification, seenArticle) in newArticles {
                    context.insert(notification)
                    context.insert(seenArticle)
                }
            }

            print("Inserted/updated \(newArticles.count) articles in one transaction.")
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

    func addOrUpdateArticlesWithExtendedData(_ articles: [(
        title: String,
        body: String,
        jsonURL: String,
        topic: String?,
        articleTitle: String,
        affected: String,
        domain: String?,
        pubDate: Date?,
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
    )], suppressBadgeUpdate: Bool = false) async throws {
        // Debug what we're trying to save
        print("Attempting to save \(articles.count) articles to database")

        // Process articles off the main thread
        let processedData = await Task.detached(priority: .utility) { () -> [(article: PreparedArticle, fields: [RichTextField: String?])] in
            return articles.map { article in
                // Convert to PreparedArticle
                let prepared = PreparedArticle(
                    title: article.title,
                    body: article.body,
                    jsonURL: article.jsonURL,
                    topic: article.topic,
                    articleTitle: article.articleTitle,
                    affected: article.affected,
                    domain: article.domain,
                    pubDate: article.pubDate,
                    sourcesQuality: article.sourcesQuality,
                    argumentQuality: article.argumentQuality,
                    sourceType: article.sourceType,
                    sourceAnalysis: article.sourceAnalysis,
                    quality: article.quality,
                    summary: article.summary,
                    criticalAnalysis: article.criticalAnalysis,
                    logicalFallacies: article.logicalFallacies,
                    relationToTopic: article.relationToTopic,
                    additionalInsights: article.additionalInsights,
                    engineStats: article.engineStats,
                    similarArticles: article.similarArticles
                )

                // Create a mapping of fields to their markdown text values
                let fields: [RichTextField: String?] = [
                    .title: article.title,
                    .body: article.body,
                    .summary: article.summary,
                    .criticalAnalysis: article.criticalAnalysis,
                    .logicalFallacies: article.logicalFallacies,
                    .sourceAnalysis: article.sourceAnalysis,
                    .relationToTopic: article.relationToTopic,
                    .additionalInsights: article.additionalInsights,
                ]

                return (prepared, fields)
            }
        }.value

        // Use MainActor only for the database operations
        try await MainActor.run {
            let context = ArgusApp.sharedModelContainer.mainContext

            // Fetch existing data (must happen on MainActor)
            let existingNotifications = try? context.fetch(FetchDescriptor<NotificationData>())
            let existingURLs = existingNotifications?.map { $0.json_url } ?? []
            print("Found \(existingURLs.count) existing notifications")

            let existingSeenURLs = (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []
            print("Found \(existingSeenURLs.count) seen articles")

            // Process all articles in a single transaction
            try context.transaction {
                for (article, _) in processedData {
                    if existingURLs.contains(article.jsonURL) {
                        print("Updating existing article: \(article.jsonURL)")
                        // Update existing notification
                        if let notification = existingNotifications?.first(where: { $0.json_url == article.jsonURL }) {
                            // Update fields
                            self.updateNotificationFields(notification: notification, extendedInfo: (
                                sourcesQuality: article.sourcesQuality,
                                argumentQuality: article.argumentQuality,
                                sourceType: article.sourceType,
                                sourceAnalysis: article.sourceAnalysis,
                                quality: article.quality,
                                summary: article.summary,
                                criticalAnalysis: article.criticalAnalysis,
                                logicalFallacies: article.logicalFallacies,
                                relationToTopic: article.relationToTopic,
                                additionalInsights: article.additionalInsights,
                                engineStats: article.engineStats, // Changed from engine_stats to engineStats
                                similarArticles: article.similarArticles // Changed from similar_articles to similarArticles
                            ))
                        }
                    } else if !existingSeenURLs.contains(article.jsonURL) {
                        print("Creating new article: \(article.jsonURL)")

                        // Create new notification with all fields
                        let notification = NotificationData(
                            date: Date(),
                            title: article.title,
                            body: article.body,
                            json_url: article.jsonURL,
                            topic: article.topic,
                            article_title: article.articleTitle,
                            affected: article.affected,
                            domain: article.domain,
                            pub_date: article.pubDate ?? Date(),
                            isViewed: false,
                            isBookmarked: false,
                            isArchived: false,
                            sources_quality: article.sourcesQuality,
                            argument_quality: article.argumentQuality,
                            source_type: article.sourceType,
                            source_analysis: article.sourceAnalysis,
                            quality: article.quality,
                            summary: article.summary,
                            critical_analysis: article.criticalAnalysis,
                            logical_fallacies: article.logicalFallacies,
                            relation_to_topic: article.relationToTopic,
                            additional_insights: article.additionalInsights,
                            engine_stats: article.engineStats,
                            similar_articles: article.similarArticles
                        )

                        let seenArticle = SeenArticle(
                            id: notification.id,
                            json_url: article.jsonURL,
                            date: notification.date
                        )

                        // Insert the new entities
                        context.insert(notification)
                        context.insert(seenArticle)
                    } else {
                        print("Skipping article (already seen): \(article.jsonURL)")
                    }
                }
            }

            print("Database transaction completed")

            if !suppressBadgeUpdate {
                NotificationUtils.updateAppBadgeCount()
            }
        }
    }
}
