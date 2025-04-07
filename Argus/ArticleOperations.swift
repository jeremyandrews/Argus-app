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

    /// Toggles the archived status of an article
    /// - Parameter article: The article to toggle the archived status for
    /// - Returns: Boolean indicating the new archived state
    @discardableResult
    func toggleArchive(for article: NotificationData) async throws -> Bool {
        let newArchivedStatus = !article.isArchived
        try await articleService.markArticle(id: article.id, asArchived: newArchivedStatus)
        return newArchivedStatus
    }

    /// Deletes an article
    /// - Parameter article: The article to delete
    func deleteArticle(_ article: NotificationData) async throws {
        try await articleService.deleteArticle(id: article.id)
    }

    // MARK: - Fetch Operations

    /// Fetches articles with the specified filters
    /// - Parameters:
    ///   - topic: Optional topic to filter by
    ///   - showUnreadOnly: Whether to show only unread articles
    ///   - showBookmarkedOnly: Whether to show only bookmarked articles
    ///   - showArchivedContent: Whether to show archived content
    ///   - limit: Maximum number of articles to return
    /// - Returns: Array of articles matching the criteria
    func fetchArticles(
        topic: String?,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool,
        showArchivedContent: Bool,
        limit: Int? = nil
    ) async throws -> [NotificationData] {
        return try await articleService.fetchArticles(
            topic: topic != "All" ? topic : nil,
            isRead: showUnreadOnly ? false : nil,
            isBookmarked: showBookmarkedOnly ? true : nil,
            isArchived: !showArchivedContent ? false : nil,
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
        // Direct call since we're already on MainActor
        return getAttributedString(for: field, from: article, createIfMissing: createIfMissing)
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

    /// Marks multiple articles as archived or unarchived
    /// - Parameters:
    ///   - articleIds: IDs of articles to update
    ///   - isArchived: Whether to mark articles as archived or unarchived
    /// - Returns: Number of articles successfully updated
    @discardableResult
    func markArticles(ids articleIds: [UUID], asArchived isArchived: Bool) async -> Int {
        var updatedCount = 0

        for id in articleIds {
            do {
                try await articleService.markArticle(id: id, asArchived: isArchived)
                updatedCount += 1
            } catch {
                AppLogger.database.error("Failed to mark article \(id) as \(isArchived ? "archived" : "unarchived"): \(error)")
                // Continue with other articles even if one fails
            }
        }

        return updatedCount
    }

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
}
