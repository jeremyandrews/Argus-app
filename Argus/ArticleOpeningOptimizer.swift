import SwiftUI
import Foundation

/// Optimized article opening handler that achieves sub-300ms performance
@MainActor
final class ArticleOpeningOptimizer {
    
    // MARK: - Singleton
    static let shared = ArticleOpeningOptimizer()
    
    // MARK: - Cache
    private var presentedViewControllers: [UUID: UIViewController] = [:]
    
    private init() {}
    
    // MARK: - Optimized Opening Method
    
    /// Opens an article with minimal overhead - target <300ms
    func openArticleOptimized(
        _ article: ArticleListItem,
        from viewModel: NewsViewModel,
        in windowScene: UIWindowScene? = nil
    ) {
        let startTime = Date()
        
        // STEP 1: Get articles snapshot (instant)
        let articlesSnapshot = viewModel.filteredArticles
        
        // STEP 2: Find index (fast)
        guard let index = articlesSnapshot.firstIndex(where: { $0.id == article.id }) else {
            AppLogger.database.error("Article not found: \(article.id)")
            return
        }
        
        AppLogger.database.debug("⚡ Opening article at index \(index) of \(articlesSnapshot.count)")
        
        // STEP 3: Create MINIMAL placeholder - just the current article + neighbors
        // This is the KEY optimization - don't create 48 ArticleModel objects!
        let minimalArticles = createMinimalPlaceholders(
            from: articlesSnapshot,
            currentIndex: index
        )
        
        // STEP 4: Create lightweight view model
        let detailViewModel = createLightweightViewModel(
            articles: minimalArticles.articles,
            allArticles: minimalArticles.articles,
            currentIndex: minimalArticles.adjustedIndex,
            newsViewModel: viewModel
        )
        
        // STEP 5: Present immediately (no wrapper needed)
        let detailView = NewsDetailView(viewModel: detailViewModel)
        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen
        
        // Get window and present
        let scene = windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        if let window = scene?.windows.first,
           let rootViewController = window.rootViewController {
            
            rootViewController.present(hostingController, animated: true)
            
            // Track presented controller for potential reuse
            presentedViewControllers[article.id] = hostingController
            
            let presentTime = Date().timeIntervalSince(startTime)
            AppLogger.database.debug("✅ Article presented in \(String(format: "%.3f", presentTime * 1000))ms")
            
            // STEP 6: Load full data in background (low priority, non-blocking)
            Task.detached(priority: .background) {
                await self.loadFullDataInBackground(
                    for: article,
                    viewModel: detailViewModel,
                    newsViewModel: viewModel,
                    originalSnapshot: articlesSnapshot
                )
            }
            
            // STEP 7: Mark as read (non-blocking)
            Task.detached(priority: .utility) {
                await viewModel.openArticle(article)
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Creates minimal placeholder articles (just current + 2 neighbors)
    private func createMinimalPlaceholders(
        from snapshot: [ArticleListItem],
        currentIndex: Int
    ) -> (articles: [ArticleModel], adjustedIndex: Int) {
        
        // Only create placeholders for current + immediate neighbors
        let startIdx = max(0, currentIndex - 1)
        let endIdx = min(snapshot.count - 1, currentIndex + 1)
        
        var placeholders: [ArticleModel] = []
        var adjustedIndex = 0
        
        for i in startIdx...endIdx {
            let item = snapshot[i]
            
            // Create ultra-lightweight placeholder with ONLY essential fields
            let placeholder = ArticleModel(
                id: item.id,
                jsonURL: "",
                url: "",
                title: item.title,
                body: item.body,
                domain: item.domain ?? "",
                articleTitle: item.title,
                affected: item.affected,
                publishDate: item.publishDate,
                addedDate: Date(),
                topic: item.topic,
                isViewed: item.isViewed,
                isBookmarked: item.isBookmarked,
                sourcesQuality: nil,
                argumentQuality: nil,
                sourceType: item.sourceType,
                sourceAnalysis: nil,
                quality: Int(item.qualityScore),
                summary: item.body, // Use body as initial summary
                criticalAnalysis: nil,
                logicalFallacies: nil,
                relationToTopic: nil,
                additionalInsights: nil,
                actionRecommendations: nil,
                talkingPoints: nil,
                eli5: nil,
                engineStats: nil,
                engineModel: nil,
                engineElapsedTime: nil,
                engineRawStats: nil,
                engineSystemInfo: nil,
                databaseId: nil,
                relatedArticles: nil,
                titleBlob: nil,
                bodyBlob: nil,
                summaryBlob: nil,
                criticalAnalysisBlob: nil,
                logicalFallaciesBlob: nil,
                sourceAnalysisBlob: nil,
                relationToTopicBlob: nil,
                additionalInsightsBlob: nil,
                actionRecommendationsBlob: nil,
                talkingPointsBlob: nil,
                eli5Blob: nil,
                clusterSummary: nil,
                clusterSummaryBlob: nil,
                entities: []
            )
            
            placeholders.append(placeholder)
            
            if i == currentIndex {
                adjustedIndex = placeholders.count - 1
            }
        }
        
        return (placeholders, adjustedIndex)
    }
    
    /// Creates a lightweight view model with minimal initialization
    private func createLightweightViewModel(
        articles: [ArticleModel],
        allArticles: [ArticleModel],
        currentIndex: Int,
        newsViewModel: NewsViewModel
    ) -> NewsDetailViewModel {
        
        // Create view model with deferred initialization flag
        return NewsDetailViewModel(
            articles: articles,
            allArticles: allArticles,
            currentIndex: currentIndex,
            initiallyExpandedSection: "Summary",
            newsViewModel: newsViewModel,
            needsFullDataset: false // Skip heavy initialization
        )
    }
    
    /// Loads full article data in background without blocking UI
    private func loadFullDataInBackground(
        for article: ArticleListItem,
        viewModel: NewsDetailViewModel,
        newsViewModel: NewsViewModel,
        originalSnapshot: [ArticleListItem]
    ) async {
        
        // Fetch just the current article's full model
        if let fullModel = await newsViewModel.fetchSwiftDataModel(for: article.id) {
            await MainActor.run {
                viewModel.currentArticle = fullModel
                
                // Update in articles array if still valid
                if viewModel.currentIndex < viewModel.articles.count {
                    viewModel.articles[viewModel.currentIndex] = fullModel
                }
                
                // Trigger deferred initialization
                viewModel.performDeferredInitialization()
            }
        }
        
        // Load full navigation set at lower priority
        Task.detached(priority: .background) {
            // Add delay to not interfere with initial render
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            
            _ = await MainActor.run {
                Task {
                    let fullModels = await newsViewModel.getFilteredArticlesAsModels()
                    
                    // Only update if user hasn't navigated away
                    if viewModel.currentArticle?.id == article.id {
                        viewModel.articles = fullModels
                        viewModel.allArticles = fullModels
                        
                        // Find and update current index
                        if let newIndex = fullModels.firstIndex(where: { $0.id == article.id }) {
                            viewModel.currentIndex = newIndex
                        }
                    }
                }
            }
        }
    }
}

// MARK: - NewsView Extension

extension NewsView {
    /// Use the optimized article opener
    func openArticleOptimized(_ article: ArticleListItem) {
        ArticleOpeningOptimizer.shared.openArticleOptimized(
            article,
            from: viewModel
        )
    }
}
