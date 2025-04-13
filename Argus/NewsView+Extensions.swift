import SwiftUI

// MARK: - NewsView Helper Methods

extension NewsView {
    // MARK: - Pagination
    
    func loadMoreArticlesIfNeeded(currentItem: ArticleModel) {
        guard let lastItem = viewModel.filteredArticles.last else {
            return
        }
        
        // When we're within 3 items of the end, load more
        if currentItem.id == lastItem.id && viewModel.hasMoreContent && !viewModel.isLoadingMorePages {
            Task {
                await viewModel.loadMoreArticles()
            }
        }
    }
    
    // MARK: - Selection Actions
    
    func performActionOnSelection(_ action: @escaping (ArticleModel) -> Void) {
        let selectedArticles = viewModel.selectedArticleIds
        
        // Create an array of the selected articles
        let articles = viewModel.filteredArticles.filter { selectedArticles.contains($0.id) }
        
        // Perform the action on each selected article
        for article in articles {
            action(article)
        }
    }
    
    // MARK: - Article Opening
    
    func openArticle(_ article: ArticleModel) {
        // STEP 1: Take a snapshot of the current filtered articles immediately
        // This prevents issues if filters are applied during async operations
        let articlesSnapshot = viewModel.filteredArticles
        
        // STEP 2: Find the index in our snapshot (which won't change during async operations)
        guard let index = articlesSnapshot.firstIndex(where: { $0.id == article.id }) else {
            AppLogger.database.error("Article not found in filtered articles: \(article.id)")
            return
        }
        
        AppLogger.database.debug("Opening article with ID: \(article.id) at index \(index) of \(articlesSnapshot.count) articles")
        
        // STEP 3: Create view model with our snapshot
        let detailViewModel = NewsDetailViewModel(
            articles: articlesSnapshot,
            allArticles: viewModel.allArticles,
            currentIndex: index,
            initiallyExpandedSection: "Summary"
        )
        
        // Create the detail view wrapper
        struct DetailViewWrapper: View {
            let viewModel: NewsDetailViewModel
            @Environment(\.modelContext) var modelContext
            
            var body: some View {
                NewsDetailView(viewModel: viewModel)
            }
        }
        
        let detailView = DetailViewWrapper(viewModel: detailViewModel)
        
        // STEP 4: Present immediately before doing any async work
        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            AppLogger.database.debug("Presenting NewsDetailView for article: \(article.id)")
            rootViewController.present(hostingController, animated: true)
            
            // STEP 5: After presentation, do the article update and blob generation in the background
            Task {
                // Get article with context
                let articleOperations = ArticleOperations()
                if let articleWithContext = await articleOperations.getArticleModelWithContext(byId: article.id) {
                    // Mark as read
                    await viewModel.openArticle(articleWithContext)
                    
                    // Generate blobs in the background after view is already shown
                    await MainActor.run {
                        _ = articleOperations.getAttributedContent(for: .title, from: articleWithContext, createIfMissing: true)
                        _ = articleOperations.getAttributedContent(for: .body, from: articleWithContext, createIfMissing: true)
                        AppLogger.database.debug("Title and body blobs generated for article: \(article.id)")
                    }
                }
            }
        } else {
            AppLogger.database.error("Could not get root view controller to present article: \(article.id)")
        }
    }
    
    // MARK: - Empty State
    
    func getEmptyStateMessage() -> String {
        if viewModel.showUnreadOnly && viewModel.showBookmarkedOnly {
            return "No unread, bookmarked articles found."
        } else if viewModel.showUnreadOnly {
            return "No unread articles found."
        } else if viewModel.showBookmarkedOnly {
            return "No bookmarked articles found."
        } else if viewModel.selectedTopic != "All" {
            return "No articles found for topic '\(viewModel.selectedTopic)'."
        } else {
            return "Sync to load articles."
        }
    }
}
