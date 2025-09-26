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
        // CRITICAL N-1 BUG FIX: Use complete dataset instead of filtered articles
        // The n-1 bug occurs when we only pass filtered articles to the detail view
        // but the user expects to navigate through ALL articles in the topic
        
        // STEP 1: Get the complete dataset for the current topic to prevent n-1 bug
        Task {
            // Verify the article exists in the filtered view
            guard viewModel.filteredArticles.contains(where: { $0.id == article.id }) else {
                AppLogger.database.error("Article not found in filtered articles: \(article.id)")
                return
            }
            
            AppLogger.database.debug("Opening article with ID: \(article.id) from filtered view")
            
            // Find the article's index in current filtered view for placeholder
            guard let currentIndex = viewModel.filteredArticles.firstIndex(where: { $0.id == article.id }) else {
                AppLogger.database.error("Article not found in filtered articles: \(article.id)")
                return
            }
            
            await MainActor.run {
                // Create placeholder models from filtered articles initially
                let placeholderArticles = viewModel.filteredArticles.map { item in
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
            currentIndex: currentIndex,
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
            
            // SIMPLE APPROACH: Load full article and update count with proper handling
            Task {
                // 1. Fetch the full model for the current article
                if let fullModel = await viewModel.fetchSwiftDataModel(for: article.id) {
                    await MainActor.run {
                        detailViewModel.currentArticle = fullModel
                        if currentIndex < detailViewModel.articles.count {
                            detailViewModel.articles[currentIndex] = fullModel
                        }
                        detailViewModel.performDeferredInitialization()
                    }
                }
                
                // 2. PERFORMANCE FIX: Query complete dataset in background to avoid UI lockup
                Task(priority: .background) {
                    let completeDataset = await viewModel.getCompleteDatasetForNavigation(currentArticleId: article.id)
                    
                    // 3. Check if current article is visible in complete dataset
                    let currentArticleVisible = completeDataset.contains { $0.id == article.id }
                    
                    // 4. Calculate correct total: if current article filtered out, add +1
                    let actualTotal = currentArticleVisible ? completeDataset.count : completeDataset.count + 1
                    
                    await MainActor.run {
                        // Update the view model with correct count via a simple method
                        detailViewModel.updateNavigationCount(actualTotal)
                    }
                    
                    AppLogger.database.debug("✅ PERFORMANCE FIX: Updated count to \(actualTotal) in background (current visible: \(currentArticleVisible))")
                }
            }
        } else {
            AppLogger.database.error("Could not get root view controller to present article: \(article.id)")
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
            // This case should rarely happen now due to auto-redirect,
            // but include it for completeness
            return "No articles found for topic '\(viewModel.selectedTopic)'. Redirecting to All topics..."
        } else {
            return "Sync to load articles."
        }
    }
}
