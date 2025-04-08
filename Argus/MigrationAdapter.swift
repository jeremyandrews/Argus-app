import Foundation
import SwiftData
import UIKit

/// Migration adapter to enable transition to modern architecture components
/// This provides backward compatibility while we migrate to BackgroundTaskManager and ArticleService
class MigrationAdapter {
    static let shared = MigrationAdapter()

    // MARK: - Dependencies

    private let backgroundTaskManager: BackgroundTaskManager
    private let articleService: ArticleService

    // MARK: - Initialization

    init(backgroundTaskManager: BackgroundTaskManager = .shared, articleService: ArticleService = .shared) {
        self.backgroundTaskManager = backgroundTaskManager
        self.articleService = articleService
    }

    // MARK: - Legacy Compatibility Methods

    /// Processes an article directly from the server - legacy compatibility method
    /// - Parameter jsonURL: The JSON URL of the article to process
    /// - Returns: True if successful, false otherwise
    func directProcessArticle(jsonURL: String) async -> Bool {
        do {
            // Use the ArticleService's processArticleData method via APIClient
            let article = try await APIClient.shared.fetchArticleByURL(jsonURL: jsonURL)

            // Safely unwrap optional article
            if let article = article {
                let processed = try await articleService.processArticleData([article])
                return processed > 0
            } else {
                ModernizationLogger.log(.warning, component: .migration,
                                        message: "No article data found for URL: \(jsonURL)")
                return false
            }
        } catch {
            AppLogger.sync.error("Failed to process article \(jsonURL): \(error)")
            return false
        }
    }

    /// Processes multiple articles via ArticleService - legacy batch processing compatibility method
    /// - Parameter urls: Array of JSON URLs to process
    func processArticlesDirectly(urls: [String]) async {
        guard !urls.isEmpty else { return }

        // Process in batches of 10 (as BackgroundTaskManager does)
        let batchSize = 10
        let uniqueUrls = Array(Set(urls))

        for batch in stride(from: 0, to: uniqueUrls.count, by: batchSize) {
            let end = min(batch + batchSize, uniqueUrls.count)
            let batchUrls = Array(uniqueUrls[batch ..< end])

            // For each URL, fetch and process the article
            var processed = 0

            for url in batchUrls {
                do {
                    let article = try await APIClient.shared.fetchArticleByURL(jsonURL: url)

                    // Safely unwrap optional article
                    if let article = article {
                        processed += try await articleService.processArticleData([article])
                    } else {
                        ModernizationLogger.log(.warning, component: .migration,
                                                message: "No article data found for URL: \(url)")
                    }
                } catch {
                    AppLogger.sync.error("Failed to process article \(url): \(error)")
                }
            }

            AppLogger.sync.debug("Processed batch of \(batchUrls.count) articles, successfully added \(processed)")

            // Short pause between batches to avoid overwhelming the system
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Update badge count
        await MainActor.run {
            NotificationUtils.updateAppBadgeCount()
        }
    }

    /// Performs database maintenance - legacy maintenance method compatibility
    /// - Parameter timeLimit: Optional time limit for the operation
    func performScheduledMaintenance(timeLimit: TimeInterval? = nil) async {
        do {
            try await articleService.performQuickMaintenance(timeLimit: timeLimit ?? 60)
        } catch {
            AppLogger.sync.error("Error performing maintenance: \(error)")
        }
    }

    /// Legacy compatibility method for registering background tasks
    func registerBackgroundTasks() {
        backgroundTaskManager.registerBackgroundTasks()
    }

    /// Legacy compatibility method for scheduling background refreshes
    func scheduleBackgroundFetch() {
        backgroundTaskManager.scheduleBackgroundRefresh()
    }

    /// Legacy compatibility method for scheduling background processing
    func scheduleBackgroundSync() {
        backgroundTaskManager.scheduleBackgroundProcessing()
    }

    /// Legacy compatibility method for triggering a manual synchronization
    func manualSync() async -> Bool {
        do {
            _ = try await articleService.performBackgroundSync()
            return true
        } catch {
            AppLogger.sync.error("Manual sync failed: \(error)")
            return false
        }
    }

    /// Legacy compatibility method for finding existing articles
    func findExistingArticle(jsonURL: String, articleID: UUID? = nil, articleURL _: String? = nil) async -> NotificationData? {
        do {
            if let articleID = articleID {
                return try await articleService.fetchArticle(byId: articleID)
            } else {
                return try await articleService.fetchArticle(byJsonURL: jsonURL)
            }
        } catch {
            return nil
        }
    }

    /// Legacy compatibility method for checking if an article exists
    func standardizedArticleExistsCheck(jsonURL: String, articleID: UUID? = nil, articleURL: String? = nil) async -> Bool {
        return await findExistingArticle(jsonURL: jsonURL, articleID: articleID, articleURL: articleURL) != nil
    }

    /// Log a deprecation warning for methods that should no longer be used
    private func logDeprecationWarning(_ method: String) {
        AppLogger.sync.warning("⚠️ DEPRECATED: \(method) is deprecated and will be removed in a future update. Use BackgroundTaskManager or ArticleService instead.")
    }
}
