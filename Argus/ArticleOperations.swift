import Foundation
import SwiftData
import SwiftUI

/// A shared business logic layer that provides operations common to multiple views
final class ArticleOperations {
    // Dependencies
    private let articleService: ArticleServiceProtocol

    // MARK: - Initialization

    /// Initializes a new instance of ArticleOperations
    /// - Parameter articleService: The article service to use, defaults to the shared instance
    init(articleService: ArticleServiceProtocol = ArticleService.shared) {
        self.articleService = articleService
    }

    // MARK: - Article State Operations

    /// Toggles the read status of an article
    /// - Parameter article: The article to toggle the read status for
    /// - Returns: Boolean indicating the new read state
    @discardableResult
    func toggleReadStatus(for article: NotificationData) async throws -> Bool {
        let newReadStatus = !article.isViewed
        try await articleService.markArticle(id: article.id, asRead: newReadStatus)

        // Ensure UI state is updated immediately
        await MainActor.run {
            // Force update the in-memory article object
            article.isViewed = newReadStatus
        }

        return newReadStatus
    }

    /// Toggles the bookmarked status of an article
    /// - Parameter article: The article to toggle the bookmarked status for
    /// - Returns: Boolean indicating the new bookmarked state
    @discardableResult
    func toggleBookmark(for article: NotificationData) async throws -> Bool {
        let newBookmarkStatus = !article.isBookmarked
        try await articleService.markArticle(id: article.id, asBookmarked: newBookmarkStatus)
        return newBookmarkStatus
    }

    // Archive functionality removed

    /// Deletes an article
    /// - Parameter article: The article to delete
    func deleteArticle(_ article: NotificationData) async throws {
        try await articleService.deleteArticle(id: article.id)
    }

    /// Fetches a complete article by ID, ensuring all fields are loaded
    /// - Parameter id: The article ID to fetch
    /// - Returns: The complete article, or nil if not found
    func getCompleteArticle(byId id: UUID) async -> NotificationData? {
        do {
            // Fetch the article using ArticleService to ensure all fields are loaded
            let article = try await articleService.fetchArticle(byId: id)

            // Log for debugging
            if let article = article {
                let hasTitleBlob = article.title_blob != nil
                let hasBodyBlob = article.body_blob != nil
                let hasSummaryBlob = article.summary_blob != nil
                let hasEngineStats = article.engine_stats != nil
                let hasSimilarArticles = article.similar_articles != nil

                AppLogger.database.debug("""
                Fetched article \(id):
                - Title blob: \(hasTitleBlob)
                - Body blob: \(hasBodyBlob)
                - Summary blob: \(hasSummaryBlob)
                - Engine stats: \(hasEngineStats)
                - Similar articles: \(hasSimilarArticles)
                """)
            }

            return article
        } catch {
            AppLogger.database.error("Error fetching complete article: \(error)")
            return nil
        }
    }

    // MARK: - Fetch Operations

    /// Fetches articles with the specified filters
    /// - Parameters:
    ///   - topic: Optional topic to filter by
    ///   - showUnreadOnly: Whether to show only unread articles
    ///   - showBookmarkedOnly: Whether to show only bookmarked articles
    ///   - limit: Maximum number of articles to return
    /// - Returns: Array of articles matching the criteria
    func fetchArticles(
        topic: String?,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool,
        limit: Int? = nil
    ) async throws -> [NotificationData] {
        return try await articleService.fetchArticles(
            topic: topic != "All" ? topic : nil,
            isRead: showUnreadOnly ? false : nil,
            isBookmarked: showBookmarkedOnly ? true : nil,
            isArchived: nil, // Archive functionality removed
            limit: limit,
            offset: nil
        )
    }

    /// Fetches a specific article by ID
    /// - Parameter id: The unique identifier of the article
    /// - Returns: The article if found, nil otherwise
    func fetchArticle(byId id: UUID) async throws -> NotificationData? {
        return try await articleService.fetchArticle(byId: id)
    }

    /// Ensures we have an article with model context for blob operations
    /// - Parameter article: The potentially detached article
    /// - Returns: An article with valid model context, or nil if unavailable
    func getArticleWithContext(article: NotificationData) async -> NotificationData? {
        // If article already has context, use it
        if article.modelContext != nil {
            return article
        }

        // Try to fetch a fresh copy from the database
        return await getCompleteArticle(byId: article.id)
    }

    /// Gets the original ArticleModel with SwiftData context for direct persistence operations
    /// - Parameter id: The unique identifier of the article
    /// - Returns: The ArticleModel with a valid context if found, nil otherwise
    func getArticleModelWithContext(byId id: UUID) async -> ArticleModel? {
        do {
            // Use the existing articleService to fetch the ArticleModel directly
            let context = ModelContext(SwiftDataContainer.shared.container)
            let fetchDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { $0.id == id }
            )

            let articleModels = try context.fetch(fetchDescriptor)

            if let model = articleModels.first {
                AppLogger.database.debug("✅ Found ArticleModel with valid context for ID: \(id)")
                return model
            } else {
                AppLogger.database.error("❌ Failed to find ArticleModel for ID: \(id)")
                return nil
            }
        } catch {
            AppLogger.database.error("❌ Error fetching ArticleModel: \(error)")
            return nil
        }
    }

    /// Saves blob data to an ArticleModel
    /// - Parameters:
    ///   - field: The field to save blob for
    ///   - blobData: The blob data to save
    ///   - articleModel: The ArticleModel to update
    /// - Returns: True if save was successful
    @MainActor
    func saveBlobToDatabase(field: RichTextField, blobData: Data, articleModel: ArticleModel) -> Bool {
        // Set the blob on the ArticleModel using field-specific properties
        switch field {
        case .title:
            articleModel.titleBlob = blobData
        case .body:
            articleModel.bodyBlob = blobData
        case .summary:
            articleModel.summaryBlob = blobData
        case .criticalAnalysis:
            articleModel.criticalAnalysisBlob = blobData
        case .logicalFallacies:
            articleModel.logicalFallaciesBlob = blobData
        case .sourceAnalysis:
            articleModel.sourceAnalysisBlob = blobData
        case .relationToTopic:
            articleModel.relationToTopicBlob = blobData
        case .additionalInsights:
            articleModel.additionalInsightsBlob = blobData
        }

        // Save the context
        if let context = articleModel.modelContext {
            do {
                try context.save()
                AppLogger.database.debug("✅ Saved blob for \(String(describing: field)) to database (\(blobData.count) bytes)")
                return true
            } catch {
                AppLogger.database.error("❌ Failed to save blob to database: \(error)")
                return false
            }
        } else {
            AppLogger.database.error("❌ ArticleModel has no context, cannot save")
            return false
        }
    }

    // MARK: - Rich Text Operations

    /// Gets or generates an attributed string for a specific field of an article
    /// - Parameters:
    ///   - field: The field to get the attributed string for
    ///   - article: The article to get the attributed string from
    ///   - createIfMissing: Whether to create the attributed string if it's missing
    /// - Returns: The attributed string if available or createIfMissing is true, nil otherwise
    @MainActor
    func getAttributedContent(
        for field: RichTextField,
        from article: NotificationData,
        createIfMissing: Bool = true
    ) -> NSAttributedString? {
        // Enhanced implementation with better blob handling

        // Step 1: Try to get from existing blob
        if let blobData = field.getBlob(from: article), !blobData.isEmpty {
            do {
                if let attributedString = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSAttributedString.self,
                    from: blobData
                ) {
                    AppLogger.database.debug("✅ Retrieved attributed string from blob for \(String(describing: field))")
                    return attributedString
                } else {
                    AppLogger.database.warning("⚠️ Blob unarchived to nil for \(String(describing: field)), will regenerate")
                    // Fall through to regeneration
                }
            } catch {
                AppLogger.database.error("❌ Failed to unarchive blob for \(String(describing: field)): \(error)")
                // Fall through to regeneration
            }
        }

        // Step 2: Generate from markdown if needed
        if createIfMissing {
            let markdownText = getMarkdownTextForField(field, from: article)

            guard let markdownText = markdownText, !markdownText.isEmpty else {
                AppLogger.database.debug("⚠️ No markdown text for \(String(describing: field))")
                return nil
            }

            AppLogger.database.debug("⚙️ Generating attributed string for \(String(describing: field)) (length: \(markdownText.count))")

            // Generate attributed string
            if let attributedString = markdownToAttributedString(
                markdownText,
                textStyle: field.textStyle
            ) {
                // Save as blob for future use
                do {
                    let blobData = try NSKeyedArchiver.archivedData(
                        withRootObject: attributedString,
                        requiringSecureCoding: false
                    )

                    // Set blob on the article
                    field.setBlob(blobData, on: article)

                    // Save context if possible
                    if let context = article.modelContext {
                        try context.save()
                        AppLogger.database.debug("✅ Saved blob for \(String(describing: field)) (\(blobData.count) bytes)")

                        // Verify blob was saved
                        if let savedBlob = field.getBlob(from: article) {
                            AppLogger.database.debug("✅ Verified blob save: \(savedBlob.count) bytes")
                        } else {
                            AppLogger.database.warning("⚠️ Blob verification failed for \(String(describing: field))")
                        }
                    } else {
                        AppLogger.database.warning("⚠️ Article has no model context, blob not saved")
                    }
                } catch {
                    AppLogger.database.error("❌ Failed to save blob for \(String(describing: field)): \(error)")
                }

                return attributedString
            } else {
                AppLogger.database.error("❌ Failed to generate attributed string for \(String(describing: field))")
            }
        }

        return nil
    }

    /// Generates or retrieves rich text content for all text-based fields of an article
    /// - Parameter article: The article to generate rich text content for
    /// - Returns: A dictionary mapping field names to generated NSAttributedString instances
    @MainActor
    func generateAllRichTextContent(for article: NotificationData) -> [RichTextField: NSAttributedString] {
        var results: [RichTextField: NSAttributedString] = [:]

        // Generate for all rich text fields
        let fieldsToGenerate: [RichTextField] = [
            .title, .body, .summary, .criticalAnalysis,
            .logicalFallacies, .sourceAnalysis, .relationToTopic,
            .additionalInsights,
        ]

        for field in fieldsToGenerate {
            if let attributedString = getAttributedString(
                for: field,
                from: article,
                createIfMissing: true
            ) {
                results[field] = attributedString
            }
        }

        return results
    }

    // MARK: - Sync Operations

    /// Synchronizes content from the server
    /// - Parameters:
    ///   - topic: Optional topic to sync content for
    ///   - limit: Maximum number of articles to sync
    /// - Returns: Number of new articles added
    func syncContent(topic: String? = nil, limit: Int? = 30) async throws -> Int {
        return try await articleService.syncArticlesFromServer(
            topic: topic,
            limit: limit
        )
    }

    /// Performs a background sync for all subscribed topics
    /// - Returns: Summary of the sync operation
    func performBackgroundSync() async throws -> SyncResultSummary {
        return try await articleService.performBackgroundSync()
    }

    // MARK: - Group & Sort Operations

    /// Groups articles by the specified grouping style
    /// - Parameters:
    ///   - articles: The articles to group
    ///   - groupingStyle: The grouping style to use (date, topic, none)
    ///   - sortOrder: The sort order to use within groups
    /// - Returns: An array of grouped articles with keys
    func groupArticles(
        _ articles: [NotificationData],
        by groupingStyle: String,
        sortOrder: String
    ) async -> [(key: String, notifications: [NotificationData])] {
        return await Task.detached(priority: .userInitiated) {
            // First, sort the articles according to the sort order
            let sortedArticles = self.sortArticles(articles, by: sortOrder)

            // Then group them according to the grouping style
            switch groupingStyle {
            case "date":
                let groupedByDay = Dictionary(grouping: sortedArticles) {
                    Calendar.current.startOfDay(for: $0.pub_date ?? $0.date)
                }

                let sortedDayKeys = groupedByDay.keys.sorted { $0 > $1 }
                return sortedDayKeys.map { day in
                    let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                    let notifications = groupedByDay[day] ?? []
                    return (key: displayKey, notifications: notifications)
                }

            case "topic":
                let groupedByTopic = Dictionary(grouping: sortedArticles) {
                    $0.topic ?? "Uncategorized"
                }

                return groupedByTopic.map {
                    (key: $0.key, notifications: $0.value)
                }.sorted { $0.key < $1.key }

            default: // "none"
                return [("", sortedArticles)]
            }
        }.value
    }

    /// Sorts articles by the specified sort order
    /// - Parameters:
    ///   - articles: The articles to sort
    ///   - sortOrder: The sort order to use
    /// - Returns: A sorted array of articles
    func sortArticles(
        _ articles: [NotificationData],
        by sortOrder: String
    ) -> [NotificationData] {
        return articles.sorted { a, b in
            switch sortOrder {
            case "oldest":
                return (a.pub_date ?? a.date) < (b.pub_date ?? b.date)
            case "bookmarked":
                if a.isBookmarked != b.isBookmarked {
                    return a.isBookmarked
                }
                return (a.pub_date ?? a.date) > (b.pub_date ?? b.date)
            default: // "newest"
                return (a.pub_date ?? a.date) > (b.pub_date ?? b.date)
            }
        }
    }

    // MARK: - Batch Operations

    /// Marks multiple articles as read or unread
    /// - Parameters:
    ///   - articleIds: IDs of articles to update
    ///   - isRead: Whether to mark articles as read or unread
    /// - Returns: Number of articles successfully updated
    @discardableResult
    func markArticles(ids articleIds: [UUID], asRead isRead: Bool) async -> Int {
        var updatedCount = 0

        for id in articleIds {
            do {
                try await articleService.markArticle(id: id, asRead: isRead)
                updatedCount += 1
            } catch {
                AppLogger.database.error("Failed to mark article \(id) as \(isRead ? "read" : "unread"): \(error)")
                // Continue with other articles even if one fails
            }
        }

        return updatedCount
    }

    /// Marks multiple articles as bookmarked or unbookmarked
    /// - Parameters:
    ///   - articleIds: IDs of articles to update
    ///   - isBookmarked: Whether to mark articles as bookmarked or unbookmarked
    /// - Returns: Number of articles successfully updated
    @discardableResult
    func markArticles(ids articleIds: [UUID], asBookmarked isBookmarked: Bool) async -> Int {
        var updatedCount = 0

        for id in articleIds {
            do {
                try await articleService.markArticle(id: id, asBookmarked: isBookmarked)
                updatedCount += 1
            } catch {
                AppLogger.database.error("Failed to mark article \(id) as \(isBookmarked ? "bookmarked" : "unbookmarked"): \(error)")
                // Continue with other articles even if one fails
            }
        }

        return updatedCount
    }

    // Archive batch operation removed

    /// Deletes multiple articles
    /// - Parameter articleIds: IDs of articles to delete
    /// - Returns: Number of articles successfully deleted
    @discardableResult
    func deleteArticles(ids articleIds: [UUID]) async -> Int {
        var deletedCount = 0

        for id in articleIds {
            do {
                try await articleService.deleteArticle(id: id)
                deletedCount += 1
            } catch {
                AppLogger.database.error("Failed to delete article \(id): \(error)")
                // Continue with other articles even if one fails
            }
        }

        return deletedCount
    }

    /// Removes duplicate articles from the database
    /// - Returns: Number of duplicates removed
    func cleanupDuplicateArticles() async throws -> Int {
        return try await articleService.removeDuplicateArticles()
    }

    // MARK: - Rich Text Helper Methods

    /// Gets the markdown text for a specific field
    /// - Parameters:
    ///   - field: The rich text field
    ///   - article: The article to get the text from
    /// - Returns: The markdown text if available, nil otherwise
    private func getMarkdownTextForField(_ field: RichTextField, from article: NotificationData) -> String? {
        switch field {
        case .title:
            return article.title
        case .body:
            return article.body
        case .summary:
            return article.summary
        case .criticalAnalysis:
            return article.critical_analysis
        case .logicalFallacies:
            return article.logical_fallacies
        case .sourceAnalysis:
            return article.source_analysis
        case .relationToTopic:
            return article.relation_to_topic
        case .additionalInsights:
            return article.additional_insights
        }
    }
}

// NOTE: RichTextField extensions are now defined in MarkdownUtilities.swift
