import Foundation
import SwiftData
import SwiftyMarkdown
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

struct ArticleJSON {
    let title: String
    let body: String
    let jsonURL: String
    let topic: String?
    let articleTitle: String
    let affected: String
    let domain: String?
    let pubDate: Date?
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    let sourceAnalysis: String?
    let quality: Int?
    let summary: String?
    let criticalAnalysis: String?
    let logicalFallacies: String?
    let relationToTopic: String?
    let additionalInsights: String?
    let engineStats: String?
    let similarArticles: String?
}

struct PreparedArticle {
    let title: String
    let body: String
    let jsonURL: String
    let topic: String?
    let articleTitle: String
    let affected: String
    let domain: String?
    let pubDate: Date?
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    let sourceAnalysis: String?
    let quality: Int?
    let summary: String?
    let criticalAnalysis: String?
    let logicalFallacies: String?
    let relationToTopic: String?
    let additionalInsights: String?
    let engineStats: String?
    let similarArticles: String?
}

func convertToPreparedArticle(_ input: ArticleJSON) -> PreparedArticle {
    return PreparedArticle(
        title: input.title,
        body: input.body,
        jsonURL: input.jsonURL,
        topic: input.topic,
        articleTitle: input.articleTitle,
        affected: input.affected,
        domain: input.domain,
        pubDate: input.pubDate,
        sourcesQuality: input.sourcesQuality,
        argumentQuality: input.argumentQuality,
        sourceType: input.sourceType,
        sourceAnalysis: input.sourceAnalysis,
        quality: input.quality,
        summary: input.summary,
        criticalAnalysis: input.criticalAnalysis,
        logicalFallacies: input.logicalFallacies,
        relationToTopic: input.relationToTopic,
        additionalInsights: input.additionalInsights,
        engineStats: input.engineStats,
        similarArticles: input.similarArticles
    )
}

class SyncManager {
    static let shared = SyncManager()
    private init() {}

    private var syncInProgress = false
    private var lastSyncTime: Date = .distantPast
    private let minimumSyncInterval: TimeInterval = 60

    func sendRecentArticlesToServer() async {
        guard !syncInProgress else {
            print("Sync is already in progress. Skipping this call.")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) > minimumSyncInterval else {
            print("Sync called too soon; skipping.")
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
                    await self.fetchAndSaveUnseenArticles(from: unseenUrls)
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

    func processArticleJSON(_ json: [String: Any]) -> ArticleJSON? {
        guard let title = json["title"] as? String,
              let body = json["body"] as? String,
              let jsonURL = json["json_url"] as? String
        else {
            return nil
        }

        return ArticleJSON(
            title: title,
            body: body,
            jsonURL: jsonURL,
            topic: json["topic"] as? String,
            articleTitle: json["article_title"] as? String ?? "",
            affected: json["affected"] as? String ?? "",
            domain: json["domain"] as? String,
            pubDate: (json["pub_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            sourcesQuality: json["sources_quality"] as? Int,
            argumentQuality: json["argument_quality"] as? Int,
            sourceType: json["source_type"] as? String,
            sourceAnalysis: json["source_analysis"] as? String,
            quality: json["quality"] as? Int,
            summary: json["summary"] as? String,
            criticalAnalysis: json["critical_analysis"] as? String,
            logicalFallacies: json["logical_fallacies"] as? String,
            relationToTopic: json["relation_to_topic"] as? String,
            additionalInsights: json["additional_insights"] as? String,
            engineStats: json["engine_stats"] as? String,
            similarArticles: json["similar_articles"] as? String
        )
    }

    private func convertMarkdownFieldsToRichText(for notification: NotificationData) {
        // Create function to convert markdown to NSAttributedString with Dynamic Type support
        func markdownToAccessibleAttributedString(_ markdown: String?, textStyle: String) -> NSAttributedString? {
            guard let markdown = markdown, !markdown.isEmpty else { return nil }

            let swiftyMarkdown = SwiftyMarkdown(string: markdown)

            // Get the preferred font for the specified text style (supports Dynamic Type)
            let bodyFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle(rawValue: textStyle))
            swiftyMarkdown.body.fontName = bodyFont.fontName
            swiftyMarkdown.body.fontSize = bodyFont.pointSize

            // Style headings with appropriate Dynamic Type text styles
            let h1Font = UIFont.preferredFont(forTextStyle: .title1)
            swiftyMarkdown.h1.fontName = h1Font.fontName
            swiftyMarkdown.h1.fontSize = h1Font.pointSize

            let h2Font = UIFont.preferredFont(forTextStyle: .title2)
            swiftyMarkdown.h2.fontName = h2Font.fontName
            swiftyMarkdown.h2.fontSize = h2Font.pointSize

            let h3Font = UIFont.preferredFont(forTextStyle: .title3)
            swiftyMarkdown.h3.fontName = h3Font.fontName
            swiftyMarkdown.h3.fontSize = h3Font.pointSize

            // Other styling
            swiftyMarkdown.link.color = .systemBlue

            // Get bold and italic versions of the body font if possible
            if let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                let boldFont = UIFont(descriptor: boldDescriptor, size: 0)
                swiftyMarkdown.bold.fontName = boldFont.fontName
            } else {
                swiftyMarkdown.bold.fontName = ".SFUI-Bold"
            }

            if let italicDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                let italicFont = UIFont(descriptor: italicDescriptor, size: 0)
                swiftyMarkdown.italic.fontName = italicFont.fontName
            } else {
                swiftyMarkdown.italic.fontName = ".SFUI-Italic"
            }

            // Get the initial attributed string from SwiftyMarkdown
            let attributedString = swiftyMarkdown.attributedString()

            // Create a mutable copy
            let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)

            // Add accessibility trait to indicate the text style
            let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")
            mutableAttributedString.addAttribute(
                textStyleKey,
                value: textStyle,
                range: NSRange(location: 0, length: mutableAttributedString.length)
            )

            return mutableAttributedString
        }

        // Add this method to handle the other places that still call the old function name
        func markdownToAttributedString(_ markdown: String?, isTitle: Bool = false) -> NSAttributedString? {
            let textStyle = isTitle ? "UIFontTextStyleHeadline" : "UIFontTextStyleBody"
            return markdownToAccessibleAttributedString(markdown, textStyle: textStyle)
        }

        // Convert title with headline style
        if let attributedTitle = markdownToAccessibleAttributedString(notification.title, textStyle: "UIFontTextStyleHeadline") {
            try? notification.setRichText(attributedTitle, for: .title)
        }

        // Convert body with body style
        if let attributedBody = markdownToAccessibleAttributedString(notification.body, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedBody, for: .body)
        }

        // Convert summary
        if let attributedSummary = markdownToAccessibleAttributedString(notification.summary, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedSummary, for: .summary)
        }

        // Convert critical analysis
        if let attributedCriticalAnalysis = markdownToAccessibleAttributedString(notification.critical_analysis, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedCriticalAnalysis, for: .criticalAnalysis)
        }

        // Convert logical fallacies
        if let attributedLogicalFallacies = markdownToAccessibleAttributedString(notification.logical_fallacies, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedLogicalFallacies, for: .logicalFallacies)
        }

        // Convert source analysis
        if let attributedSourceAnalysis = markdownToAccessibleAttributedString(notification.source_analysis, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedSourceAnalysis, for: .sourceAnalysis)
        }

        // Convert relation to topic
        if let attributedRelationToTopic = markdownToAccessibleAttributedString(notification.relation_to_topic, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedRelationToTopic, for: .relationToTopic)
        }

        // Convert additional insights
        if let attributedAdditionalInsights = markdownToAccessibleAttributedString(notification.additional_insights, textStyle: "UIFontTextStyleBody") {
            try? notification.setRichText(attributedAdditionalInsights, for: .additionalInsights)
        }
    }

    static func convertMarkdownToRichTextIfNeeded(for notification: NotificationData) {
        // Check if rich text versions already exist
        let hasRichText = notification.title_blob != nil &&
            notification.body_blob != nil &&
            (notification.summary == nil || notification.summary_blob != nil) &&
            (notification.critical_analysis == nil || notification.critical_analysis_blob != nil) &&
            (notification.logical_fallacies == nil || notification.logical_fallacies_blob != nil) &&
            (notification.source_analysis == nil || notification.source_analysis_blob != nil) &&
            (notification.relation_to_topic == nil || notification.relation_to_topic_blob != nil) &&
            (notification.additional_insights == nil || notification.additional_insights_blob != nil)

        // Convert only if we don't have rich text versions yet
        if !hasRichText {
            Task {
                // Offload the CPU-intensive conversion to a detached task
                await Task.detached(priority: .utility) {
                    await MainActor.run {
                        // This function handles the actual conversion work
                        SyncManager.shared.convertMarkdownFieldsToRichText(for: notification)
                    }
                }.value
            }
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

    @MainActor
    private func savePreparedArticles(_ articles: [PreparedArticle]) throws {
        let context = ArgusApp.sharedModelContainer.mainContext

        let existingSeenURLs = Set(
            (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []
        )

        let newArticles = articles.filter { !existingSeenURLs.contains($0.jsonURL) }
        guard !newArticles.isEmpty else {
            print("No new articles to insert/update. Skipping transaction.")
            return
        }

        try context.transaction {
            for prepared in newArticles {
                let notification = NotificationData(
                    date: Date(),
                    title: prepared.title,
                    body: prepared.body,
                    json_url: prepared.jsonURL,
                    topic: prepared.topic,
                    article_title: prepared.articleTitle,
                    affected: prepared.affected,
                    domain: prepared.domain,
                    pub_date: prepared.pubDate ?? Date(),
                    isViewed: false,
                    isBookmarked: false,
                    isArchived: false
                )
                context.insert(notification)
                context.insert(SeenArticle(id: notification.id, json_url: prepared.jsonURL, date: notification.date))
            }
        }

        print("Inserted/updated \(newArticles.count) articles in one transaction.")
    }

    private func generateAttributedStringsForFields(_ fields: (
        title: String,
        body: String,
        summary: String?,
        criticalAnalysis: String?,
        logicalFallacies: String?,
        sourceAnalysis: String?,
        relationToTopic: String?,
        additionalInsights: String?
    )) -> [String: NSAttributedString] {
        var attributedStrings: [String: NSAttributedString] = [:]

        // Create function to convert markdown to NSAttributedString with Dynamic Type support
        func markdownToAccessibleAttributedString(_ markdown: String?, textStyle: String) -> NSAttributedString? {
            guard let markdown = markdown, !markdown.isEmpty else { return nil }

            let swiftyMarkdown = SwiftyMarkdown(string: markdown)

            // Get the preferred font for the specified text style (supports Dynamic Type)
            let bodyFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle(rawValue: textStyle))
            swiftyMarkdown.body.fontName = bodyFont.fontName
            swiftyMarkdown.body.fontSize = bodyFont.pointSize

            // Style headings with appropriate Dynamic Type text styles
            let h1Font = UIFont.preferredFont(forTextStyle: .title1)
            swiftyMarkdown.h1.fontName = h1Font.fontName
            swiftyMarkdown.h1.fontSize = h1Font.pointSize

            let h2Font = UIFont.preferredFont(forTextStyle: .title2)
            swiftyMarkdown.h2.fontName = h2Font.fontName
            swiftyMarkdown.h2.fontSize = h2Font.pointSize

            let h3Font = UIFont.preferredFont(forTextStyle: .title3)
            swiftyMarkdown.h3.fontName = h3Font.fontName
            swiftyMarkdown.h3.fontSize = h3Font.pointSize

            // Other styling
            swiftyMarkdown.link.color = .systemBlue

            // Get bold and italic versions of the body font if possible
            if let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                let boldFont = UIFont(descriptor: boldDescriptor, size: 0)
                swiftyMarkdown.bold.fontName = boldFont.fontName
            } else {
                swiftyMarkdown.bold.fontName = ".SFUI-Bold"
            }

            if let italicDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                let italicFont = UIFont(descriptor: italicDescriptor, size: 0)
                swiftyMarkdown.italic.fontName = italicFont.fontName
            } else {
                swiftyMarkdown.italic.fontName = ".SFUI-Italic"
            }

            // Get the initial attributed string from SwiftyMarkdown
            let attributedString = swiftyMarkdown.attributedString()

            // Create a mutable copy
            let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)

            // Add accessibility trait to indicate the text style
            let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")
            mutableAttributedString.addAttribute(
                textStyleKey,
                value: textStyle,
                range: NSRange(location: 0, length: mutableAttributedString.length)
            )

            return mutableAttributedString
        }

        // Generate all attributed strings at once
        if let attributedTitle = markdownToAccessibleAttributedString(fields.title, textStyle: "UIFontTextStyleHeadline") {
            attributedStrings["title"] = attributedTitle
        }

        if let attributedBody = markdownToAccessibleAttributedString(fields.body, textStyle: "UIFontTextStyleBody") {
            attributedStrings["body"] = attributedBody
        }

        if let summary = fields.summary,
           let attributedSummary = markdownToAccessibleAttributedString(summary, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["summary"] = attributedSummary
        }

        if let criticalAnalysis = fields.criticalAnalysis,
           let attributedCriticalAnalysis = markdownToAccessibleAttributedString(criticalAnalysis, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["critical_analysis"] = attributedCriticalAnalysis
        }

        if let logicalFallacies = fields.logicalFallacies,
           let attributedLogicalFallacies = markdownToAccessibleAttributedString(logicalFallacies, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["logical_fallacies"] = attributedLogicalFallacies
        }

        if let sourceAnalysis = fields.sourceAnalysis,
           let attributedSourceAnalysis = markdownToAccessibleAttributedString(sourceAnalysis, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["source_analysis"] = attributedSourceAnalysis
        }

        if let relationToTopic = fields.relationToTopic,
           let attributedRelationToTopic = markdownToAccessibleAttributedString(relationToTopic, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["relation_to_topic"] = attributedRelationToTopic
        }

        if let additionalInsights = fields.additionalInsights,
           let attributedAdditionalInsights = markdownToAccessibleAttributedString(additionalInsights, textStyle: "UIFontTextStyleBody")
        {
            attributedStrings["additional_insights"] = attributedAdditionalInsights
        }

        return attributedStrings
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

                                // Convert markdown fields to rich text
                                self.convertMarkdownFieldsToRichText(for: notification)
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

                            // Convert markdown fields to rich text for the new notification
                            self.convertMarkdownFieldsToRichText(for: notification)

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
            // Already has full content, ensure rich text conversions exist
            convertMarkdownToRichTextIfNeeded(for: notification)
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
            if let processedArticle = processedArticle {
                try await shared.addOrUpdateArticlesWithExtendedData([(
                    title: processedArticle.title,
                    body: processedArticle.body, // Ensure this is a String
                    jsonURL: processedArticle.jsonURL,
                    topic: processedArticle.topic,
                    articleTitle: processedArticle.articleTitle,
                    affected: processedArticle.affected,
                    domain: processedArticle.domain,
                    pubDate: processedArticle.pubDate,
                    sourcesQuality: processedArticle.sourcesQuality,
                    argumentQuality: processedArticle.argumentQuality,
                    sourceType: processedArticle.sourceType,
                    sourceAnalysis: processedArticle.sourceAnalysis,
                    quality: processedArticle.quality,
                    summary: processedArticle.summary,
                    criticalAnalysis: processedArticle.criticalAnalysis,
                    logicalFallacies: processedArticle.logicalFallacies,
                    relationToTopic: processedArticle.relationToTopic,
                    additionalInsights: processedArticle.additionalInsights,
                    engineStats: processedArticle.engineStats,
                    similarArticles: processedArticle.similarArticles
                )])
            } else {
                print("Skipping article update: processedArticle is nil")
            }

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
