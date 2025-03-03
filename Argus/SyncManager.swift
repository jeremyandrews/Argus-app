import Foundation
import SwiftData
import SwiftyMarkdown

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

    func sendRecentArticlesToServer() async {
        // Run the fetch on the main actor, but nothing else
        func fetchRecentArticles() async throws -> [SeenArticle] {
            return await MainActor.run {
                let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
                let context = ArgusApp.sharedModelContainer.mainContext
                return (try? context.fetch(FetchDescriptor<SeenArticle>(
                    predicate: #Predicate { $0.date >= oneDayAgo }
                ))) ?? []
            }
        }

        do {
            // Fetch recent articles (still requires MainActor for SwiftData)
            let recentArticles = try await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            try await withTimeout(seconds: 10) {
                // Process network request off the main thread
                let url = URL(string: "https://api.arguspulse.com/articles/sync")!
                let payload = ["seen_articles": jsonUrls]
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)

                // Parse JSON off the main thread
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)

                if let unseenUrls = serverResponse["unseen_articles"] {
                    await self.fetchAndSaveUnseenArticles(from: unseenUrls)
                }
            }
        } catch is TimeoutError {
            print("Sync operation timed out after 10 seconds")
        } catch {
            print("Failed to sync articles: \(error)")
        }
    }

    private func processArticleJSON(_ json: [String: Any]) -> (
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
    ) {
        // Use markdown directly without conversion to plain text
        let title = (json["tiny_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let body = (json["tiny_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No content available"
        let topic = json["topic"] as? String
        let articleTitle = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No article title"
        let affected = json["affected"] as? String ?? ""
        let domain = URL(string: json["url"] as? String ?? "")?.host
        let pubDate = (json["pub_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

        // Critical: Use the actual json_url from the JSON if available
        // If not available, it might be in the URL path of the request
        let jsonURL: String
        if let explicitJsonURL = json["json_url"] as? String, !explicitJsonURL.isEmpty {
            jsonURL = explicitJsonURL
        } else if let url = json["url"] as? String, url.contains("json") {
            jsonURL = url
        } else {
            // This is a critical value - we need to ensure we have something valid
            print("WARNING: No json_url found in content! Using fallback.")
            jsonURL = "https://api.arguspulse.com/articles/\(UUID().uuidString).json"
        }

        print("Processing article with JSON URL: \(jsonURL)")

        // Extract the new fields
        let sourcesQuality = json["sources_quality"] as? Int
        let argumentQuality = json["argument_quality"] as? Int
        let sourceType = json["source_type"] as? String
        let quality = json["quality"] as? Int

        // Keep markdown content intact
        let summary = (json["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let criticalAnalysis = (json["critical_analysis"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let logicalFallacies = (json["logical_fallacies"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sourceAnalysis = (json["source_analysis"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let relationToTopic = (json["relation_to_topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let additionalInsights = (json["additional_insights"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Process engine stats
        var engineStats: String?
        if let model = json["model"] as? String,
           let elapsedTime = json["elapsed_time"] as? Double,
           let stats = json["stats"] as? String
        {
            var statsDict: [String: Any] = [
                "model": model,
                "elapsed_time": elapsedTime,
                "stats": stats,
            ]

            // Add system info if available
            if let systemInfo = json["system_info"] as? [String: Any] {
                statsDict["system_info"] = systemInfo
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: statsDict),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                engineStats = jsonString
            }
        }

        // Store similar articles as JSON string
        var similarArticlesJSON: String?
        if let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty {
            if let jsonData = try? JSONSerialization.data(withJSONObject: similarArticles),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                similarArticlesJSON = jsonString
            }
        }

        return (
            title, body, jsonURL, topic, articleTitle, affected, domain, pubDate,
            sourcesQuality, argumentQuality, sourceType, sourceAnalysis, quality,
            summary, criticalAnalysis, logicalFallacies, relationToTopic, additionalInsights,
            engineStats, similarArticlesJSON
        )
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

    func fetchAndSaveUnseenArticles(from urls: [String]) async {
        // Copy the URLs to avoid capturing
        let urlsToProcess = urls

        // Process everything in detached task
        Task.detached {
            // Temporary storage for processed articles
            var processedArticles: [(
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
            )] = []

            await withTaskGroup(of: (String, Data?).self) { group in
                for urlString in urlsToProcess {
                    group.addTask {
                        guard let url = URL(string: urlString) else {
                            return (urlString, nil as Data?)
                        }
                        // Timeout only the network call, not the processing
                        do {
                            let (data, _) = try await withTimeout(seconds: 10) {
                                try await URLSession.shared.data(from: url)
                            }
                            return (urlString, data)
                        } catch {
                            print("Network request timed out or failed for \(urlString): \(error)")
                            return (urlString, nil)
                        }
                    }
                }

                for await (urlString, data) in group {
                    guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("Failed to parse JSON for URL: \(urlString)")
                        continue
                    }

                    print("Successfully fetched and parsed JSON for: \(urlString)")

                    // Create a new JSON with the URL included
                    var jsonWithURL = json
                    // Add the URL to the JSON if it doesn't have one
                    if jsonWithURL["json_url"] == nil {
                        jsonWithURL["json_url"] = urlString
                    }

                    // Process all fields from the JSON
                    let processedArticle = self.processArticleJSON(jsonWithURL)
                    processedArticles.append(processedArticle)
                }
            }

            // Debug logging to see what's happening
            print("Processed \(processedArticles.count) articles from server")

            if !processedArticles.isEmpty {
                // Make a local copy to pass to the next function
                let articlesToSave = processedArticles

                // Add to database - this function handles its own actor transitions
                do {
                    try await self.addOrUpdateArticlesWithExtendedData(articlesToSave)
                    print("Successfully saved articles to database")
                } catch {
                    print("Failed to save articles: \(error)")
                }
            }
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

        // Make a local copy to avoid capturing
        let articlesToProcess = articles

        // Move all processing to MainActor directly since we need SwiftData context
        try await Task.detached { @MainActor in
            do {
                let context = ArgusApp.sharedModelContainer.mainContext

                // Get all existing data
                let existingNotifications = try? context.fetch(FetchDescriptor<NotificationData>())
                let existingURLs = existingNotifications?.map { $0.json_url } ?? []
                print("Found \(existingURLs.count) existing notifications")

                // Get existing seen article URLs separately
                let existingSeenURLs = (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []
                print("Found \(existingSeenURLs.count) seen articles")

                // Process all articles
                try context.transaction {
                    for article in articlesToProcess {
                        if existingURLs.contains(article.jsonURL) {
                            print("Updating existing article: \(article.jsonURL)")
                            // Update existing notification
                            if let notification = existingNotifications?.first(where: { $0.json_url == article.jsonURL }) {
                                // Update the fields we want to modify
                                if let sourcesQuality = article.sourcesQuality {
                                    notification.sources_quality = sourcesQuality
                                }

                                if let argumentQuality = article.argumentQuality {
                                    notification.argument_quality = argumentQuality
                                }

                                if let sourceType = article.sourceType {
                                    notification.source_type = sourceType
                                }

                                if let sourceAnalysis = article.sourceAnalysis {
                                    notification.source_analysis = sourceAnalysis
                                }

                                if let quality = article.quality {
                                    notification.quality = quality
                                }

                                if let summary = article.summary {
                                    notification.summary = summary
                                }

                                if let criticalAnalysis = article.criticalAnalysis {
                                    notification.critical_analysis = criticalAnalysis
                                }

                                if let logicalFallacies = article.logicalFallacies {
                                    notification.logical_fallacies = logicalFallacies
                                }

                                if let relationToTopic = article.relationToTopic {
                                    notification.relation_to_topic = relationToTopic
                                }

                                if let additionalInsights = article.additionalInsights {
                                    notification.additional_insights = additionalInsights
                                }

                                if let engineStats = article.engineStats {
                                    notification.engine_stats = engineStats
                                }

                                if let similarArticles = article.similarArticles {
                                    notification.similar_articles = similarArticles
                                }
                            }
                        } else if !existingSeenURLs.contains(article.jsonURL) {
                            print("Creating new article: \(article.jsonURL)")
                            // Create new notification and seen article
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
            } catch {
                print("Failed to insert or update articles: \(error)")
                throw error
            }
        }.value
    }

    static func fetchFullContentIfNeeded(for notification: NotificationData) async throws -> NotificationData {
        // Check if the notification already has detailed content
        if notification.summary != nil &&
            notification.critical_analysis != nil &&
            notification.logical_fallacies != nil
        {
            // Already has full content, just return it
            return notification
        }

        // Need to fetch the full content
        print("Fetching full content for article: \(notification.json_url)")

        guard let url = URL(string: notification.json_url) else {
            throw NSError(domain: "com.arguspulse", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON URL: \(notification.json_url)",
            ])
        }

        // Fetch with timeout
        do {
            let (data, _) = try await withTimeout(seconds: 10) {
                try await URLSession.shared.data(from: url)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "com.arguspulse", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to parse JSON from \(url)",
                ])
            }

            // Process the retrieved JSON
            var jsonWithURL = json
            // Ensure the json_url is in the processed data
            if jsonWithURL["json_url"] == nil {
                jsonWithURL["json_url"] = notification.json_url
            }

            let processedArticle = shared.processArticleJSON(jsonWithURL)

            // Update the database with the full content
            try await shared.addOrUpdateArticlesWithExtendedData([processedArticle])

            // Instead of fetching by ID, let's use the original notification object
            // and rely on SwiftData's object tracking to reflect the updates
            await MainActor.run {
                // Give SwiftData a chance to update the object
                try? ArgusApp.sharedModelContainer.mainContext.save()
            }

            // Return the same notification object which should now have updated fields
            return notification
        } catch is TimeoutError {
            print("Network request timed out for \(url)")
            throw NSError(domain: "com.arguspulse", code: 408, userInfo: [
                NSLocalizedDescriptionKey: "Request timed out fetching article content",
            ])
        } catch {
            print("Failed to fetch article content: \(error)")
            throw error
        }
    }
}
