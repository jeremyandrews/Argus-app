import Foundation
import SwiftData
import UIKit

/// Migration adapter to help transition from SyncManager to BackgroundTaskManager and ArticleService
/// This provides backward compatibility while we refactor remaining legacy code references
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

    // MARK: - SyncManager Compatibility Methods

    /// Processes an article directly from the server - compatibility method for SyncManager.directProcessArticle
    /// - Parameter jsonURL: The JSON URL of the article to process
    /// - Returns: True if successful, false otherwise
    func directProcessArticle(jsonURL: String) async -> Bool {
        do {
            // Use the ArticleService's processArticleData method via APIClient
            let article = try await APIClient.shared.fetchArticleByURL(jsonURL: jsonURL)
            let processed = try await articleService.processArticleData([article])
            return processed > 0
        } catch {
            AppLogger.sync.error("Failed to process article \(jsonURL): \(error)")
            return false
        }
    }

    /// Processes multiple articles via ArticleService - compatibility method for SyncManager.processArticlesDirectly
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
                    processed += try await articleService.processArticleData([article])
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

    /// Performs database maintenance - compatibility method for SyncManager.performScheduledMaintenance
    /// - Parameter timeLimit: Optional time limit for the operation
    func performScheduledMaintenance(timeLimit: TimeInterval? = nil) async {
        do {
            try await articleService.performQuickMaintenance(timeLimit: timeLimit ?? 60)
        } catch {
            AppLogger.sync.error("Error performing maintenance: \(error)")
        }
    }

    /// Compatibility method for SyncManager.registerBackgroundTasks
    func registerBackgroundTasks() {
        backgroundTaskManager.registerBackgroundTasks()
    }

    /// Compatibility method for SyncManager.scheduleBackgroundFetch
    func scheduleBackgroundFetch() {
        backgroundTaskManager.scheduleBackgroundRefresh()
    }

    /// Compatibility method for SyncManager.scheduleBackgroundSync
    func scheduleBackgroundSync() {
        backgroundTaskManager.scheduleBackgroundProcessing()
    }

    /// Compatibility method for SyncManager.manualSync
    func manualSync() async -> Bool {
        do {
            _ = try await articleService.performBackgroundSync()
            return true
        } catch {
            AppLogger.sync.error("Manual sync failed: \(error)")
            return false
        }
    }

    /// Compatibility method for SyncManager.findExistingArticle
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

    /// Compatibility method for SyncManager.standardizedArticleExistsCheck
    func standardizedArticleExistsCheck(jsonURL: String, articleID: UUID? = nil, articleURL: String? = nil) async -> Bool {
        return await findExistingArticle(jsonURL: jsonURL, articleID: articleID, articleURL: articleURL) != nil
    }

    /// Log a deprecation warning for methods that should no longer be used
    private func logDeprecationWarning(_ method: String) {
        AppLogger.sync.warning("⚠️ DEPRECATED: \(method) is deprecated and will be removed in a future update. Use BackgroundTaskManager or ArticleService instead.")
    }
}
