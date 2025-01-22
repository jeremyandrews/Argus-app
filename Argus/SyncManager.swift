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
            // Fetch all articles to inspect the table
            let allArticles = try context.fetch(FetchDescriptor<SeenArticle>())
            print("All SeenArticle entries: \(allArticles)")

            let recentArticles = try context.fetch(
                FetchDescriptor<SeenArticle>(predicate: #Predicate { $0.date >= twentyFourHoursAgo })
            )
            print("Recent SeenArticle entries: \(recentArticles)")

            let jsonUrls = recentArticles.map { $0.json_url }
            print("jsonUrls: \(jsonUrls)")

            guard let token = UserDefaults.standard.string(forKey: "jwtToken") else {
                print("JWT token not available.")
                return
            }

            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = ["seen_articles": jsonUrls]
            print("Payload being sent: \(payload)")
            request.httpBody = try JSONEncoder().encode(payload)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    print("Failed to sync articles. Server responded with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                    return
                }

                let serverResponse = try JSONDecoder().decode([String].self, from: data)
                print("Articles not seen by client: \(serverResponse)")
            } catch {
                print("Failed to sync articles: \(error)")
            }

        } catch {
            print("Failed to fetch recent articles: \(error)")
        }
    }
}
