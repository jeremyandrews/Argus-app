import SwiftData
import SwiftUI

extension NewsView {
    // Setup notification observer for processing markdown
    static func setupMarkdownProcessingObserver() {
        // This static method will be called when the app starts
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ProcessMarkdownForArticle"),
            object: nil,
            queue: .main
        ) { notification in
            // Extract article ID from notification
            guard let articleID = notification.userInfo?["articleID"] as? UUID else {
                AppLogger.database.error("Missing article ID in ProcessMarkdownForArticle notification")
                return
            }

            // Process the article
            Task { @MainActor in
                // Get the main context from SwiftDataContainer
                let mainContext = SwiftDataContainer.shared.container.mainContext

                // Using a safer approach to avoid predicate type issues
                let descriptor = FetchDescriptor<ArticleModel>()
                let allArticles = try? mainContext.fetch(descriptor)
                
                // Manual filtering by ID string to avoid predicate issues
                let idString = articleID.uuidString
                guard let article = allArticles?.first(where: { $0.id.uuidString == idString }) else {
                    AppLogger.database.error("Failed to fetch article \(articleID) for markdown processing")
                    return
                }

                // Create operations instance for blob generation
                let operations = ArticleOperations()

                // Generate the blobs on the main thread (required for UI components)
                let titleBlob = operations.getAttributedContent(for: .title, from: article, createIfMissing: true)
                let bodyBlob = operations.getAttributedContent(for: .body, from: article, createIfMissing: true)

                // Log the result
                if titleBlob != nil && bodyBlob != nil {
                    AppLogger.database.debug("Successfully generated rich text for article \(articleID)")
                } else {
                    AppLogger.database.error("Failed to generate rich text for article \(articleID)")
                }

                // Save changes
                do {
                    try mainContext.save()
                } catch {
                    AppLogger.database.error("Failed to save rich text blobs: \(error)")
                }
            }
        }

        AppLogger.database.debug("Markdown processing observer set up")
    }

    // Enhanced openArticle method that uses ViewModel for data operations
    func openArticle(_ article: ArticleModel) {
        guard !isActivelyScrolling else { return }

        // Use the view model to mark as read
        Task {
            await viewModel.openArticle(article)
        }

        // Find the index of the article
        guard let index = viewModel.filteredArticles.firstIndex(where: { $0.id == article.id }) else {
            return
        }

        // Extract formatted content from blobs if available
        var extractedTitle: NSAttributedString?
        var extractedBody: NSAttributedString?
        var extractedSummary: NSAttributedString?

        // Create ArticleOperations for advanced operations
        let articleOperations = ArticleOperations()

        // Extract title blob if available
        if let titleBlobData = article.titleBlob {
            extractedTitle = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: titleBlobData
            )
        }

        // Extract body blob if available
        if let bodyBlobData = article.bodyBlob {
            extractedBody = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: bodyBlobData
            )
        }

        // Handle summary - if blob exists, extract it; if not, generate it
        if let summaryBlobData = article.summaryBlob {
            // Try to extract existing blob
            extractedSummary = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: summaryBlobData
            )

            if extractedSummary != nil {
                AppLogger.database.debug("Successfully extracted summary blob for article \(article.id)")
            } else {
                AppLogger.database.error("Failed to extract summary blob for article \(article.id)")

                // If extraction failed but blob exists, generate from text
                if let summaryText = article.summary, !summaryText.isEmpty {
                    // Generated synchronously without awaiting since we're already on the main thread
                    extractedSummary = articleOperations.getAttributedContent(for: .summary, from: article, createIfMissing: true)
                    AppLogger.database.debug("Generated fallback summary for article \(article.id)")
                }
            }
        } else {
            // No blob exists, generate it if we have text content
            AppLogger.database.debug("No summary blob found for article \(article.id), generating one")
            if let summaryText = article.summary, !summaryText.isEmpty {
                // Generate synchronously since we're already on the main thread
                extractedSummary = articleOperations.getAttributedContent(for: .summary, from: article, createIfMissing: true)
                AppLogger.database.debug("Generated new summary for article \(article.id)")
            }
        }

        // Set up the view model and view asynchronously to handle context fetch
        Task {
            // Get article with context for persistence operations
            let articleWithContext = await articleOperations.getArticleModelWithContext(byId: article.id)

            // Log the context status
            if let articleWithContext = articleWithContext {
                AppLogger.database.debug("✅ Retrieved article with context for ID: \(article.id)")
                AppLogger.database.debug("✅ Context valid: \(articleWithContext.modelContext != nil)")
            } else {
                AppLogger.database.warning("⚠️ Could not retrieve article with context for ID: \(article.id)")
            }

            // Create a pre-configured ViewModel that will be passed to the NewsDetailView
            // This is critical for maintaining SwiftData context and ensuring blobs are properly saved
            let detailViewModel = NewsDetailViewModel(
                articles: viewModel.filteredArticles,
                allArticles: viewModel.allArticles,
                currentIndex: index,
                initiallyExpandedSection: "Summary",
                preloadedArticle: articleWithContext ?? article,
                preloadedTitle: extractedTitle,
                preloadedBody: extractedBody,
                preloadedSummary: extractedSummary,
                articleOperations: articleOperations
            )

            // Create the detail view with the pre-configured ViewModel using the new initializer
            // This ensures the view uses our ViewModel with a valid SwiftData context
            let detailView = NewsDetailView(viewModel: detailViewModel)

            // Get modelContext from the shared container
            let modelContext = SwiftDataContainer.shared.container.mainContext

            // Create and present the hosting controller with environment
            let hostingController = UIHostingController(
                rootView: detailView.environment(\.modelContext, modelContext)
            )
            hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootViewController = window.rootViewController
            {
                rootViewController.present(hostingController, animated: true)
            }

            // After presenting the view, use PreloadManager to prepare next few articles
            Task {
                // Use our dedicated PreloadManager to handle preloading
                if let currentIndex = viewModel.filteredArticles.firstIndex(where: { $0.id == article.id }) {
                    PreloadManager.shared.preloadArticles(viewModel.filteredArticles, currentIndex: currentIndex)
                }
            }
        }
    }

    // Enhanced loadMoreArticlesIfNeeded using ViewModel for pagination
    func loadMoreArticlesIfNeeded(currentItem: ArticleModel) {
        // Check if we're approaching the end of the list using ViewModel data
        guard let index = viewModel.filteredArticles.firstIndex(where: { $0.id == currentItem.id }),
              index >= viewModel.filteredArticles.count - 5,
              viewModel.hasMoreContent,
              !viewModel.isLoadingMorePages
        else {
            return
        }

        // Trigger pagination through ViewModel
        Task {
            await viewModel.loadMoreArticles()
        }

        // Also check if the article needs body blob processing
        Task {
            // Check if processing is needed
            let needsProcessing = currentItem.bodyBlob == nil

            if needsProcessing {
                // Process the current item with high priority via ViewModel
                await viewModel.generateBodyBlobIfNeeded(articleID: currentItem.id)
            }
        }

        // Preload the next few articles to make scrolling smoother
        if let currentIndex = viewModel.filteredArticles.firstIndex(where: { $0.id == currentItem.id }) {
            Task(priority: .background) {
                PreloadManager.shared.preloadArticles(viewModel.filteredArticles, currentIndex: currentIndex)
            }
        }
    }

    // Implementation of the empty state message
    func getEmptyStateMessage() -> String {
        let activeSubscriptions = viewModel.subscriptions.filter { $0.value.isSubscribed }.keys.sorted()
        if activeSubscriptions.isEmpty {
            return "You are not currently subscribed to any topics. Click 'Subscriptions' below."
        }
        var message = "Please be patient, news will arrive automatically. You do not need to leave this application open.\n\nYou are currently subscribed to: \(activeSubscriptions.joined(separator: ", "))."
        
        // Check filter status directly from viewModel instead of using isAnyFilterActive property
        let filtersActive = viewModel.showUnreadOnly || viewModel.showBookmarkedOnly
        if filtersActive {
            message += "\n\n"
            if viewModel.showUnreadOnly && viewModel.showBookmarkedOnly {
                message += "You are filtering to show only Unread articles that have also been Bookmarked."
            } else if viewModel.showUnreadOnly {
                message += "You are filtering to show only Unread articles."
            } else if viewModel.showBookmarkedOnly {
                message += "You are filtering to show only Bookmarked articles."
            }
        }
        return message
    }

    // Perform action on multiple selected articles
    func performActionOnSelection(action: (ArticleModel) -> Void) {
        if !viewModel.selectedArticleIds.isEmpty {
            // For complex operations that aren't directly supported by viewModel batch operations,
            // we apply the action to each selected article
            for id in viewModel.selectedArticleIds {
                if let article = viewModel.filteredArticles.first(where: { $0.id == id }) {
                    action(article)
                }
            }

            // Reset selection state - only clear selected IDs here
            // The parent view will handle resetting editMode
            withAnimation {
                viewModel.selectedArticleIds.removeAll()
            }
            
            // Post a notification that can be observed by NewsView to reset edit mode
            NotificationCenter.default.post(
                name: Notification.Name("ResetEditMode"),
                object: nil
            )
        }
    }
}
