import SwiftUI

// MARK: - NewsView Helper Methods

extension NewsView {
    // MARK: - Pagination

    func loadMoreArticlesIfNeeded(currentItem: ArticleListItem) {
        guard let lastItem = viewModel.filteredArticles.last else {
            return
        }

        // When we're within 3 items of the end, load more
        if currentItem.id == lastItem.id, viewModel.hasMoreContent, !viewModel.isLoadingMorePages {
            Task {
                await viewModel.loadMoreArticles()
            }
        }
    }

    // MARK: - Selection Actions

    func performActionOnSelection(_ action: @escaping (ArticleListItem) -> Void) {
        let selectedArticles = viewModel.selectedArticleIds

        // Create an array of the selected articles
        let articles = viewModel.filteredArticles.filter { selectedArticles.contains($0.id) }

        // Perform the action on each selected article
        for article in articles {
            action(article)
        }
    }

    // MARK: - Article Opening

    func openArticle(_ article: ArticleListItem) {
        // STEP 1: Take a snapshot of the current filtered articles immediately
        // This prevents issues if filters are applied during async operations
        let articlesSnapshot = viewModel.filteredArticles

        // STEP 2: Find the index in our snapshot (which won't change during async operations)
        guard let index = articlesSnapshot.firstIndex(where: { $0.id == article.id }) else {
            AppLogger.database.error("Article not found in filtered articles: \(article.id)")
            return
        }

        AppLogger.database.debug("Opening article with ID: \(article.id) at index \(index) of \(articlesSnapshot.count) articles")

        // STEP 3: Present detail view IMMEDIATELY with placeholder models
        // IMPORTANT: Include summary text in placeholder to ensure content is visible
        let placeholderArticles = articlesSnapshot.map { item in
            ArticleModel(
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
                // CRITICAL: Use body as initial summary so content is visible immediately
                summary: item.body, // Show body content as summary initially
                criticalAnalysis: "Loading full analysis...",
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
        }
        
        // Create view model with placeholder models (instant!)
        let detailViewModel = NewsDetailViewModel(
            articles: placeholderArticles,
            allArticles: placeholderArticles,
            currentIndex: index,
            initiallyExpandedSection: "Summary",
            newsViewModel: viewModel,
            needsFullDataset: false
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

        // Present immediately - UI should appear instantly
        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            AppLogger.database.debug("Presenting NewsDetailView for article: \(article.id)")
            rootViewController.present(hostingController, animated: true)

            // Mark as read in background (non-blocking)
            Task.detached(priority: .background) {
                await self.viewModel.openArticle(article)
            }
            
            // Load full article data after presenting (fetch only current article!)
            Task {
                // Fetch the full model for the current article
                if let fullModel = await viewModel.fetchSwiftDataModel(for: article.id) {
                    await MainActor.run {
                        // Update the current article with full data
                        detailViewModel.currentArticle = fullModel
                        
                        // Also update it in the articles array to ensure consistency
                        if index < detailViewModel.articles.count {
                            detailViewModel.articles[index] = fullModel
                        }
                        
                        // Initialize deferred content loading
                        detailViewModel.performDeferredInitialization()
                    }
                } else {
                    AppLogger.database.error("Failed to fetch full model for article: \(article.id)")
                }
                
                // Fetch full models for navigation in background (low priority)
                Task.detached(priority: .background) {
                    await MainActor.run {
                        Task {
                            // Fetch models within MainActor context to avoid Sendable issues
                            let fullModels = await viewModel.getFilteredArticlesAsModels()
                            
                            // Update all articles with full models, preserving current article
                            let currentId = detailViewModel.currentArticle?.id
                            detailViewModel.articles = fullModels
                            detailViewModel.allArticles = fullModels
                            
                            // Ensure current article index is still correct
                            if let currentId = currentId,
                               let newIndex = fullModels.firstIndex(where: { $0.id == currentId }) {
                                detailViewModel.currentIndex = newIndex
                            }
                        }
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
            // This case should rarely happen now due to auto-redirect,
            // but include it for completeness
            return "No articles found for topic '\(viewModel.selectedTopic)'. Redirecting to All topics..."
        } else {
            return "Sync to load articles."
        }
    }
}
