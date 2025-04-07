import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Service responsible for managing articles between the API and local SwiftData storage
class ArticleService {
    // MARK: - Singleton and Dependencies

    /// Shared instance for global access
    static let shared = ArticleService()

    /// API client for network operations
    private let apiClient: APIClient

    /// SwiftData container for storage
    private let modelContainer: ModelContainer

    /// Logger for service operations
    private let logger = AppLogger.database // Using the existing database logger category

    // MARK: - Error Types

    /// Error types specific to ArticleService
    enum ArticleServiceError: Error, LocalizedError {
        case notFound(String)
        case databaseError(Error)
        case uniquenessViolation(String)
        case invalidData(String)
        case syncFailed(Error)

        var errorDescription: String? {
            switch self {
            case let .notFound(message):
                return "Resource not found: \(message)"
            case let .databaseError(error):
                return "Database error: \(error.localizedDescription)"
            case let .uniquenessViolation(message):
                return "Uniqueness violation: \(message)"
            case let .invalidData(message):
                return "Invalid data: \(message)"
            case let .syncFailed(error):
                return "Synchronization failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization

    /// Private initializer to enforce singleton pattern
    private init(apiClient: APIClient = .shared,
                 modelContainer: ModelContainer = SwiftDataContainer.shared.container)
    {
        self.apiClient = apiClient
        self.modelContainer = modelContainer
        logger.debug("ArticleService initialized")
    }

    // MARK: - Article Fetching Methods

    /// Fetches articles from local storage with optional filtering
    /// - Parameters:
    ///   - topic: Optional topic filter
    ///   - isRead: Optional read status filter
    /// - Returns: Array of ArticleModel objects
    func fetchArticles(topic: String? = nil, isRead: Bool? = nil) async throws -> [ArticleModel] {
        // Create a new context for this operation
        let context = ModelContext(modelContainer)

        // Build predicate based on filters
        var predicates: [Predicate<ArticleModel>] = []

        if let topic = topic {
            predicates.append(#Predicate<ArticleModel> { article in
                article.topic == topic
            })
        }

        if let isRead = isRead {
            predicates.append(#Predicate<ArticleModel> { article in
                article.isViewed == isRead
            })
        }

        // Create the fetch descriptor with combined predicate
        var descriptor = FetchDescriptor<ArticleModel>()
        if !predicates.isEmpty {
            if predicates.count == 1 {
                descriptor.predicate = predicates[0]
            } else if predicates.count == 2 {
                // For exactly two predicates, combine them directly with AND
                let topicPredicate = predicates[0]
                let readPredicate = predicates[1]
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    topicPredicate.evaluate(article) && readPredicate.evaluate(article)
                }
            }
        }

        // Add sorting by publish date (newest first)
        descriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]

        do {
            let articles = try context.fetch(descriptor)
            logger.info("Fetched \(articles.count) articles from local storage")
            return articles
        } catch {
            logger.error("Failed to fetch articles: \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(error)
        }
    }

    /// Fetches a specific article by ID
    /// - Parameter id: UUID of the article to fetch
    /// - Returns: ArticleModel if found
    /// - Throws: Error if article not found or database error
    func fetchArticle(byId id: UUID) async throws -> ArticleModel {
        let context = ModelContext(modelContainer)

        let descriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate { article in
                article.id == id
            }
        )

        do {
            let articles = try context.fetch(descriptor)
            guard let article = articles.first else {
                logger.error("Article with ID \(id) not found")
                throw ArticleServiceError.notFound("Article with ID \(id) not found")
            }

            logger.info("Fetched article with ID \(id)")
            return article
        } catch let error as ArticleServiceError {
            throw error
        } catch {
            logger.error("Failed to fetch article with ID \(id): \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(error)
        }
    }

    // MARK: - Synchronization Methods

    /// Syncs new articles from the server (only adding articles we don't have)
    /// - Parameters:
    ///   - topic: Optional topic to sync articles for
    ///   - limit: Maximum number of articles to fetch
    /// - Returns: Number of new articles synced
    /// - Throws: Error if sync fails
    func syncArticlesFromServer(topic: String? = nil, limit: Int = 50) async throws -> Int {
        // Create a background context for database operations
        let context = ModelContext(modelContainer)

        do {
            // Fetch articles from API
            let articleJSONs = try await apiClient.fetchArticles(limit: limit, topic: topic)
            logger.info("Fetched \(articleJSONs.count) articles from API")

            // Track new articles count for return value
            var newArticlesCount = 0

            // Process in batches for better performance
            let batchSize = 10
            for batch in stride(from: 0, to: articleJSONs.count, by: batchSize) {
                let endIndex = min(batch + batchSize, articleJSONs.count)
                let batchSlice = articleJSONs[batch ..< endIndex]

                // Process each article in this batch
                for articleJSON in batchSlice {
                    // Check if article already exists by jsonURL
                    if try await articleExists(jsonURL: articleJSON.jsonURL, in: context) {
                        // Skip existing articles - no update needed since articles are immutable
                        logger.debug("Skipping existing article with URL \(articleJSON.jsonURL)")
                        continue
                    }

                    // Article doesn't exist, create it
                    try await createNewArticle(from: articleJSON, in: context)
                    newArticlesCount += 1
                }

                // Save after each batch
                try context.save()
                logger.debug("Saved batch with \(newArticlesCount) new articles")
            }

            logger.info("Sync completed: \(newArticlesCount) new articles added")
            return newArticlesCount

        } catch {
            logger.error("Failed to sync articles: \(error.localizedDescription)")
            throw ArticleServiceError.syncFailed(error)
        }
    }

    /// Checks if an article already exists in the database
    /// - Parameters:
    ///   - jsonURL: Article JSON URL (primary identifier)
    ///   - context: SwiftData context to use
    /// - Returns: True if article exists, false otherwise
    private func articleExists(jsonURL: String, in context: ModelContext) async throws -> Bool {
        // Check by JSON URL which is our unique identifier
        let urlDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate { article in
                article.jsonURL == jsonURL
            }
        )

        // Just check if there's at least one match
        return try !context.fetch(urlDescriptor).isEmpty
    }

    /// Creates a new article from API data
    /// - Parameters:
    ///   - articleJSON: Article data from API
    ///   - context: SwiftData context to use
    private func createNewArticle(from articleJSON: ArticleJSON, in context: ModelContext) async throws {
        // Create a UUID for this article
        let articleId = UUID() // New articles need a UUID

        // Create new article with data from JSON
        let article = ArticleModel(
            id: articleId,
            jsonURL: articleJSON.jsonURL,
            url: articleJSON.url,
            title: articleJSON.title,
            body: articleJSON.body,
            domain: articleJSON.domain,
            articleTitle: articleJSON.articleTitle,
            affected: articleJSON.affected,
            publishDate: articleJSON.pubDate ?? Date(), // Use pubDate from JSON or current date as fallback
            topic: articleJSON.topic,
            sourcesQuality: articleJSON.sourcesQuality,
            argumentQuality: articleJSON.argumentQuality,
            sourceType: articleJSON.sourceType,
            sourceAnalysis: articleJSON.sourceAnalysis,
            quality: articleJSON.quality,
            summary: articleJSON.summary,
            criticalAnalysis: articleJSON.criticalAnalysis,
            logicalFallacies: articleJSON.logicalFallacies,
            relationToTopic: articleJSON.relationToTopic,
            additionalInsights: articleJSON.additionalInsights,
            engineStats: articleJSON.engineStats,
            similarArticles: articleJSON.similarArticles
        )

        // Add to the context
        context.insert(article)

        // Ensure topic relationship
        if let topicName = articleJSON.topic {
            try await ensureTopicRelationship(for: article, topicName: topicName, in: context)
        }

        logger.debug("Created new article with ID \(article.id)")
    }

    /// Ensures an article has the proper topic relationship
    /// - Parameters:
    ///   - article: Article to update
    ///   - topicName: Name of the topic
    ///   - context: SwiftData context to use
    private func ensureTopicRelationship(for article: ArticleModel, topicName: String, in context: ModelContext) async throws {
        // Find existing topic or create new one
        let topicDescriptor = FetchDescriptor<TopicModel>(
            predicate: #Predicate { topic in
                topic.name == topicName
            }
        )

        let existingTopics = try context.fetch(topicDescriptor)

        let topic: TopicModel
        if let existingTopic = existingTopics.first {
            topic = existingTopic
        } else {
            // Create new topic if it doesn't exist
            topic = TopicModel(
                name: topicName,
                // Default to normal priority, can be changed by user later
                priority: .normal,
                notificationsEnabled: false
            )
            context.insert(topic)
            logger.debug("Created new topic: \(topicName)")
        }

        // Set up bidirectional relationship
        if article.topics == nil {
            article.topics = [topic]
        } else if !article.topics!.contains(where: { $0.id == topic.id }) {
            article.topics!.append(topic)
        }
    }

    // MARK: - Article Status Management

    /// Marks an article as read/unread
    /// - Parameters:
    ///   - id: UUID of the article
    ///   - isRead: Whether the article should be marked as read
    func markArticle(id: UUID, asRead isRead: Bool) async throws {
        let context = ModelContext(modelContainer)

        do {
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate { article in
                    article.id == id
                }
            )

            guard let article = try context.fetch(descriptor).first else {
                logger.error("Cannot mark article as read: Article with ID \(id) not found")
                throw ArticleServiceError.notFound("Article with ID \(id) not found")
            }

            article.isViewed = isRead

            try context.save()
            logger.debug("Marked article \(id) as \(isRead ? "read" : "unread")")
        } catch let error as ArticleServiceError {
            throw error
        } catch {
            logger.error("Failed to mark article as \(isRead ? "read" : "unread"): \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(error)
        }
    }

    /// Marks an article as bookmarked/unbookmarked
    /// - Parameters:
    ///   - id: UUID of the article
    ///   - isBookmarked: Whether the article should be bookmarked
    func markArticle(id: UUID, asBookmarked isBookmarked: Bool) async throws {
        let context = ModelContext(modelContainer)

        do {
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate { article in
                    article.id == id
                }
            )

            guard let article = try context.fetch(descriptor).first else {
                logger.error("Cannot bookmark article: Article with ID \(id) not found")
                throw ArticleServiceError.notFound("Article with ID \(id) not found")
            }

            article.isBookmarked = isBookmarked

            try context.save()
            logger.debug("Marked article \(id) as \(isBookmarked ? "bookmarked" : "unbookmarked")")
        } catch let error as ArticleServiceError {
            throw error
        } catch {
            logger.error("Failed to mark article as \(isBookmarked ? "bookmarked" : "unbookmarked"): \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(error)
        }
    }

    // MARK: - Background Processing

    /// Performs a full sync in the background
    /// - Returns: Summary of sync results
    /// - Throws: Error if sync fails
    func performBackgroundSync() async throws -> SyncSummary {
        let startTime = Date()

        do {
            // First, get all topics to sync each one
            let topics = try await fetchAllTopics()
            var totalNewArticles = 0
            var syncedTopics = 0

            // Sync each topic individually for better organization
            for topic in topics {
                let newArticles = try await syncArticlesFromServer(topic: topic.name)
                totalNewArticles += newArticles
                syncedTopics += 1

                // Allow for task cancellation between topics
                try Task.checkCancellation()
            }

            // Also sync without topic filter to get uncategorized articles
            let uncategorizedCount = try await syncArticlesFromServer(topic: nil)
            totalNewArticles += uncategorizedCount

            let duration = Date().timeIntervalSince(startTime)

            // Create and return summary
            let summary = SyncSummary(
                newArticlesCount: totalNewArticles,
                syncedTopicsCount: syncedTopics,
                duration: duration,
                timestamp: Date()
            )

            logger.info("Background sync completed: \(totalNewArticles) new articles across \(syncedTopics) topics in \(String(format: "%.2f", duration))s")
            return summary

        } catch {
            logger.error("Background sync failed: \(error.localizedDescription)")
            throw ArticleServiceError.syncFailed(error)
        }
    }

    /// Summary of a sync operation
    struct SyncSummary {
        let newArticlesCount: Int
        let syncedTopicsCount: Int
        let duration: TimeInterval
        let timestamp: Date
    }

    /// Fetches all topics from the database
    /// - Returns: Array of TopicModel objects
    private func fetchAllTopics() async throws -> [TopicModel] {
        let context = ModelContext(modelContainer)

        do {
            let descriptor = FetchDescriptor<TopicModel>()
            let topics = try context.fetch(descriptor)
            return topics
        } catch {
            logger.error("Failed to fetch topics: \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(error)
        }
    }
}

// Using the existing ArticleJSON from ArticleModels.swift instead of redefining it here
