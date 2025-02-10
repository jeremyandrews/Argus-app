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

            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
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
                print("Failed to sync articles: \(error)")
            }
        } catch {
            print("Failed to fetch recent articles: \(error)")
        }
    }

    func fetchAndSaveUnseenArticles(from urls: [String]) async {
        for urlString in urls {
            guard let url = URL(string: urlString) else {
                print("Invalid URL: \(urlString)")
                continue
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("Invalid JSON structure for URL: \(urlString)")
                    continue
                }

                let title = json["tiny_title"] as? String ?? "Untitled"
                let body = json["tiny_summary"] as? String ?? "No content available"
                let topic = json["topic"] as? String
                let articleTitle = json["title"] as? String ?? "No article title"
                let affected = json["affected"] as? String ?? ""
                let article_url = json["url"] as? String ?? "none"
                let domain = URL(string: article_url)?.host

                var pubDate: Date?
                if let pubDateString = json["pub_date"] as? String {
                    let isoFormatter = ISO8601DateFormatter()
                    if let parsed = isoFormatter.date(from: pubDateString) {
                        pubDate = parsed
                    }
                }

                // Then pass it to saveNotification
                saveNotification(
                    title: title,
                    body: body,
                    json_url: urlString,
                    topic: topic,
                    articleTitle: articleTitle,
                    affected: affected,
                    domain: domain,
                    pubDate: pubDate,
                    suppressBadgeUpdate: true
                )
            } catch {
                print("Failed to fetch or save unseen article for URL \(urlString): \(error)")
            }
        }

        // Update the badge just once at the end:
        NotificationUtils.updateAppBadgeCount()
    }

    func saveNotification(
        title: String,
        body: String,
        json_url: String,
        topic: String?,
        articleTitle: String,
        affected: String,
        domain: String?,
        pubDate: Date? = nil, // new parameter
        suppressBadgeUpdate: Bool = false
    ) {
        let context = ArgusApp.sharedModelContainer.mainContext

        do {
            try context.transaction { [context] in
                // Check for existing
                let existingNotification = try context.fetch(
                    FetchDescriptor<NotificationData>(predicate: #Predicate { $0.json_url == json_url })
                ).first

                let existingSeenArticle = try context.fetch(
                    FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.json_url == json_url })
                ).first

                guard existingNotification == nil, existingSeenArticle == nil else {
                    print("Duplicate json_url found, skipping: \(json_url)")
                    return
                }

                // Create the new NotificationData
                let newNotification = NotificationData(
                    date: Date(), // the date Argus received it
                    title: title,
                    body: body,
                    json_url: json_url,
                    topic: topic,
                    article_title: articleTitle,
                    affected: affected,
                    domain: domain,
                    pub_date: pubDate ?? Date()
                )

                context.insert(newNotification)

                // Also create a SeenArticle entry
                let seenArticle = SeenArticle(
                    id: newNotification.id,
                    json_url: json_url,
                    date: newNotification.date
                )
                context.insert(seenArticle)
            }

            if !suppressBadgeUpdate {
                NotificationUtils.updateAppBadgeCount()
            }

        } catch {
            print("Failed to save notification or seen article: \(error)")
        }
    }
}
