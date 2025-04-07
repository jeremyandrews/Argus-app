import Foundation
import SwiftData
import SwiftUI

/// Implementation of the ArticleServiceProtocol that provides CRUD operations and sync functionality
final class ArticleService: ArticleServiceProtocol {
    // Singleton instance for easy access
    static let shared = ArticleService()

    // Dependencies
    private let apiClient: APIClient
    private let modelContainer: ModelContainer

    // Cache management
    private let cache = NSCache<NSString, NSArray>()
    private let cacheExpiration: TimeInterval = 60 // 1 minute
    private var lastCacheUpdate = Date.distantPast
    private var cacheKeys = Set<String>()

    // Active tasks tracking
    private var activeSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    init(apiClient: APIClient = APIClient.shared, modelContainer: ModelContainer? = nil) {
        self.apiClient = apiClient

        // Use the provided container or get the shared one
        if let container = modelContainer {
            self.modelContainer = container
        } else {
            self.modelContainer = SwiftDataContainer.shared.container
        }
    }

    // MARK: - Fetch Operations

    func fetchArticles(
        topic: String?,
        isRead: Bool?,
        isBookmarked: Bool?,
        isArchived: Bool?,
        limit: Int?,
        offset: Int?
    ) async throws -> [NotificationData] {
        // Check cache first for common queries
        let cacheKey = createCacheKey(topic: topic, isRead: isRead, isBookmarked: isBookmarked, isArchived: isArchived)

        if let cachedResults = checkCache(for: cacheKey) {
            return cachedResults
        }

        // Build the predicate
        var predicate: Predicate<NotificationData>?

        // Topic predicate (most selective, so apply first)
        if let topic = topic, topic != "All" {
            predicate = #Predicate<NotificationData> { $0.topic == topic }
        }

        // Read status predicate
        if let isRead = isRead {
            let readPredicate = #Predicate<NotificationData> { $0.isViewed == isRead }
            if let existingPredicate = predicate {
                predicate = #Predicate<NotificationData> { existingPredicate.evaluate($0) && readPredicate.evaluate($0) }
            } else {
                predicate = readPredicate
            }
        }

        // Bookmarked status predicate
        if let isBookmarked = isBookmarked {
            let bookmarkPredicate = #Predicate<NotificationData> { $0.isBookmarked == isBookmarked }
            if let existingPredicate = predicate {
                predicate = #Predicate<NotificationData> { existingPredicate.evaluate($0) && bookmarkPredicate.evaluate($0) }
            } else {
                predicate = bookmarkPredicate
            }
        }

        // Archived status predicate
        if let isArchived = isArchived {
            let archivedPredicate = #Predicate<NotificationData> { $0.isArchived == isArchived }
            if let existingPredicate = predicate {
                predicate = #Predicate<NotificationData> { existingPredicate.evaluate($0) && archivedPredicate.evaluate($0) }
            } else {
                predicate = archivedPredicate
            }
        }

        // Create fetch descriptor
        var fetchDescriptor = FetchDescriptor<NotificationData>(predicate: predicate)

        // Apply sorting - default to newest first
        fetchDescriptor.sortBy = [SortDescriptor(\.pub_date, order: .reverse)]

        // Apply pagination if specified
        if let limit = limit {
            fetchDescriptor.fetchLimit = limit
        }

        if let offset = offset, offset > 0 {
            fetchDescriptor.fetchOffset = offset
        }

        // Execute the fetch in a dedicated context
        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)

            // Cache the results
            cacheResults(results, for: cacheKey)

            return results
        } catch {
            AppLogger.database.error("Error fetching articles: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func fetchArticle(byId id: UUID) async throws -> NotificationData? {
        let fetchDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { $0.id == id }
        )

        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)
            return results.first
        } catch {
            AppLogger.database.error("Error fetching article by ID: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func fetchArticle(byJsonURL jsonURL: String) async throws -> NotificationData? {
        let fetchDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { $0.json_url == jsonURL }
        )

        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)
            return results.first
        } catch {
            AppLogger.database.error("Error fetching article by JSON URL: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func searchArticles(queryText: String, limit: Int?) async throws -> [NotificationData] {
        guard !queryText.isEmpty else {
            return []
        }

        // Build the search predicate - search title and body
        let searchPredicate = #Predicate<NotificationData> {
            $0.title.localizedStandardContains(queryText) ||
                $0.body.localizedStandardContains(queryText)
        }

        var fetchDescriptor = FetchDescriptor<NotificationData>(predicate: searchPredicate)

        // Apply limit if specified
        if let limit = limit {
            fetchDescriptor.fetchLimit = limit
        }

        // Sort by relevance (approximated by date for now)
        fetchDescriptor.sortBy = [SortDescriptor(\.pub_date, order: .reverse)]

        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)
            return results
        } catch {
            AppLogger.database.error("Error searching articles: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    // MARK: - State Management Operations

    func markArticle(id: UUID, asRead isRead: Bool) async throws {
        guard let article = try await fetchArticle(byId: id) else {
            throw ArticleServiceError.articleNotFound
        }

        // Only proceed if the state is actually changing
        if article.isViewed == isRead {
            return
        }

        do {
            let context = ModelContext(modelContainer)

            // Re-fetch in this context
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate { $0.id == id }
            )

            guard let articleInContext = try context.fetch(descriptor).first else {
                throw ArticleServiceError.articleNotFound
            }

            // Update the property
            articleInContext.isViewed = isRead

            // Save the changes
            try context.save()

            // Clear cache since article state has changed
            clearCache()

            // Update badge count
            await NotificationUtils.updateAppBadgeCount()

            // Post notification for views to update
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("ArticleReadStatusChanged"),
                    object: nil,
                    userInfo: ["articleID": id, "isViewed": isRead]
                )
            }

        } catch {
            AppLogger.database.error("Error marking article as read: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func markArticle(id: UUID, asBookmarked isBookmarked: Bool) async throws {
        guard let article = try await fetchArticle(byId: id) else {
            throw ArticleServiceError.articleNotFound
        }

        // Only proceed if the state is actually changing
        if article.isBookmarked == isBookmarked {
            return
        }

        do {
            let context = ModelContext(modelContainer)

            // Re-fetch in this context
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate { $0.id == id }
            )

            guard let articleInContext = try context.fetch(descriptor).first else {
                throw ArticleServiceError.articleNotFound
            }

            // Update the property
            articleInContext.isBookmarked = isBookmarked

            // Save the changes
            try context.save()

            // Clear cache since article state has changed
            clearCache()

            // Post notification for views to update
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("ArticleBookmarkStatusChanged"),
                    object: nil,
                    userInfo: ["articleID": id, "isBookmarked": isBookmarked]
                )
            }

        } catch {
            AppLogger.database.error("Error marking article as bookmarked: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func markArticle(id: UUID, asArchived isArchived: Bool) async throws {
        guard let article = try await fetchArticle(byId: id) else {
            throw ArticleServiceError.articleNotFound
        }

        // Only proceed if the state is actually changing
        if article.isArchived == isArchived {
            return
        }

        do {
            let context = ModelContext(modelContainer)

            // Re-fetch in this context
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate { $0.id == id }
            )

            guard let articleInContext = try context.fetch(descriptor).first else {
                throw ArticleServiceError.articleNotFound
            }

            // Update the property
            articleInContext.isArchived = isArchived

            // Save the changes
            try context.save()

            // Clear cache since article state has changed
            clearCache()

            // Post notification for views to update
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("ArticleArchived"),
                    object: nil,
                    userInfo: ["articleID": id, "isArchived": isArchived]
                )
            }

            // Remove notification from system if article is archived
            if isArchived {
                // AppDelegate's method is actor-isolated, so we need to await it
                await AppDelegate().removeNotificationIfExists(jsonURL: article.json_url)
            }

        } catch {
            AppLogger.database.error("Error marking article as archived: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func deleteArticle(id: UUID) async throws {
        do {
            let context = ModelContext(modelContainer)

            // Re-fetch in this context
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate { $0.id == id }
            )

            guard let articleInContext = try context.fetch(descriptor).first else {
                throw ArticleServiceError.articleNotFound
            }

            // Save the JSON URL for notification removal
            let jsonURL = articleInContext.json_url

            // Delete the article
            context.delete(articleInContext)

            // Save the changes
            try context.save()

            // Clear cache since articles have changed
            clearCache()

            // Update badge count
            await NotificationUtils.updateAppBadgeCount()

            // Remove any system notification for this article
            if !jsonURL.isEmpty {
                // AppDelegate's method is actor-isolated, so we need to await it
                await AppDelegate().removeNotificationIfExists(jsonURL: jsonURL)
            }

            // Post notification about deletion
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .willDeleteArticle,
                    object: nil,
                    userInfo: ["articleID": id]
                )
            }

        } catch {
            AppLogger.database.error("Error deleting article: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    // MARK: - Sync Operations

    func syncArticlesFromServer(topic: String?, limit _: Int?) async throws -> Int {
        do {
            // Fetch articles from server with default limits
            // Note: The API sends all unseen articles, so we'll handle limiting after fetch
            let remoteArticles = try await apiClient.fetchArticles(
                topic: topic
            )

            // Process the articles
            return try await processRemoteArticles(remoteArticles)

        } catch {
            AppLogger.sync.error("Error syncing articles from server: \(error)")
            throw ArticleServiceError.networkError(underlyingError: error)
        }
    }

    func performBackgroundSync() async throws -> SyncResultSummary {
        // Cancel any existing task
        activeSyncTask?.cancel()

        // Start timing
        let startTime = Date()
        var addedCount = 0
        let updatedCount = 0
        let deletedCount = 0

        // Create a new task for syncing
        do {
            // Fetch subscribed topics
            let subscriptions = await SubscriptionsView().loadSubscriptions()
            let subscribedTopics = subscriptions.filter { $0.value.isSubscribed }.keys

            // Start with "All" topics sync (limited count)
            addedCount += try await syncArticlesFromServer(topic: nil, limit: 30)

            // Sync each subscribed topic
            for topic in subscribedTopics {
                // Check for cancellation before each topic
                try Task.checkCancellation()

                // Sync this topic (limited count)
                addedCount += try await syncArticlesFromServer(topic: topic, limit: 20)
            }

            // Update last sync time
            UserDefaults.standard.set(Date(), forKey: "lastSyncTime")

            // Calculate duration
            let duration = Date().timeIntervalSince(startTime)

            // Clear cache as we have new data
            clearCache()

            // Return the summary
            return SyncResultSummary(
                addedCount: addedCount,
                updatedCount: updatedCount,
                deletedCount: deletedCount,
                duration: duration
            )

        } catch {
            if error is CancellationError {
                throw ArticleServiceError.cancelled
            }
            AppLogger.sync.error("Error performing background sync: \(error)")
            throw ArticleServiceError.networkError(underlyingError: error)
        }
    }

    // MARK: - Rich Text Operations

    /// Generates initial rich text content for a new article
    /// This must run on the main actor to properly handle NSAttributedString
    @MainActor
    private func generateInitialRichText(for article: NotificationData) {
        // Generate the basic rich text for immediate display
        _ = getAttributedString(for: .title, from: article, createIfMissing: true)
        _ = getAttributedString(for: .body, from: article, createIfMissing: true)
    }

    /// Generates rich text content for an article field
    /// This entire method runs on the main actor to properly handle NSAttributedString
    @MainActor
    func generateRichTextContent(
        for articleId: UUID,
        field: RichTextField
    ) async throws -> NSAttributedString? {
        do {
            // Fetch the article
            let fetchDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { $0.id == articleId }
            )

            let context = ModelContext(modelContainer)
            let articles = try context.fetch(fetchDescriptor)

            guard let article = articles.first else {
                return nil
            }

            // Generate the attributed string
            let attributedString = getAttributedString(
                for: field,
                from: article,
                createIfMissing: true
            )

            return attributedString
        } catch {
            AppLogger.database.error("Error generating rich text content: \(error)")
            return nil
        }
    }

    // MARK: - Private Helper Methods

    private func processRemoteArticles(_ articles: [ArticleJSON]) async throws -> Int {
        guard !articles.isEmpty else { return 0 }

        let context = ModelContext(modelContainer)
        var addedCount = 0

        for article in articles {
            // Check if we already have this article
            let existingArticle = try await fetchArticle(byJsonURL: article.jsonURL)

            if existingArticle == nil {
                // Create a new article using the proper initializer
                let date = Date()
                let newArticle = NotificationData(
                    id: UUID(),
                    date: date,
                    title: article.title,
                    body: article.body,
                    json_url: article.jsonURL,
                    article_url: article.url,
                    topic: article.topic,
                    article_title: article.articleTitle,
                    affected: article.affected,
                    domain: article.domain ?? "",
                    pub_date: article.pubDate ?? date,
                    isViewed: false,
                    isBookmarked: false,
                    isArchived: false,
                    sources_quality: article.sourcesQuality,
                    argument_quality: article.argumentQuality,
                    source_type: article.sourceType,
                    source_analysis: article.sourceAnalysis,
                    quality: article.quality,
                    summary: article.summary,
                    critical_analysis: article.criticalAnalysis,
                    logical_fallacies: article.logicalFallacies,
                    relation_to_topic: article.relationToTopic,
                    additional_insights: article.additionalInsights
                )
                context.insert(newArticle)

                // Ensure we generate the rich text for at least title and body
                await generateInitialRichText(for: newArticle)

                addedCount += 1
            } else {
                // We already have this article - update any missing fields if needed
                // This could be expanded to update specific fields that might change
            }
        }

        // Save changes
        try context.save()

        // Clear cache as we have new data
        clearCache()

        // Return count of new articles
        return addedCount
    }

    // MARK: - Cache Management

    private func createCacheKey(
        topic: String?,
        isRead: Bool?,
        isBookmarked: Bool?,
        isArchived: Bool?
    ) -> String {
        let topicPart = topic ?? "all"
        let readPart = isRead == nil ? "any" : (isRead! ? "read" : "unread")
        let bookmarkPart = isBookmarked == nil ? "any" : (isBookmarked! ? "bookmarked" : "notBookmarked")
        let archivedPart = isArchived == nil ? "any" : (isArchived! ? "archived" : "notArchived")

        return "\(topicPart)_\(readPart)_\(bookmarkPart)_\(archivedPart)"
    }

    private func checkCache(for key: String) -> [NotificationData]? {
        // Check if cache is valid (not expired)
        let now = Date()
        if now.timeIntervalSince(lastCacheUpdate) > cacheExpiration {
            clearCache()
            return nil
        }

        // Check if we have this key in cache
        if let cachedArray = cache.object(forKey: key as NSString) as? [NotificationData] {
            return cachedArray
        }

        return nil
    }

    private func cacheResults(_ results: [NotificationData], for key: String) {
        cache.setObject(results as NSArray, forKey: key as NSString)
        cacheKeys.insert(key)
        lastCacheUpdate = Date()
    }

    private func clearCache() {
        cache.removeAllObjects()
        cacheKeys.removeAll()
        lastCacheUpdate = Date.distantPast
    }
}
