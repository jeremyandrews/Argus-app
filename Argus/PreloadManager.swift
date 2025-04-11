import Foundation
import SwiftUI

/// Handles preloading articles before they are visible to improve
/// scroll performance and prevent UI jitter during markdown processing
class PreloadManager {
    // Singleton instance
    static let shared = PreloadManager()

    // Track preloaded article IDs
    private var preloadedIDs = Set<UUID>()
    private let preloadLock = NSLock()

    // Current preload task
    private var preloadTask: Task<Void, Never>?

    private init() {}

    // Mark an article as preloaded - thread-safe using MainActor
    @MainActor
    func markAsPreloaded(_ id: UUID) {
        preloadedIDs.insert(id)
    }

    // Check if an article is preloaded - thread-safe using MainActor
    @MainActor
    func isPreloaded(_ id: UUID) -> Bool {
        return preloadedIDs.contains(id)
    }

    // Preload a batch of articles that will likely be viewed soon
    func preloadArticles(_ articles: [ArticleModel], currentIndex: Int) {
        // Cancel any existing preload task
        preloadTask?.cancel()

        // Start a new preload task
        preloadTask = Task(priority: .background) {
            // Calculate which articles to preload (next few after current)
            let startIndex = currentIndex + 1
            let endIndex = min(startIndex + 5, articles.count)

            guard startIndex < articles.count else { return }

            // Preload each article
            for index in startIndex ..< endIndex {
                if Task.isCancelled { break }

                let article = articles[index]

                // Skip if already preloaded
                if await isPreloaded(article.id) {
                    continue
                }

                // Mark as preloaded
                await markAsPreloaded(article.id)

                // Use ArticleOperations to process blob generation
                let operations = ArticleOperations()

                // Extract the article ID (which is Sendable) to use inside MainActor
                let articleId = article.id

                // Generate blobs for key fields - everything related to ArticleModel must run on MainActor
                // for Swift 6 sendability compliance
                // Use Task with @MainActor annotation to handle async operations on the MainActor
                await Task { @MainActor in
                    // Within MainActor, get a fresh ArticleModel with context
                    if let articleWithContext = await operations.getArticleModelWithContext(byId: articleId) {
                        // These operations already run on the main actor since they involve NSAttributedString
                        _ = operations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                        _ = operations.getAttributedContent(for: .body, from: articleWithContext, createIfMissing: true)

                        AppLogger.database.debug("✅ Preloaded blobs for article \(articleId)")
                    } else {
                        AppLogger.database.warning("⚠️ Could not preload article \(articleId) - context not available")
                    }
                }.value

                // Schedule processing through the queue manager as a fallback
                await ProcessingQueueManager.shared.scheduleProcessing(for: article.id)

                // Small delay between articles
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
    }
}
