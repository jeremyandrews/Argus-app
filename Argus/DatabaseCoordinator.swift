import Combine
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// DatabaseCoordinator provides a centralized, thread-safe interface for all database operations.
/// It uses Swift's actor model to ensure proper isolation and concurrency safety.
actor DatabaseCoordinator {
    // MARK: - Singleton Instance

    // MARK: - Private Properties

    /// The model container for database access
    private let container: ModelContainer

    /// Cache of contexts for specific operations
    private var operationContexts = [String: ModelContext]()

    /// Logger for database operations
    private let logger = AppLogger.database

    /// Caches to track recently processed data to prevent duplicates and redundant lookups
    private var recentlyProcessedIDs = NSCache<NSString, NSDate>()
    private var recentlyCheckedURLs = NSCache<NSString, NSDate>()
    private var recentlyCheckedIDs = NSCache<NSString, NSDate>()
    private let idCacheExpirationInterval: TimeInterval = 600 // 10 minutes
    private let lookupCacheExpirationInterval: TimeInterval = 60 // 1 minute

    // MARK: - Initialization

    /// Shared container for initialization
    private static var _sharedContainer: ModelContainer?

    /// Private initializer for singleton pattern
    private init() async {
        // Get the container from the ArgusApp singleton via MainActor
        if let existingContainer = DatabaseCoordinator._sharedContainer {
            container = existingContainer
        } else {
            // Access the MainActor-isolated property safely
            container = await MainActor.run {
                let container = ArgusApp.sharedModelContainer
                DatabaseCoordinator._sharedContainer = container
                return container
            }
        }

        // Setup the ID cache
        recentlyProcessedIDs.countLimit = 1000

        logger.info("DatabaseCoordinator initialized")
    }

    /// Create the shared instance with proper isolation
    static func createShared() async -> DatabaseCoordinator {
        return await DatabaseCoordinator()
    }

    /// Lazy initialization of the shared instance
    static var _shared: DatabaseCoordinator?

    /// Shared instance for application-wide use - dynamically initialized on first access
    static var shared: DatabaseCoordinator {
        get async {
            if let existing = _shared {
                return existing
            }

            let newCoordinator = await createShared()
            _shared = newCoordinator
            return newCoordinator
        }
    }

    // MARK: - Context Management

    /// Get a context for a specific operation, creating a new one if needed
    /// - Parameter operation: A string identifier for the operation
    /// - Returns: A ModelContext for the operation
    private func getContext(for operation: String = "default") -> ModelContext {
        if let existingContext = operationContexts[operation] {
            return existingContext
        }

        let context = ModelContext(container)
        operationContexts[operation] = context
        return context
    }

    /// Execute a transaction with proper error handling and isolation
    /// - Parameters:
    ///   - operation: Identifier for the operation
    ///   - block: The transaction block to execute
    /// - Returns: The result of the transaction
    func performTransaction<T>(_ operation: String = "default", _ block: @Sendable (isolated DatabaseCoordinator, ModelContext) async throws -> T) async throws -> T {
        // Get context within actor's isolation domain
        let context = getContext(for: operation)

        // Disable auto-save during transaction for better control
        context.autosaveEnabled = false

        do {
            // Execute the transaction within actor isolation domain
            // by passing self and the context to the block
            let result = try await block(self, context)

            // Save changes if the transaction completes successfully
            try context.save()

            return result
        } catch {
            // Log the error and rethrow
            logger.error("Transaction failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Duplicate Prevention

    /// Check if an ID was recently processed and mark it as processed if not
    /// - Parameter id: The UUID to check
    /// - Returns: True if the ID was recently processed (duplicate), false otherwise
    private func checkAndMarkIDAsProcessed(id: UUID) -> Bool {
        let idString = id.uuidString as NSString
        let now = Date()

        // Check if this ID was processed recently
        if let processedDate = recentlyProcessedIDs.object(forKey: idString) {
            // If the entry is recent enough, it's a duplicate
            if now.timeIntervalSince(processedDate as Date) < idCacheExpirationInterval {
                logger.debug("Duplicate ID detected via in-memory cache: \(id)")
                return true
            }
        }

        // Not a duplicate (or expired entry), mark as processed
        recentlyProcessedIDs.setObject(now as NSDate, forKey: idString)
        return false
    }

    // MARK: - Article Operations

    /// Find an article by its ID
    /// - Parameter id: The UUID of the article
    /// - Returns: The article if found, nil otherwise
    func findArticle(by id: UUID) async -> NotificationData? {
        try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.id == id
                }
            )

            return try context.fetch(descriptor).first
        }
    }

    /// Find an article by its JSON URL
    /// - Parameter jsonURL: The JSON URL of the article
    /// - Returns: The article if found, nil otherwise
    func findArticle(by jsonURL: String) async -> NotificationData? {
        try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.json_url == jsonURL
                }
            )

            return try context.fetch(descriptor).first
        }
    }

    /// Find an article by multiple criteria (best-effort match)
    /// - Parameters:
    ///   - jsonURL: The JSON URL of the article
    ///   - id: Optional UUID of the article
    ///   - articleURL: Optional article URL
    /// - Returns: The article if found, nil otherwise
    func findArticle(jsonURL: String, id: UUID? = nil, articleURL: String? = nil) async -> NotificationData? {
        try? await performTransaction { _, context in
            // First priority - check by ID if provided
            if let id = id {
                let idDescriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.id == id
                    }
                )

                if let article = try context.fetch(idDescriptor).first {
                    self.logger.debug("Article found by ID: \(id)")
                    return article
                }
            }

            // Second priority - check by jsonURL
            if !jsonURL.isEmpty {
                let urlDescriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.json_url == jsonURL
                    }
                )

                if let article = try context.fetch(urlDescriptor).first {
                    self.logger.debug("Article found by jsonURL: \(jsonURL)")
                    return article
                }
            }

            // Last priority - check by article URL
            if let articleURL = articleURL, !articleURL.isEmpty {
                let articleURLDescriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.article_url == articleURL
                    }
                )

                if let article = try context.fetch(articleURLDescriptor).first {
                    self.logger.debug("Article found by articleURL: \(articleURL)")
                    return article
                }
            }

            self.logger.debug("Article not found: \(jsonURL)")
            return nil
        }
    }

    /// Optimized check if an article exists by its ID
    /// - Parameter id: The UUID of the article
    /// - Returns: True if the article exists, false otherwise
    func articleExists(id: UUID) async -> Bool {
        // Check the memory cache first for instant response
        let idString = id.uuidString as NSString
        let now = Date()

        // Return immediately if we recently checked this ID
        if let cacheDate = recentlyCheckedIDs.object(forKey: idString),
           now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
        {
            logger.debug("Cache hit for ID existence check: \(id)")
            return true
        }

        // Optimized database lookup with fetchLimit=1
        let exists = (try? await performTransaction { _, context in
            var descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.id == id
                }
            )
            // Only need to know if any exist, not fetch the whole record
            descriptor.fetchLimit = 1

            return try context.fetchCount(descriptor) > 0
        }) ?? false

        // Cache the result if it exists
        if exists {
            recentlyCheckedIDs.setObject(now as NSDate, forKey: idString)
        }

        return exists
    }

    /// Optimized check if an article exists by its JSON URL
    /// - Parameter jsonURL: The JSON URL of the article
    /// - Returns: True if the article exists, false otherwise
    func articleExists(jsonURL: String) async -> Bool {
        // Check the memory cache first for instant response
        let urlKey = jsonURL as NSString
        let now = Date()

        // Return immediately if we recently checked this URL
        if let cacheDate = recentlyCheckedURLs.object(forKey: urlKey),
           now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
        {
            logger.debug("Cache hit for URL existence check: \(jsonURL)")
            return true
        }

        // Optimized database lookup with fetchLimit=1
        let exists = (try? await performTransaction { _, context in
            var descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.json_url == jsonURL
                }
            )
            // Only need to know if any exist, not fetch the whole record
            descriptor.fetchLimit = 1

            return try context.fetchCount(descriptor) > 0
        }) ?? false

        // Cache the result if it exists
        if exists {
            recentlyCheckedURLs.setObject(now as NSDate, forKey: urlKey)
        }

        return exists
    }

    /// Optimized check if an article exists by any of the provided criteria
    /// - Parameters:
    ///   - jsonURL: The JSON URL of the article
    ///   - id: Optional UUID of the article
    ///   - articleURL: Optional article URL
    /// - Returns: True if the article exists, false otherwise
    func articleExists(jsonURL: String, id: UUID? = nil, articleURL: String? = nil) async -> Bool {
        // First check ID (most unique) - use memory cache and focused query
        if let id = id {
            let idString = id.uuidString as NSString
            let now = Date()

            // Check memory cache first for ID
            if let cacheDate = recentlyCheckedIDs.object(forKey: idString),
               now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
            {
                logger.debug("Cache hit for ID existence check: \(id)")
                return true
            }

            // Optimized database lookup for ID
            let existsById = (try? await performTransaction { _, context in
                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.id == id
                    }
                )
                descriptor.fetchLimit = 1
                return try context.fetchCount(descriptor) > 0
            }) ?? false

            if existsById {
                // Cache the result
                recentlyCheckedIDs.setObject(now as NSDate, forKey: idString)
                return true
            }
        }

        // Next check URL
        if !jsonURL.isEmpty {
            let urlKey = jsonURL as NSString
            let now = Date()

            // Check memory cache first for URL
            if let cacheDate = recentlyCheckedURLs.object(forKey: urlKey),
               now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
            {
                logger.debug("Cache hit for URL existence check: \(jsonURL)")
                return true
            }

            // Optimized database lookup for URL
            let existsByUrl = (try? await performTransaction { _, context in
                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.json_url == jsonURL
                    }
                )
                descriptor.fetchLimit = 1
                return try context.fetchCount(descriptor) > 0
            }) ?? false

            if existsByUrl {
                // Cache the result
                recentlyCheckedURLs.setObject(now as NSDate, forKey: urlKey)
                return true
            }
        }

        // Lastly check article URL if provided
        if let articleURL = articleURL, !articleURL.isEmpty {
            // Don't cache article URL lookups as they're less common
            return (try? await performTransaction { _, context in
                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { article in
                        article.article_url == articleURL
                    }
                )
                descriptor.fetchLimit = 1
                return try context.fetchCount(descriptor) > 0
            }) ?? false
        }

        return false
    }

    /// Find existing articles in a batch by IDs
    /// - Parameter ids: Array of UUIDs to check
    /// - Returns: Dictionary mapping UUIDs to found articles
    func findExistingArticles(ids: [UUID]) async -> [UUID: NotificationData] {
        guard !ids.isEmpty else { return [:] }

        // Collect all results as an array first to avoid concurrent mutation
        let pairs = await withTaskGroup(of: (UUID, NotificationData?).self, returning: [(UUID, NotificationData)].self) { group in
            // Add all tasks to the group
            for id in ids {
                group.addTask {
                    let article = await self.findArticle(by: id)
                    return (id, article)
                }
            }

            // Safely collect non-nil results
            var validResults: [(UUID, NotificationData)] = []
            for await (id, articleOption) in group {
                if let article = articleOption {
                    validResults.append((id, article))
                }
            }

            return validResults
        }

        // Convert the array to a dictionary once all tasks are complete
        var results = [UUID: NotificationData]()
        for (id, article) in pairs {
            results[id] = article
        }

        return results
    }

    /// Find existing articles in a batch by JSON URLs
    /// - Parameter jsonURLs: Array of JSON URLs to check
    /// - Returns: Dictionary mapping JSON URLs to found articles
    func findExistingArticles(jsonURLs: [String]) async -> [String: NotificationData] {
        guard !jsonURLs.isEmpty else { return [:] }

        // Use a transaction that returns the result dictionary to avoid Swift 6 concurrency errors
        let results = try? await performTransaction { _, context in
            // Create a local dictionary inside the transaction
            var localResults = [String: NotificationData]()

            let descriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    jsonURLs.contains(article.json_url)
                }
            )

            let articles = try context.fetch(descriptor)

            // Populate the local dictionary
            for article in articles {
                localResults[article.json_url] = article
            }

            // Return the local results dictionary from the transaction
            return localResults
        }

        // Return the results or an empty dictionary if the transaction failed
        return results ?? [:]
    }

    /// Optimized check for which articles exist in a batch
    /// - Parameters:
    ///   - jsonURLs: Array of JSON URLs to check
    ///   - ids: Optional array of UUIDs to check
    /// - Returns: Tuple of sets containing existing JSON URLs and UUIDs
    func batchArticleExistsCheck(jsonURLs: [String], ids: [UUID]? = nil) async -> (jsonURLs: Set<String>, ids: Set<UUID>) {
        // Early return if nothing to check
        guard !jsonURLs.isEmpty || (ids?.isEmpty == false) else {
            return (jsonURLs: Set(), ids: Set())
        }

        // Check caches first for fast response
        let now = Date()
        var cachedURLs = Set<String>()
        var cachedIDs = Set<UUID>()

        // Check URL cache - we can quickly eliminate known URLs
        for url in jsonURLs {
            let urlKey = url as NSString
            if let cacheDate = recentlyCheckedURLs.object(forKey: urlKey),
               now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
            {
                cachedURLs.insert(url)
            }
        }

        // Check ID cache if IDs were provided
        if let ids = ids {
            for id in ids {
                let idKey = id.uuidString as NSString
                if let cacheDate = recentlyCheckedIDs.object(forKey: idKey),
                   now.timeIntervalSince(cacheDate as Date) < lookupCacheExpirationInterval
                {
                    cachedIDs.insert(id)
                }
            }
        }

        // Filter out URLs that we already know exist
        let urlsToCheck = jsonURLs.filter { !cachedURLs.contains($0) }
        let idsToCheck = ids?.filter { !cachedIDs.contains($0) } ?? []

        // If everything is in cache, we can return immediately
        if urlsToCheck.isEmpty, idsToCheck.isEmpty {
            logger.debug("Batch check: All items found in cache - \(cachedURLs.count) URLs and \(cachedIDs.count) IDs")
            return (jsonURLs: cachedURLs, ids: cachedIDs)
        }

        // Now check database for remaining items
        // Make copies of captured variables for use in concurrent context
        let cachedURLsCopy = cachedURLs
        let cachedIDsCopy = cachedIDs

        // Use fallback cache if transaction fails
        return (try? await performTransaction { _, context in
            var existingURLs = cachedURLsCopy
            var existingIDs = cachedIDsCopy

            // Process URLs in batches of 100 for more efficient queries
            if !urlsToCheck.isEmpty {
                for urlBatch in urlsToCheck.chunked(into: 100) {
                    // Check NotificationData
                    var urlDescriptor = FetchDescriptor<NotificationData>(
                        predicate: #Predicate<NotificationData> { article in
                            urlBatch.contains(article.json_url)
                        }
                    )

                    // Only fetch the specific properties we need
                    urlDescriptor.propertiesToFetch = [\.id, \.json_url]

                    let articles = try context.fetch(urlDescriptor)
                    for article in articles {
                        existingURLs.insert(article.json_url)
                        existingIDs.insert(article.id)

                        // Already inserted above - no further action needed
                    }

                    // Also check SeenArticle table
                    var seenDescriptor = FetchDescriptor<SeenArticle>(
                        predicate: #Predicate<SeenArticle> { seen in
                            urlBatch.contains(seen.json_url)
                        }
                    )
                    seenDescriptor.propertiesToFetch = [\.id, \.json_url]

                    let seenArticles = try context.fetch(seenDescriptor)
                    for seen in seenArticles {
                        existingURLs.insert(seen.json_url)
                        existingIDs.insert(seen.id)

                        // Already added to the sets above
                    }
                }
            }

            // Process IDs in batches if provided
            if !idsToCheck.isEmpty {
                for idBatch in idsToCheck.chunked(into: 100) {
                    // Check NotificationData
                    var idDescriptor = FetchDescriptor<NotificationData>(
                        predicate: #Predicate<NotificationData> { article in
                            idBatch.contains(article.id)
                        }
                    )
                    idDescriptor.propertiesToFetch = [\.id, \.json_url]

                    let articles = try context.fetch(idDescriptor)
                    for article in articles {
                        existingIDs.insert(article.id)
                        existingURLs.insert(article.json_url)

                        // Already added to the sets above
                    }

                    // Also check SeenArticle table
                    var seenDescriptor = FetchDescriptor<SeenArticle>(
                        predicate: #Predicate<SeenArticle> { seen in
                            idBatch.contains(seen.id)
                        }
                    )
                    seenDescriptor.propertiesToFetch = [\.id, \.json_url]

                    let seenArticles = try context.fetch(seenDescriptor)
                    for seen in seenArticles {
                        existingIDs.insert(seen.id)
                        existingURLs.insert(seen.json_url)

                        // Already added to the sets above
                    }
                }
            }

            self.logger.debug("Batch check: found \(existingURLs.count) URLs and \(existingIDs.count) IDs (including \(cachedURLsCopy.count) cached URLs)")

            return (existingURLs, existingIDs)
        }) ?? (cachedURLs, cachedIDs)
    }

    /// Save an article to the database
    /// - Parameter articleJSON: The article data to save
    /// - Returns: The saved NotificationData object
    func saveArticle(_ articleJSON: ArticleJSON) async throws -> NotificationData {
        // Extract UUID from the URL filename if possible
        let fileName = articleJSON.jsonURL.split(separator: "/").last ?? ""
        var extractedID: UUID? = nil

        if let uuidRange = fileName.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) {
            let uuidString = String(fileName[uuidRange])
            extractedID = UUID(uuidString: uuidString)
        }

        // Make sure we have a valid ID
        guard let articleID = extractedID else {
            logger.error("Failed to extract valid UUID from article URL: \(articleJSON.jsonURL)")
            throw DatabaseError.invalidArticleID
        }

        // Check if this is a duplicate using our in-memory cache
        if checkAndMarkIDAsProcessed(id: articleID) {
            logger.debug("Skipping duplicate article with ID \(articleID)")
            throw DatabaseError.duplicateArticle
        }

        // Look for existing article
        if let existingArticle = await findArticle(jsonURL: articleJSON.jsonURL, id: articleID) {
            // Update existing article
            return try await updateArticle(existingArticle, with: articleJSON)
        }

        // Create a new article
        return try await performTransaction { _, context in
            let date = Date()

            // Extract additional data from the article JSON
            let engineStatsJSON = articleJSON.engineStats
            let similarArticlesJSON = articleJSON.similarArticles

            // Create notification data
            let notification = NotificationData(
                id: articleID,
                date: date,
                title: articleJSON.title,
                body: articleJSON.body,
                json_url: articleJSON.jsonURL,
                article_url: articleJSON.url,
                topic: articleJSON.topic,
                article_title: articleJSON.articleTitle,
                affected: articleJSON.affected,
                domain: articleJSON.domain,
                pub_date: articleJSON.pubDate ?? date,
                isViewed: false,
                isBookmarked: false,
                sources_quality: articleJSON.sourcesQuality,
                argument_quality: articleJSON.argumentQuality,
                source_type: articleJSON.sourceType,
                source_analysis: articleJSON.sourceAnalysis,
                quality: articleJSON.quality,
                summary: articleJSON.summary,
                critical_analysis: articleJSON.criticalAnalysis,
                logical_fallacies: articleJSON.logicalFallacies,
                relation_to_topic: articleJSON.relationToTopic,
                additional_insights: articleJSON.additionalInsights,
                engine_stats: engineStatsJSON,
                similar_articles: similarArticlesJSON
            )

            // Create seen article record
            let seenArticle = SeenArticle(
                id: articleID,
                json_url: articleJSON.jsonURL,
                date: date
            )

            // Double-check there's no article with this ID
            let finalIDCheck = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { existing in
                    existing.id == articleID
                }
            )

            // Last-minute duplicate check
            if let existingDuplicate = try? context.fetch(finalIDCheck).first {
                self.logger.debug("Last-minute duplicate detection - updating instead of inserting: \(articleID)")
                await self.updateFields(of: existingDuplicate, with: articleJSON)

                // Only insert the SeenArticle record if it doesn't exist
                let existingSeenCheck = FetchDescriptor<SeenArticle>(
                    predicate: #Predicate<SeenArticle> { seen in
                        seen.id == articleID
                    }
                )

                if (try? context.fetch(existingSeenCheck).first) == nil {
                    context.insert(seenArticle)
                }

                // Generate rich text synchronously for the duplicate
                await MainActor.run {
                    _ = getAttributedString(for: .title, from: existingDuplicate, createIfMissing: true)
                    _ = getAttributedString(for: .body, from: existingDuplicate, createIfMissing: true)
                }

                return existingDuplicate
            } else {
                // Insert both records
                context.insert(notification)
                context.insert(seenArticle)

                // Generate rich text attributes synchronously on the main actor
                // This ensures rich text is created before the article is saved
                await MainActor.run {
                    _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
                    _ = getAttributedString(for: .body, from: notification, createIfMissing: true)
                }

                return notification
            }
        }
    }

    /// Update an existing article with new data
    /// - Parameters:
    ///   - article: The article to update
    ///   - data: The new data to apply
    /// - Returns: The updated article
    func updateArticle(_ article: NotificationData, with data: ArticleJSON) async throws -> NotificationData {
        try await performTransaction { _, context in
            // Store the ID as a regular UUID to avoid context issues
            let articleId = article.id

            // Fetch a fresh copy of the article in this context
            let fetchDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.id == articleId
                }
            )

            guard let freshArticle = try context.fetch(fetchDescriptor).first else {
                throw DatabaseError.contextError
            }

            // Update all fields
            await self.updateFields(of: freshArticle, with: data)

            // Get the ID for the SeenArticle query
            let freshArticleId = freshArticle.id

            // Ensure the SeenArticle record exists
            let seenCheckDescriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seen in
                    seen.id == freshArticleId
                }
            )

            if (try? context.fetch(seenCheckDescriptor).first) == nil {
                let seenArticle = SeenArticle(
                    id: freshArticle.id,
                    json_url: freshArticle.json_url,
                    date: Date()
                )
                context.insert(seenArticle)
            }

            // Generate rich text attributes synchronously on the main actor
            // This ensures rich text is created before the transaction completes
            await MainActor.run {
                _ = getAttributedString(for: .title, from: freshArticle, createIfMissing: true)
                _ = getAttributedString(for: .body, from: freshArticle, createIfMissing: true)
            }

            return freshArticle
        }
    }

    /// Helper method to update the fields of an article
    /// - Parameters:
    ///   - article: The article to update
    ///   - data: The new data to apply
    private func updateFields(of article: NotificationData, with data: ArticleJSON) async {
        // Update notification fields
        article.title = data.title
        article.body = data.body
        article.json_url = data.jsonURL
        article.article_url = data.url
        article.topic = data.topic
        article.article_title = data.articleTitle
        article.affected = data.affected
        article.domain = data.domain

        // Only update the pubDate if the new one has a value
        if let pubDate = data.pubDate {
            article.pub_date = pubDate
        }

        // Don't override user-specific flags
        // article.isViewed remains unchanged
        // article.isBookmarked remains unchanged
        // Archive functionality removed

        // Update quality indicators
        article.sources_quality = data.sourcesQuality
        article.argument_quality = data.argumentQuality
        article.source_type = data.sourceType
        article.source_analysis = data.sourceAnalysis
        article.quality = data.quality

        // Update content analysis
        article.summary = data.summary
        article.critical_analysis = data.criticalAnalysis
        article.logical_fallacies = data.logicalFallacies
        article.relation_to_topic = data.relationToTopic
        article.additional_insights = data.additionalInsights

        // Update metadata
        article.engine_stats = data.engineStats
        article.similar_articles = data.similarArticles
    }

    // MARK: - Query Operations

    /// Fetch articles for a specific topic with optimized performance
    /// - Parameters:
    ///   - topic: The topic to filter by, or "All" for all topics
    ///   - showUnreadOnly: Whether to show only unread articles
    ///   - showBookmarkedOnly: Whether to show only bookmarked articles
    /// - Returns: Array of filtered notifications
    func fetchArticlesForTopic(
        _ topic: String,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool
    ) async -> [NotificationData] {
        // Use a transaction that returns the result array directly
        let results = try? await performTransaction { _, context in
            // Build an optimized predicate based on filter combination
            var predicate: Predicate<NotificationData>?

            // 1. Apply topic filter if not "All"
            if topic != "All" {
                predicate = #Predicate<NotificationData> { article in
                    article.topic == topic
                }
            }

            // 2. Apply unread filter if needed
            if showUnreadOnly {
                let unreadPredicate = #Predicate<NotificationData> { article in
                    !article.isViewed
                }

                if let existingPredicate = predicate {
                    predicate = #Predicate<NotificationData> { article in
                        existingPredicate.evaluate(article) && unreadPredicate.evaluate(article)
                    }
                } else {
                    predicate = unreadPredicate
                }
            }

            // 3. Apply bookmarked filter if needed
            if showBookmarkedOnly {
                let bookmarkedPredicate = #Predicate<NotificationData> { article in
                    article.isBookmarked
                }

                if let existingPredicate = predicate {
                    predicate = #Predicate<NotificationData> { article in
                        existingPredicate.evaluate(article) && bookmarkedPredicate.evaluate(article)
                    }
                } else {
                    predicate = bookmarkedPredicate
                }
            }

            // Archive filter removed

            // Create the fetch descriptor with our optimized predicate
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.pub_date, order: .reverse)]
            )

            // Fetch and return in a single transaction for better performance
            return try context.fetch(descriptor)
        }

        return results ?? []
    }

    /// Fetch recent articles since a specified date
    /// - Parameter date: The date to fetch articles from
    /// - Returns: Array of seen articles
    func fetchRecentArticles(since date: Date = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!) async -> [SeenArticle] {
        // Use a transaction that returns the result array to avoid Swift 6 concurrency errors
        let results = try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seenArticle in
                    seenArticle.date >= date
                }
            )

            // Return the results directly from the transaction
            return try context.fetch(descriptor)
        }

        return results ?? []
    }

    /// Fetch articles matching a predicate
    /// - Parameter predicate: The predicate to match
    /// - Returns: Array of matching articles
    func fetchArticles(matching predicate: Predicate<NotificationData>) async -> [NotificationData] {
        // Use a transaction that returns the results directly to avoid Swift 6 concurrency errors
        let results = try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<NotificationData>(predicate: predicate)
            return try context.fetch(descriptor)
        }

        return results ?? []
    }

    /// Count articles matching a predicate
    /// - Parameter predicate: The predicate to match
    /// - Returns: The number of matching articles
    func countArticles(matching predicate: Predicate<NotificationData>) async -> Int {
        // Use a transaction that returns the count directly to avoid Swift 6 concurrency errors
        let count = try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<NotificationData>(predicate: predicate)
            return try context.fetchCount(descriptor)
        }

        return count ?? 0
    }

    // MARK: - Maintenance Operations

    /// Perform database maintenance
    func performMaintenance() async {
        logger.info("Starting database maintenance")

        // Currently just updating metrics and logs
        // Could be expanded with more optimization tasks in the future

        // Update maintenance metrics
        await MainActor.run {
            UserDefaults.standard.set(0, forKey: "articleMaintenanceMetric")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastMaintenanceTime")
        }

        logger.info("Database maintenance completed")
    }

    /// Clear all caches
    func clearCaches() async {
        // Clear in-memory caches
        recentlyProcessedIDs.removeAllObjects()

        logger.info("Database caches cleared")
    }

    /// Get database statistics
    /// - Returns: Dictionary of statistics
    func getDatabaseStatistics() async -> [String: Any] {
        // Use a transaction that returns the statistics directly to avoid Swift 6 concurrency errors
        let stats = try? await performTransaction { _, context in
            // Create a local dictionary inside the transaction
            var localStats = [String: Any]()

            // Count all articles
            let articleCount = try context.fetchCount(FetchDescriptor<NotificationData>())
            localStats["articleCount"] = articleCount

            // Count seen articles
            let seenCount = try context.fetchCount(FetchDescriptor<SeenArticle>())
            localStats["seenCount"] = seenCount

            // Count unread articles
            let unreadDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    !article.isViewed
                }
            )
            let unreadCount = try context.fetchCount(unreadDescriptor)
            localStats["unreadCount"] = unreadCount

            // Count bookmarked articles
            let bookmarkedDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { article in
                    article.isBookmarked
                }
            )
            let bookmarkedCount = try context.fetchCount(bookmarkedDescriptor)
            localStats["bookmarkedCount"] = bookmarkedCount

            // Return the local stats dictionary from the transaction
            return localStats
        }

        // Return the results or an empty dictionary if the transaction failed
        return stats ?? [:]
    }
}

// MARK: - Error Types

/// Errors that can occur in database operations
enum DatabaseError: Error, LocalizedError, Equatable {
    case invalidArticleID
    case duplicateArticle
    case contextError
    case transactionError(String)

    var errorDescription: String? {
        switch self {
        case .invalidArticleID:
            return "Invalid article ID"
        case .duplicateArticle:
            return "Article already exists"
        case .contextError:
            return "Error accessing database context"
        case let .transactionError(message):
            return "Transaction error: \(message)"
        }
    }

    static func == (lhs: DatabaseError, rhs: DatabaseError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidArticleID, .invalidArticleID),
             (.duplicateArticle, .duplicateArticle),
             (.contextError, .contextError):
            return true
        case let (.transactionError(lhsMessage), .transactionError(rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

// We don't need to add Sendable conformance to ModelContext
// The actor provides isolation for all database operations
// and handles thread safety automatically

// MARK: - SyncManager Integration

extension DatabaseCoordinator {
    /// Process article JSON data in the same way as SyncManager
    func syncProcessArticleJSON(_ json: [String: Any]) -> ArticleJSON? {
        guard let title = json["tiny_title"] as? String,
              let body = json["tiny_summary"] as? String
        else {
            logger.error("Missing required fields in article JSON")
            return nil
        }

        let jsonURL = json["json_url"] as? String ?? ""
        let url = json["url"] as? String ?? json["article_url"] as? String ?? ""
        let domain = extractDomain(from: url)

        // Extract date if available
        var pubDate: Date?
        if let pubDateString = json["pub_date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            pubDate = formatter.date(from: pubDateString)

            if pubDate == nil {
                // Try alternative date formats
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                pubDate = fallbackFormatter.date(from: pubDateString)
            }
        }

        // Directly cast quality values from the JSON
        let sourcesQuality = json["sources_quality"] as? Int
        let argumentQuality = json["argument_quality"] as? Int
        let quality: Int? = (json["quality"] as? Double).map { Int($0) }

        // Create the article JSON object
        return ArticleJSON(
            title: title,
            body: body,
            jsonURL: jsonURL,
            url: url,
            topic: json["topic"] as? String,
            articleTitle: json["article_title"] as? String ?? "",
            affected: json["affected"] as? String ?? "",
            domain: domain,
            pubDate: pubDate,
            sourcesQuality: sourcesQuality,
            argumentQuality: argumentQuality,
            sourceType: json["source_type"] as? String,
            sourceAnalysis: json["source_analysis"] as? String,
            quality: quality,
            summary: json["summary"] as? String,
            criticalAnalysis: json["critical_analysis"] as? String,
            logicalFallacies: json["logical_fallacies"] as? String,
            relationToTopic: json["relation_to_topic"] as? String,
            additionalInsights: json["additional_insights"] as? String,
            engineStats: extractEngineStats(from: json),
            similarArticles: extractSimilarArticles(from: json)
        )
    }

    // We now use the global extractDomain function from CommonUtilities.swift

    // Helper to extract engine stats from JSON
    private func extractEngineStats(from json: [String: Any]) -> String? {
        var engineStatsDict: [String: Any] = [:]

        if let model = json["model"] as? String {
            engineStatsDict["model"] = model
        }

        if let elapsedTime = json["elapsed_time"] as? Double {
            engineStatsDict["elapsed_time"] = elapsedTime
        }

        if let stats = json["stats"] as? String {
            engineStatsDict["stats"] = stats
        }

        if let systemInfo = json["system_info"] as? [String: Any] {
            engineStatsDict["system_info"] = systemInfo
        }

        if engineStatsDict.isEmpty {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: engineStatsDict), encoding: .utf8)
    }

    // Helper to extract similar articles from JSON
    private func extractSimilarArticles(from json: [String: Any]) -> String? {
        guard let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty else {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: similarArticles), encoding: .utf8)
    }
}

// MARK: - DatabaseCoordinator Notification Support

// Note: We use the existing notification names defined in SyncManager

// MARK: - DatabaseCoordinator Convenience Extensions

// Extension for working with ArticleQueueModel
extension DatabaseCoordinator {
    /// Process an article from its JSON URL
    /// - Parameter jsonURL: The URL of the article JSON
    /// - Returns: Success or failure
    func processArticle(jsonURL: String) async -> Bool {
        // First - perform a thorough check if the article already exists in our database
        // This prevents unnecessary network requests and duplicate articles
        if await articleExists(jsonURL: jsonURL) {
            // Article already exists, this is a successful outcome
            logger.debug("Article already exists, skipping fetch: \(jsonURL)")
            return true
        }

        // Extract article ID from URL if possible, for better logging
        let articleId = extractArticleIDFromURL(jsonURL)
        let articleIdString = articleId?.uuidString ?? "unknown"

        // Attempt to fetch and process the article
        do {
            // Fetch article data from the URL
            guard let url = URL(string: jsonURL) else {
                logger.error("Invalid URL format: \(jsonURL)")
                throw URLError(.badURL)
            }

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)

            // Get both data and response so we can check HTTP status
            let (data, response) = try await session.data(from: url)

            // Check for HTTP response codes
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    logger.error("Article not found (404): \(jsonURL)")
                    return false
                } else if httpResponse.statusCode != 200 {
                    logger.error("HTTP error \(httpResponse.statusCode) fetching article: \(jsonURL)")
                    return false
                }
            }

            // Parse the JSON
            guard let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("Invalid JSON format for article: \(articleIdString)")
                throw DatabaseError.transactionError("Invalid JSON data in response")
            }

            // Ensure the json_url is set
            var enrichedJson = rawJson
            if enrichedJson["json_url"] == nil {
                enrichedJson["json_url"] = jsonURL
            }

            // Convert to ArticleJSON model
            guard let articleJSON = syncProcessArticleJSON(enrichedJson) else {
                logger.error("Failed to process article JSON: \(articleIdString)")
                throw DatabaseError.transactionError("Failed to process article JSON")
            }

            // Double-check for duplicates after parsing
            if let articleId = articleId, await articleExists(id: articleId) {
                logger.debug("Article already exists (checked after parsing): \(articleIdString)")
                return true
            }

            // Save the article
            let _ = try await saveArticle(articleJSON)

            // Update badge count (debounced in NotificationUtils)
            await MainActor.run {
                NotificationUtils.updateAppBadgeCount()
            }

            return true
        } catch let error as DatabaseError where error == .duplicateArticle {
            // This is not a failure, the article already exists
            logger.debug("Skipped duplicate article: \(articleIdString)")
            return true
        } catch let urlError as URLError {
            // Handle network errors specifically
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                logger.error("Network connectivity issue fetching article: \(articleIdString)")
            case .timedOut:
                logger.error("Request timed out fetching article: \(articleIdString)")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                logger.error("Host connection error fetching article: \(articleIdString)")
            default:
                logger.error("URL error fetching article \(articleIdString): \(urlError.localizedDescription)")
            }
            return false
        } catch {
            logger.error("Error processing article \(articleIdString): \(error.localizedDescription)")
            return false
        }
    }

    /// Extract article ID from a JSON URL
    /// - Parameter jsonURL: The JSON URL
    /// - Returns: UUID if extractable, nil otherwise
    private func extractArticleIDFromURL(_ jsonURL: String) -> UUID? {
        let fileName = jsonURL.split(separator: "/").last ?? ""
        if let uuidRange = fileName.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) {
            let uuidString = String(fileName[uuidRange])
            return UUID(uuidString: uuidString)
        }
        return nil
    }

    /// Process multiple articles in parallel
    /// - Parameter jsonURLs: Array of JSON URLs to process
    /// - Returns: Success, failure, and skipped counts
    func processArticles(jsonURLs: [String]) async -> (success: Int, failure: Int, skipped: Int) {
        guard !jsonURLs.isEmpty else { return (0, 0, 0) }

        var successCount = 0
        var failureCount = 0
        var skippedCount = 0

        // Check for existing articles first
        let existingURLs = await findExistingArticles(jsonURLs: jsonURLs)

        // Filter out URLs that already exist
        let urlsToProcess = jsonURLs.filter { !existingURLs.keys.contains($0) }

        if urlsToProcess.count < jsonURLs.count {
            skippedCount = jsonURLs.count - urlsToProcess.count
            logger.debug("Skipping \(skippedCount) articles that already exist")
        }

        // Process remaining articles with controlled concurrency
        let processingResults = await withTaskGroup(of: Bool.self, returning: (success: Int, failure: Int).self) { group in
            // Limit concurrency to prevent overwhelming the system
            let concurrencyLimit = 5
            var activeCount = 0
            var localSuccessCount = 0
            var localFailureCount = 0

            for jsonURL in urlsToProcess {
                if activeCount >= concurrencyLimit {
                    // Wait for a task to complete before adding more
                    if await group.next() == true {
                        localSuccessCount += 1
                    } else {
                        localFailureCount += 1
                    }
                    activeCount -= 1
                }

                group.addTask {
                    await self.processArticle(jsonURL: jsonURL)
                }
                activeCount += 1
            }

            // Wait for remaining tasks to complete
            for await result in group {
                if result {
                    localSuccessCount += 1
                } else {
                    localFailureCount += 1
                }
            }

            return (localSuccessCount, localFailureCount)
        }

        // Update our counters with the results
        successCount = processingResults.success
        failureCount = processingResults.failure

        // Create local copies for the notification to avoid concurrent access issues
        let finalSuccessCount = successCount
        let finalFailureCount = failureCount
        let finalSkippedCount = skippedCount

        // Post notification that processing is complete
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name.articleProcessingCompleted,
                object: nil,
                userInfo: [
                    "successCount": finalSuccessCount,
                    "failureCount": finalFailureCount,
                    "skippedCount": finalSkippedCount,
                ]
            )
        }

        return (successCount, failureCount, skippedCount)
    }
}
