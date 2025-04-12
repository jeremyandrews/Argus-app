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
        Task {
            await viewModel.openArticle(article)
            
            // Create a view model with the right context
            if let index = viewModel.filteredArticles.firstIndex(where: { $0.id == article.id }) {
                let detailViewModel = NewsDetailViewModel(
                    articles: viewModel.filteredArticles,
                    allArticles: viewModel.allArticles,
                    currentIndex: index
                )
                
                // Create the detail view 
                // We need to make a host view to properly pass the modelContext
                struct DetailViewWrapper: View {
                    let viewModel: NewsDetailViewModel
                    @Environment(\.modelContext) var modelContext
                    
                    var body: some View {
                        NewsDetailView(viewModel: viewModel)
                    }
                }
                
                let detailView = DetailViewWrapper(viewModel: detailViewModel)
                
                // Present modally in full screen
                let hostingController = UIHostingController(rootView: detailView)
                hostingController.modalPresentationStyle = .fullScreen
                
                // Use the shared scene to present
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController
                {
                    rootViewController.present(hostingController, animated: true)
                }
            }
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
