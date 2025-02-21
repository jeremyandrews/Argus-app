import Foundation
import SwiftData

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
        @MainActor func fetchRecentArticles() async throws -> [SeenArticle] {
            let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
            let context = ArgusApp.sharedModelContainer.mainContext
            return try context.fetch(FetchDescriptor<SeenArticle>(
                predicate: #Predicate { $0.date >= oneDayAgo }
            ))
        }

        do {
            // Only wrap the network call in timeout, not the whole function
            let recentArticles = try await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            try await withTimeout(seconds: 10) {
                let url = URL(string: "https://api.arguspulse.com/articles/sync")!
                let payload = ["seen_articles": jsonUrls]
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
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
        await MainActor.run {
            do {
                let context = ArgusApp.sharedModelContainer.mainContext
                let existingURLs = (try? context.fetch(FetchDescriptor<NotificationData>()))?.map { $0.json_url } ?? []
                let existingSeenURLs = (try? context.fetch(FetchDescriptor<SeenArticle>()))?.map { $0.json_url } ?? []

                var newNotifications: [NotificationData] = []
                var newSeenArticles: [SeenArticle] = []

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
                    Task { @MainActor in
                        NotificationUtils.updateAppBadgeCount()
                    }
                }
            } catch {
                print("Failed to insert articles: \(error)")
            }
        }
    }

    func fetchAndSaveUnseenArticles(from urls: [String]) async {
        await withTaskGroup(of: (String, Data?).self) { group in
            for urlString in urls {
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

            var articlesToInsert: [(title: String, body: String, jsonURL: String, topic: String?, articleTitle: String, affected: String, domain: String?, pubDate: Date?)] = []

            for await (urlString, data) in group {
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let title = json["tiny_title"] as? String ?? "Untitled"
                let body = json["tiny_summary"] as? String ?? "No content available"
                let topic = json["topic"] as? String
                let articleTitle = json["title"] as? String ?? "No article title"
                let affected = json["affected"] as? String ?? ""
                let domain = URL(string: json["url"] as? String ?? "")?.host
                let pubDate = (json["pub_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

                articlesToInsert.append((title, body, urlString, topic, articleTitle, affected, domain, pubDate))
            }

            // Database operations shouldn't have timeouts
            try? await self.addOrUpdateArticles(articlesToInsert)
        }
    }
}
