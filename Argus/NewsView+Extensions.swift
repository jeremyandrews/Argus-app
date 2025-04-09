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
                // Get the notification from the main context
                let descriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { $0.id == articleID }
                )

                // Get the main context - it's not optional
                let mainContext = ArgusApp.sharedModelContainer.mainContext

                // Try to fetch the notification
                guard let notification = try? mainContext.fetch(descriptor).first else {
                    AppLogger.database.error("Failed to fetch notification \(articleID) for markdown processing")
                    return
                }

                // Generate the blobs on the main thread (required for UI components)
                let titleBlob = getAttributedString(for: .title, from: notification, createIfMissing: true)
                let bodyBlob = getAttributedString(for: .body, from: notification, createIfMissing: true)

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

    // Updated function to generate blobs using ViewModel
    func generateBodyBlob(notificationID: UUID) {
        Task {
            await viewModel.generateBodyBlobIfNeeded(notificationID: notificationID)
        }
    }

    // Enhanced openArticle method that uses ViewModel for data operations
    func openArticle(_ notification: NotificationData) {
        guard !isActivelyScrolling else { return }

        // Use the view model to mark as read
        Task {
            await viewModel.openArticle(notification)
        }

        // Find the index of the notification
        guard let index = viewModel.filteredArticles.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        // Extract formatted content from blobs if available
        var extractedTitle: NSAttributedString?
        var extractedBody: NSAttributedString?
        var extractedSummary: NSAttributedString?

        // Create ArticleOperations for advanced operations
        let articleOperations = ArticleOperations()

        // Extract title blob if available
        if let titleBlobData = notification.title_blob {
            extractedTitle = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: titleBlobData
            )
        }

        // Extract body blob if available
        if let bodyBlobData = notification.body_blob {
            extractedBody = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: bodyBlobData
            )
        }

        // Handle summary - if blob exists, extract it; if not, generate it
        if let summaryBlobData = notification.summary_blob {
            // Try to extract existing blob
            extractedSummary = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: summaryBlobData
            )

            if extractedSummary != nil {
                AppLogger.database.debug("Successfully extracted summary blob for article \(notification.id)")
            } else {
                AppLogger.database.error("Failed to extract summary blob for article \(notification.id)")

                // If extraction failed but blob exists, generate from text
                if let summaryText = notification.summary, !summaryText.isEmpty {
                    extractedSummary = getAttributedString(for: .summary, from: notification, createIfMissing: true)
                    AppLogger.database.debug("Generated fallback summary for article \(notification.id)")
                }
            }
        } else {
            // No blob exists, generate it if we have text content
            AppLogger.database.debug("No summary blob found for article \(notification.id), generating one")
            if let summaryText = notification.summary, !summaryText.isEmpty {
                extractedSummary = getAttributedString(for: .summary, from: notification, createIfMissing: true)
                AppLogger.database.debug("Generated new summary for article \(notification.id)")
            }
        }

        // Set up the view model and view asynchronously to handle ArticleModel fetch
        Task {
            // Get the ArticleModel with context for database operations
            let articleModel = await articleOperations.getArticleModelWithContext(byId: notification.id)

            // Create a pre-configured ViewModel that will be passed to the NewsDetailView
            // This is critical for maintaining SwiftData context and ensuring blobs are properly saved
            let detailViewModel = NewsDetailViewModel(
                articles: viewModel.filteredArticles,
                allArticles: viewModel.allArticles,
                currentIndex: index,
                initiallyExpandedSection: "Summary",
                preloadedArticle: notification,
                preloadedTitle: extractedTitle,
                preloadedBody: extractedBody,
                preloadedSummary: extractedSummary,
                preloadedArticleModel: articleModel,
                articleOperations: articleOperations
            )

            // Create the detail view with the pre-configured ViewModel using the new initializer
            // This ensures the view uses our ViewModel with a valid SwiftData context
            let detailView = NewsDetailView(viewModel: detailViewModel)

            // Get modelContext from the shared container
            let modelContext = ArgusApp.sharedModelContainer.mainContext

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
                if let currentIndex = viewModel.filteredArticles.firstIndex(where: { $0.id == notification.id }) {
                    PreloadManager.shared.preloadArticles(viewModel.filteredArticles, currentIndex: currentIndex)
                }
            }
        }
    }

    // Enhanced loadMoreNotificationsIfNeeded using ViewModel for pagination
    func loadMoreNotificationsIfNeeded(currentItem: NotificationData) {
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

        // Also check if the notification needs body blob processing
        Task {
            // Check if processing is needed
            let needsProcessing = currentItem.body_blob == nil

            if needsProcessing {
                // Process the current item with high priority via ViewModel
                await viewModel.generateBodyBlobIfNeeded(notificationID: currentItem.id)
            }
        }

        // Preload the next few articles to make scrolling smoother
        if let currentIndex = viewModel.filteredArticles.firstIndex(where: { $0.id == currentItem.id }) {
            Task(priority: .background) {
                PreloadManager.shared.preloadArticles(viewModel.filteredArticles, currentIndex: currentIndex)
            }
        }
    }

    // Implementation of the affected field view that was moved from NewsView.swift
    func affectedFieldView(_ notification: NotificationData) -> some View {
        return Group {
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .textSelection(.disabled)
            }
        }
    }

    // Improved summary view that keeps content visible while processing
    func summaryContent(_ notification: NotificationData) -> some View {
        // State to avoid triggering multiple processing requests
        let needsProcessing = !notification.body.isEmpty && notification.body_blob == nil

        return ZStack(alignment: .bottomTrailing) {
            // Always show the content - either rich text or plain text
            Group {
                if let bodyBlob = notification.body_blob,
                   let attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: bodyBlob)
                {
                    NonSelectableRichTextView(attributedString: attributedBody, lineLimit: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(notification.body.isEmpty ? "(Error: missing data)" : notification.body)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .textSelection(.disabled)
                }
            }

            // Show processing indicator as an overlay if needed - not replacing content
            if needsProcessing {
                HStack(spacing: 4) {
                    Text("Formatting...")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.trailing, 4)
                }
                .padding(4)
                .background(Color(UIColor.systemBackground).opacity(0.7))
                .cornerRadius(4)
                .onAppear {
                    // Schedule processing on appear, but don't block UI
                    Task {
                        generateBodyBlob(notificationID: notification.id)
                    }
                }
            }
        }
    }
}
