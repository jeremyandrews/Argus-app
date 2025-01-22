import Foundation
import SwiftData

@MainActor
class SyncManager {
    static let shared = SyncManager()

    private init() {}

    func sendRecentArticlesToServer() async {
        let context = ArgusApp.sharedModelContainer.mainContext
        let twentyFourHoursAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()

        do {
            // Fetch recent articles
            let recentArticles = try context.fetch(
                FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.date >= twentyFourHoursAgo })
            )
            let jsonUrls = recentArticles.map { $0.json_url }
            print("Payload being sent: \(jsonUrls)")

            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            let payload = ["seen_articles": jsonUrls]

            do {
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
                // Adjust decoding for dictionary response
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)
                if let unseenArticles = serverResponse["unseen_articles"] {
                    print("Unseen articles: \(unseenArticles)")
                } else {
                    print("Server response did not contain 'unseen_articles'.")
                }
            } catch {
                print("Failed to sync articles: \(error)")
            }
        } catch {
            print("Failed to fetch recent articles: \(error)")
        }
    }
}
