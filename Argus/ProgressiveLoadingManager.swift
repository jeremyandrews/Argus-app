import Foundation
import SwiftData
import SwiftUI

/// Manages progressive loading of article content using standard iOS 18+ patterns
/// Loads only what's visible and preloads adjacent content
@MainActor
final class ProgressiveLoadingManager: ObservableObject {
    
    // MARK: - Properties
    
    /// Articles currently in the viewport
    @Published private(set) var visibleArticles: Set<UUID> = []
    
    /// Articles that have been loaded
    private var loadedArticles: Set<UUID> = []
    
    /// Articles currently being loaded
    private var loadingArticles: Set<UUID> = []
    
    /// Preload distance (number of items before/after visible range)
    private let preloadDistance = 3
    
    /// Maximum concurrent loads
    private let maxConcurrentLoads = 3
    
    /// Article operations for loading content
    private let articleOperations = ArticleOperations()
    
    // MARK: - Public Methods
    
    /// Called when an article appears in the viewport
    func articleAppeared(_ article: ArticleModel) {
        visibleArticles.insert(article.id)
        
        // Load this article if needed
        loadArticleIfNeeded(article)
        
        // Preload adjacent articles
        Task {
            await preloadAdjacentArticles(around: article)
        }
    }
    
    /// Called when an article disappears from the viewport
    func articleDisappeared(_ article: ArticleModel) {
        visibleArticles.remove(article.id)
    }
    
    /// Check if an article's content is loaded
    func isLoaded(_ article: ArticleModel) -> Bool {
        return loadedArticles.contains(article.id)
    }
    
    /// Check if an article is currently loading
    func isLoading(_ article: ArticleModel) -> Bool {
        return loadingArticles.contains(article.id)
    }
    
    /// Reset the loading state (e.g., when filters change)
    func reset() {
        visibleArticles.removeAll()
        loadedArticles.removeAll()
        loadingArticles.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Load an article's content if it hasn't been loaded yet
    private func loadArticleIfNeeded(_ article: ArticleModel) {
        guard !loadedArticles.contains(article.id),
              !loadingArticles.contains(article.id),
              loadingArticles.count < maxConcurrentLoads else {
            return
        }
        
        loadingArticles.insert(article.id)
        
        Task {
            await loadArticleContent(article)
            
            await MainActor.run {
                loadingArticles.remove(article.id)
                loadedArticles.insert(article.id)
            }
        }
    }
    
    /// Load the actual content for an article
    private func loadArticleContent(_ article: ArticleModel) async {
        // Load only essential content first (title and summary)
        guard let articleModel = await articleOperations.getArticleModelWithContext(byId: article.id) else {
            return
        }
        
        // Generate rich text for title and summary only (not body yet)
        _ = articleOperations.getAttributedContent(for: .title, from: articleModel, createIfMissing: true)
        _ = articleOperations.getAttributedContent(for: .summary, from: articleModel, createIfMissing: true)
        
        // Quality metadata is already in the model, no need to fetch separately
        
        AppLogger.database.debug("Progressive load: Article \(article.id) essential content loaded")
    }
    
    /// Preload articles adjacent to the given article
    private func preloadAdjacentArticles(around article: ArticleModel) async {
        // This would need access to the articles array to find adjacent items
        // For now, just log that we would preload
        AppLogger.database.debug("Would preload \(self.preloadDistance) articles around \(article.id)")
    }
    
    /// Load full content for an article (when user is about to open it)
    func loadFullContent(for article: ArticleModel) async {
        guard let articleModel = await articleOperations.getArticleModelWithContext(byId: article.id) else {
            return
        }
        
        // Load all content including body and additional fields
        _ = articleOperations.getAttributedContent(for: .body, from: articleModel, createIfMissing: true)
        _ = articleOperations.getAttributedContent(for: .criticalAnalysis, from: articleModel, createIfMissing: true)
        _ = articleOperations.getAttributedContent(for: .sourceAnalysis, from: articleModel, createIfMissing: true)
        
        loadedArticles.insert(article.id)
        
        AppLogger.database.debug("Progressive load: Article \(article.id) full content loaded")
    }
}

// MARK: - View Modifiers

/// View modifier to handle progressive loading
struct ProgressiveLoadingModifier: ViewModifier {
    let article: ArticleModel
    @ObservedObject var loadingManager: ProgressiveLoadingManager
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                loadingManager.articleAppeared(article)
            }
            .onDisappear {
                loadingManager.articleDisappeared(article)
            }
    }
}

extension View {
    /// Apply progressive loading to a view for the given article
    func progressiveLoad(_ article: ArticleModel, with manager: ProgressiveLoadingManager) -> some View {
        self.modifier(ProgressiveLoadingModifier(article: article, loadingManager: manager))
    }
}
