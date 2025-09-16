import Foundation
import SwiftUI

/// Priority levels for preloading operations
enum PreloadPriority: String {
    case critical = "critical"  // For list view essentials (tiny_title, tiny_summary)
    case high = "high"         // For detail view navigation (summaries)
    case medium = "medium"     // For general preloading
    case low = "low"           // For background preloading
}

/// Types of preloading operations to optimize resource usage
enum PreloadType: String {
    case listViewEssentials    // Only title + summary for list display
    case summaryOnly          // Only summary for detail navigation
    case fullContent         // All content types (title, body, summary)
}

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
    // ENHANCED: Preload Next-8 and Previous-8 articles with prioritization for faster navigation
    // Swift 6 compatible version using article IDs
    func preloadArticlesByIds(_ articleIds: [UUID], currentIndex: Int) {
        // Cancel any existing preload task
        preloadTask?.cancel()

        // Start a new preload task with utility priority to avoid competing with UI
        preloadTask = Task(priority: .utility) {
            // PHASE 5: Optimize preloading - reduce from 6 to 2 articles (immediate neighbors only)
            // This eliminates excessive database operations that compete with UI responsiveness
            let nextIndex = currentIndex + 1
            let prevIndex = currentIndex - 1

            AppLogger.database.debug("🚀 PreloadManager: Phase 5 optimized preloading - 2 articles only around index \(currentIndex)")
            AppLogger.database.debug("   Next: \(nextIndex) (1 article)")
            AppLogger.database.debug("   Prev: \(prevIndex) (1 article)")

            var preloadedCount = 0

            // Preload next article (immediate neighbor)
            if nextIndex < articleIds.count {
                let articleId = articleIds[nextIndex]

                // Skip if already preloaded
                if await isPreloaded(articleId) {
                    AppLogger.database.debug("⚡ Next article at index \(nextIndex) already preloaded, skipping")
                } else {
                    await markAsPreloaded(articleId)
                    await preloadSingleArticleById(articleId, index: nextIndex, priority: .high, type: .summaryOnly)
                    preloadedCount += 1
                    AppLogger.database.debug("✅ Preloaded next article at index \(nextIndex)")
                }
            }

            // Preload previous article (immediate neighbor)
            if prevIndex >= 0 {
                let articleId = articleIds[prevIndex]

                if await isPreloaded(articleId) {
                    AppLogger.database.debug("⚡ Previous article at index \(prevIndex) already preloaded, skipping")
                } else {
                    await markAsPreloaded(articleId)
                    await preloadSingleArticleById(articleId, index: prevIndex, priority: .high, type: .summaryOnly)
                    preloadedCount += 1
                    AppLogger.database.debug("✅ Preloaded previous article at index \(prevIndex)")
                }
            }

            AppLogger.database.debug("✅ PreloadManager: Enhanced preloading completed - \(preloadedCount) articles processed")
        }
    }
    
    // Legacy method maintained for backward compatibility
    func preloadArticles(_ articles: [ArticleModel], currentIndex: Int) {
        let articleIds = articles.map { $0.id }
        preloadArticlesByIds(articleIds, currentIndex: currentIndex)
    }

    // Helper method to preload a single article by ID with priority levels and type optimization (Swift 6 compatible)
    private func preloadSingleArticleById(_ articleId: UUID, index: Int, priority: PreloadPriority = .medium, type: PreloadType = .fullContent) async {
        // Use ArticleOperations to process blob generation
        let operations = ArticleOperations()

        // Extract priority and type strings early to avoid repeated access
        let priorityString = priority.rawValue
        let typeString = type.rawValue

        // Execute preloading operations on MainActor to avoid Sendable issues
        _ = await MainActor.run {
            Task { @MainActor in
                // Get the article model on MainActor to avoid crossing isolation boundaries
                if let articleWithContext = await operations.getArticleModelWithContext(byId: articleId) {
                    switch type {
                    case .listViewEssentials:
                        // Only generate title and summary for list view display
                        _ = operations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                        _ = operations.getAttributedContent(for: .summary, from: articleWithContext, createIfMissing: true)
                        
                    case .summaryOnly:
                        // Only generate summary for detail view navigation
                        _ = operations.getAttributedContent(for: .summary, from: articleWithContext, createIfMissing: true)
                        
                    case .fullContent:
                        // Generate all content types for comprehensive preloading
                        _ = operations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                        _ = operations.getAttributedContent(for: .body, from: articleWithContext, createIfMissing: true)
                        _ = operations.getAttributedContent(for: .summary, from: articleWithContext, createIfMissing: true)
                    }

                    AppLogger.database.debug("✅ Preloaded \(typeString) blobs for article \(articleId) at index \(index) (priority: \(priorityString))")
                } else {
                    AppLogger.database.warning("⚠️ Could not preload article \(articleId) at index \(index) - context not available (priority: \(priorityString), type: \(typeString))")
                }
                
                // Schedule processing through the queue manager as a fallback
                ProcessingQueueManager.shared.scheduleProcessing(for: articleId)
            }
        }
    }
    
    // MARK: - Specialized Preloading Methods
    
    /// Ensures all visible articles have their essential fields (title, summary) preloaded
    /// This eliminates spinner states in the list view
    func preloadListViewEssentials(for articles: [ArticleModel]) async {
        AppLogger.database.debug("🔥 PreloadManager: Starting critical list view preloading for \(articles.count) articles")
        
        var criticalTasks: [Task<Void, Never>] = []
        
        for (index, article) in articles.enumerated() {
            let task = Task {
                await self.preloadSingleArticleById(article.id, index: index, priority: .critical, type: .listViewEssentials)
                await self.markAsPreloaded(article.id)
            }
            criticalTasks.append(task)
        }
        
        // Wait for all critical preloading to complete
        for task in criticalTasks {
            await task.value
        }
        
        AppLogger.database.debug("✅ PreloadManager: Completed critical list view preloading for \(articles.count) articles")
    }
    
    /// Preloads summaries for articles around the current position for smooth detail view navigation
    func preloadDetailViewSummaries(_ currentArticleId: UUID, articles: [ArticleModel]) async {
        guard !articles.isEmpty else { return }
        
        guard let currentIndex = articles.firstIndex(where: { $0.id == currentArticleId }) else {
            AppLogger.database.debug("PreloadManager: Current article not found for detail view preloading")
            return
        }
        
        AppLogger.database.debug("🔍 PreloadManager: Starting detail view summary preloading around index \(currentIndex)")
        
        var summaryTasks: [Task<Void, Never>] = []
        
        // Preload summaries 5 ahead and 5 behind for smooth navigation
        let detailPreloadDistance = 5
        let startIndex = max(0, currentIndex - detailPreloadDistance)
        let endIndex = min(articles.count - 1, currentIndex + detailPreloadDistance)
        
        for index in startIndex...endIndex {
            if index == currentIndex { continue } // Skip current article
            
            let article = articles[index]
            let task = Task {
                await self.preloadSingleArticleById(article.id, index: index, priority: .high, type: .summaryOnly)
                await self.markAsPreloaded(article.id)
            }
            summaryTasks.append(task)
        }
        
        // Execute all summary preloading tasks
        for task in summaryTasks {
            await task.value
        }
        
        AppLogger.database.debug("✅ PreloadManager: Completed detail view summary preloading (\(summaryTasks.count) articles)")
    }
    
    /// Preloads the top article's summary when switching topics
    func preloadTopicFirstArticle(from articles: [ArticleModel]) async {
        guard let firstArticle = articles.first else { return }
        
        AppLogger.database.debug("🏷️ PreloadManager: Preloading first article summary for topic switch")
        
        let task = Task {
            await self.preloadSingleArticleById(firstArticle.id, index: 0, priority: .high, type: .summaryOnly)
            await self.markAsPreloaded(firstArticle.id)
        }
        
        await task.value
        
        AppLogger.database.debug("✅ PreloadManager: Completed topic first article preloading")
    }
}
