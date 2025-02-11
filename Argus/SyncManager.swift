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
        let context = ArgusApp.sharedModelContainer.mainContext

        // We’ll collect new articles in memory first:
        var newNotifications = [NotificationData]()
        var newSeenArticles = [SeenArticle]()

        // (Optional) First, fetch all existing json_url values in one go
        // so we can skip duplicates without doing an individual fetch each time:
        let existingURLs = try? context.fetch(
            FetchDescriptor<NotificationData>()
        ).map { $0.json_url }
        let existingSeenURLs = try? context.fetch(
            FetchDescriptor<SeenArticle>()
        ).map { $0.json_url }

        // Now loop over each URL, but *do not* insert right away:
        for urlString in urls {
            // If you like, skip duplicates in memory:
            if existingURLs?.contains(urlString) == true || existingSeenURLs?.contains(urlString) == true {
                print("Duplicate found, skipping \(urlString)")
                continue
            }

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

                // Extract fields:
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

                // Prepare the objects, but do NOT insert them yet:
                let newNotification = NotificationData(
                    date: Date(),
                    title: title,
                    body: body,
                    json_url: urlString,
                    topic: topic,
                    article_title: articleTitle,
                    affected: affected,
                    domain: domain,
                    pub_date: pubDate ?? Date()
                )
                let seenArticle = SeenArticle(
                    id: newNotification.id,
                    json_url: urlString,
                    date: newNotification.date
                )

                newNotifications.append(newNotification)
                newSeenArticles.append(seenArticle)

            } catch {
                print("Failed to fetch or parse article \(urlString): \(error)")
            }
        }

        // Now do *one* transaction to insert everything:
        do {
            try context.transaction {
                for n in newNotifications {
                    context.insert(n)
                }
                for s in newSeenArticles {
                    context.insert(s)
                }
            }
        } catch {
            print("Failed batch-inserting unseen articles: \(error)")
        }

        // Update the badge exactly once at the end
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
