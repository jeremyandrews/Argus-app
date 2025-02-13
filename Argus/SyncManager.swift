import Foundation
import SwiftData

@MainActor
class SyncManager {
    static let shared = SyncManager()
    private init() {}

    func sendRecentArticlesToServer() async {
        let context = ArgusApp.sharedModelContainer.mainContext
        let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        do {
            // Fetch recent SeenArticle entries
            let recentArticles = try context.fetch(
                FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.date >= oneDayAgo })
            )
            let jsonUrls = recentArticles.map { $0.json_url }
            let url = URL(string: "https://api.arguspulse.com/articles/sync ")!
            let payload = ["seen_articles": jsonUrls]
            do {
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
                // Decode the server response
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)
                if let unseenUrls = serverResponse["unseen_articles"] {
                    await fetchAndSaveUnseenArticles(from: unseenUrls)
                } else {
                    print("No unseen articles received.")
                }
            } catch {
                print("Failed to sync articles: (error)")
            }
        } catch {
            print("Failed to fetch recent articles: (error)")
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
        let context = ArgusApp.sharedModelContainer.mainContext

        // First, fetch all existing URLs in one go
        let existingURLs = try context.fetch(
            FetchDescriptor<NotificationData>()
        ).map { $0.json_url }

        let existingSeenURLs = try context.fetch(
            FetchDescriptor<SeenArticle>()
        ).map { $0.json_url }

        // Prepare arrays for batch insertion
        var newNotifications: [NotificationData] = []
        var newSeenArticles: [SeenArticle] = []

        // Filter and prepare new articles
        for article in articles {
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

        // Single transaction for batch insertion
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
    }

    // fetchAndSaveUnseenArticles now just collects and calls addOrUpdateArticles
    func fetchAndSaveUnseenArticles(from urls: [String]) async {
        var articlesToInsert: [(
            title: String,
            body: String,
            jsonURL: String,
            topic: String?,
            articleTitle: String,
            affected: String,
            domain: String?,
            pubDate: Date?
        )] = []

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                print("Invalid URL: \(urlString)")
                continue
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("Invalid JSON structure for \(urlString)")
                    continue
                }

                let title = json["tiny_title"] as? String ?? "Untitled"
                let body = json["tiny_summary"] as? String ?? "No content available"
                let topic = json["topic"] as? String
                let articleTitle = json["title"] as? String ?? "No article title"
                let affected = json["affected"] as? String ?? ""
                let articleURL = json["url"] as? String ?? "none"
                let domain = URL(string: articleURL)?.host

                var pubDate: Date?
                if let pubDateString = json["pub_date"] as? String {
                    let isoFormatter = ISO8601DateFormatter()
                    pubDate = isoFormatter.date(from: pubDateString)
                }

                articlesToInsert.append((
                    title: title,
                    body: body,
                    jsonURL: urlString,
                    topic: topic,
                    articleTitle: articleTitle,
                    affected: affected,
                    domain: domain,
                    pubDate: pubDate
                ))
            } catch {
                print("Failed to fetch or process article \(urlString): \(error)")
            }
        }

        // Use the same insertion path as single articles
        do {
            try await addOrUpdateArticles(articlesToInsert)
        } catch {
            print("Failed batch-inserting articles: \(error)")
        }
    }
}
