import Foundation
import SwiftUI

/// Errors that can occur during article service operations
enum ArticleServiceError: Error {
    /// The requested article was not found
    case articleNotFound

    /// A network error occurred while fetching data
    case networkError(underlyingError: Error)

    /// A database error occurred during persistence operations
    case databaseError(underlyingError: Error)

    /// A validation error occurred (e.g., duplicate article)
    case validationError(String)

    /// The operation was cancelled
    case cancelled

    /// An unexpected error occurred
    case unknown(String)
}

/// Summary of a synchronization operation
struct SyncResultSummary {
    let addedCount: Int
    let updatedCount: Int
    let deletedCount: Int
    let duration: TimeInterval
}

/// Protocol defining operations for managing article data
protocol ArticleServiceProtocol {
    // MARK: - Fetch Operations

    /// Fetches articles matching the specified criteria
    /// - Parameters:
    ///   - topic: Optional topic to filter by
    ///   - isRead: Optional read status to filter by
    ///   - isBookmarked: Optional bookmarked status to filter by
    ///   - isArchived: Optional archived status to filter by
    ///   - limit: Maximum number of articles to return
    ///   - offset: Number of articles to skip
    /// - Returns: Array of articles matching the criteria
    func fetchArticles(
        topic: String?,
        isRead: Bool?,
        isBookmarked: Bool?,
        isArchived: Bool?,
        limit: Int?,
        offset: Int?
    ) async throws -> [ArticleModel]

    /// Fetches a specific article by ID
    /// - Parameter id: The unique identifier of the article
    /// - Returns: The article if found, nil otherwise
    func fetchArticle(byId id: UUID) async throws -> ArticleModel?

    /// Fetches an article by its JSON URL
    /// - Parameter jsonURL: The JSON URL of the article
    /// - Returns: The article if found, nil otherwise
    func fetchArticle(byJsonURL jsonURL: String) async throws -> ArticleModel?

    /// Searches articles with the given query text
    /// - Parameters:
    ///   - queryText: Text to search for in article titles and bodies
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching articles
    func searchArticles(queryText: String, limit: Int?) async throws -> [ArticleModel]

    // MARK: - State Management Operations

    /// Updates the read status of an article
    /// - Parameters:
    ///   - id: The unique identifier of the article
    ///   - isRead: New read status
    func markArticle(id: UUID, asRead isRead: Bool) async throws

    /// Updates the bookmarked status of an article
    /// - Parameters:
    ///   - id: The unique identifier of the article
    ///   - isBookmarked: New bookmarked status
    func markArticle(id: UUID, asBookmarked isBookmarked: Bool) async throws

    // Archive functionality removed

    /// Deletes an article
    /// - Parameter id: The unique identifier of the article to delete
    func deleteArticle(id: UUID) async throws

    // MARK: - Sync Operations
    
    /// Processes the provided article data and adds new articles to the database
    /// - Parameters:
    ///   - articles: Array of article JSON data to process
    ///   - progressHandler: Optional handler for progress updates (current, total)
    /// - Returns: Number of new articles added
    func processArticleData(_ articles: [ArticleJSON], progressHandler: ((Int, Int) -> Void)?) async throws -> Int
    
    /// Synchronizes articles from the server for the specified topic
    /// - Parameters:
    ///   - topic: Topic to sync articles for, or nil for all topics
    ///   - limit: Maximum number of articles to sync
    ///   - progressHandler: Optional handler for progress updates (current, total)
    /// - Returns: Number of new articles added
    func syncArticlesFromServer(topic: String?, limit: Int?, progressHandler: ((Int, Int) -> Void)?) async throws -> Int

    /// Performs a full background synchronization
    /// - Parameter progressHandler: Optional handler for progress updates (current, total)
    /// - Returns: Result summary with counts of added, updated, and deleted articles
    func performBackgroundSync(progressHandler: ((Int, Int) -> Void)?) async throws -> SyncResultSummary

    /// Removes duplicate articles from the database, keeping only the newest version of each article
    /// - Returns: The number of duplicate articles removed
    func removeDuplicateArticles() async throws -> Int

    // MARK: - Rich Text Operations

    /// Generates rich text content for a specific field of an article
    /// - Parameters:
    ///   - articleId: The unique identifier of the article
    ///   - field: The field to generate rich text for
    /// - Returns: The generated NSAttributedString if successful, nil otherwise
    /// - Note: This method must run on the MainActor since NSAttributedString is not Sendable
    @MainActor
    func generateRichTextContent(
        for articleId: UUID,
        field: RichTextField
    ) async throws -> NSAttributedString?
}

// Extension to provide user-friendly error messages
extension ArticleServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .articleNotFound:
            return "The requested article could not be found"
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case let .databaseError(error):
            return "Database error: \(error.localizedDescription)"
        case let .validationError(message):
            return "Validation error: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        case let .unknown(message):
            return "An unexpected error occurred: \(message)"
        }
    }
}
