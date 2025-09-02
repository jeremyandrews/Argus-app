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
    // Enhanced to preload Next-5 and Previous-5 articles for faster navigation
    // Swift 6 compatible version using article IDs
    func preloadArticlesByIds(_ articleIds: [UUID], currentIndex: Int) {
        // Cancel any existing preload task
        preloadTask?.cancel()

        // Start a new preload task
        preloadTask = Task(priority: .background) {
            // Calculate which articles to preload (5 in each direction from current)
            let nextStartIndex = currentIndex + 1
            let nextEndIndex = min(nextStartIndex + 5, articleIds.count)
            let prevStartIndex = max(0, currentIndex - 5)
            let prevEndIndex = currentIndex

            AppLogger.database.debug("🚀 PreloadManager: Preloading articles around index \(currentIndex)")
            AppLogger.database.debug("   Next: \(nextStartIndex) to \(nextEndIndex-1)")
            AppLogger.database.debug("   Prev: \(prevStartIndex) to \(prevEndIndex-1)")

            var preloadedCount = 0

            // Preload next 5 articles
            if nextStartIndex < articleIds.count {
                for index in nextStartIndex ..< nextEndIndex {
                    if Task.isCancelled { break }

                    let articleId = articleIds[index]

                    // Skip if already preloaded (no-op for already preloaded articles)
                    if await isPreloaded(articleId) {
                        AppLogger.database.debug("⚡ Article at index \(index) already preloaded, skipping")
                        continue
                    }

                    // Mark as preloaded
                    await markAsPreloaded(articleId)

                    await preloadSingleArticleById(articleId, index: index)
                    preloadedCount += 1

                    // Small delay between articles
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
            }

            // Preload previous 5 articles  
            if prevEndIndex > prevStartIndex {
                for index in (prevStartIndex ..< prevEndIndex).reversed() {
                    if Task.isCancelled { break }

                    let articleId = articleIds[index]

                    // Skip if already preloaded (no-op for already preloaded articles)
                    if await isPreloaded(articleId) {
                        AppLogger.database.debug("⚡ Article at index \(index) already preloaded, skipping")
                        continue
                    }

                    // Mark as preloaded
                    await markAsPreloaded(articleId)

                    await preloadSingleArticleById(articleId, index: index)
                    preloadedCount += 1

                    // Small delay between articles
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
            }

            AppLogger.database.debug("✅ PreloadManager: Completed preloading \(preloadedCount) articles")
        }
    }
    
    // Legacy method maintained for backward compatibility
    func preloadArticles(_ articles: [ArticleModel], currentIndex: Int) {
        let articleIds = articles.map { $0.id }
        preloadArticlesByIds(articleIds, currentIndex: currentIndex)
    }

    // Helper method to preload a single article by ID (Swift 6 compatible)
    private func preloadSingleArticleById(_ articleId: UUID, index: Int) async {
        // Use ArticleOperations to process blob generation
        let operations = ArticleOperations()

        // Generate blobs for key fields - everything related to ArticleModel must run on MainActor
        // for Swift 6 sendability compliance
        await Task { @MainActor in
            // Within MainActor, get a fresh ArticleModel with context
            if let articleWithContext = await operations.getArticleModelWithContext(byId: articleId) {
                // These operations already run on the main actor since they involve NSAttributedString
                _ = operations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                _ = operations.getAttributedContent(for: .body, from: articleWithContext, createIfMissing: true)
                
                // Also preload summary since it's expanded by default in NewsDetailView
                _ = operations.getAttributedContent(for: .summary, from: articleWithContext, createIfMissing: true)

                AppLogger.database.debug("✅ Preloaded title, body, and summary blobs for article \(articleId) at index \(index)")
            } else {
                AppLogger.database.warning("⚠️ Could not preload article \(articleId) at index \(index) - context not available")
            }
        }.value

        // Schedule processing through the queue manager as a fallback
        await ProcessingQueueManager.shared.scheduleProcessing(for: articleId)
    }
}
