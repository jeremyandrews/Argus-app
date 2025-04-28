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
    func findArticle(by id: UUID) async -> ArticleModel? {
        try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    article.id.uuidString == id.uuidString
                }
            )

            return try context.fetch(descriptor).first
        }
    }

    /// Find an article by its JSON URL
    /// - Parameter jsonURL: The JSON URL of the article
    /// - Returns: The article if found, nil otherwise
    func findArticle(by jsonURL: String) async -> ArticleModel? {
        try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    article.jsonURL == jsonURL
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
    func findArticle(jsonURL: String, id: UUID? = nil, articleURL: String? = nil) async -> ArticleModel? {
        try? await performTransaction { _, context in
            // First priority - check by ID if provided
            if let id = id {
                let idDescriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.id.uuidString == id.uuidString
                    }
                )

                if let article = try context.fetch(idDescriptor).first {
                    self.logger.debug("Article found by ID: \(id)")
                    return article
                }
            }

            // Second priority - check by jsonURL
            if !jsonURL.isEmpty {
                let urlDescriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.jsonURL == jsonURL
                    }
                )

                if let article = try context.fetch(urlDescriptor).first {
                    self.logger.debug("Article found by jsonURL: \(jsonURL)")
                    return article
                }
            }

            // Last priority - check by article URL
            if let articleURL = articleURL, !articleURL.isEmpty {
                let articleURLDescriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.url == articleURL
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
            var descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    article.id.uuidString == id.uuidString
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
            var descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    article.jsonURL == jsonURL
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
                var descriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.id.uuidString == id.uuidString
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
                var descriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.jsonURL == jsonURL
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
                var descriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { article in
                        article.url == articleURL
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
    func findExistingArticles(ids: [UUID]) async -> [UUID: ArticleModel] {
        guard !ids.isEmpty else { return [:] }

        // Use a transaction to avoid Sendable issues with PersistentModel
        if let results = try? await performTransaction("findExistingArticles", { _, context -> [UUID: ArticleModel] in
            // Create a dictionary to store results
            var results = [UUID: ArticleModel]()

            // Process IDs in batches for better performance
            for idBatch in ids.chunked(into: 25) {
                // Build OR predicates for each ID
                var orPredicates: [Predicate<ArticleModel>] = []

                for id in idBatch {
                    orPredicates.append(#Predicate<ArticleModel> { article in
                        article.id.uuidString == id.uuidString
                    })
                }

                // Combine predicates with OR
                let combinedPredicate = orPredicates.reduce(Predicate<ArticleModel>.false) { result, predicate in
                    #Predicate<ArticleModel> { article in
                        result.evaluate(article) || predicate.evaluate(article)
                    }
                }

                // Fetch matching articles
                let descriptor = FetchDescriptor<ArticleModel>(predicate: combinedPredicate)
                let articles = try context.fetch(descriptor)

                // Add articles to results dictionary
                for article in articles {
                    results[article.id] = article
                }
            }

            return results
        }) {
            return results
        } else {
            return [:]
        }
    }

    /// Find existing articles in a batch by JSON URLs
    /// - Parameter jsonURLs: Array of JSON URLs to check
    /// - Returns: Dictionary mapping JSON URLs to found articles
    func findExistingArticles(jsonURLs: [String]) async -> [String: ArticleModel] {
        guard !jsonURLs.isEmpty else { return [:] }

        // Use a transaction that returns the result dictionary to avoid Swift 6 concurrency errors
        let results = try? await performTransaction { _, context in
            // Create a local dictionary inside the transaction
            var localResults = [String: ArticleModel]()

            // We need to use a different approach that works with Swift 6
            // Process URLs in batches of 25 for more efficient queries
            for urlBatch in jsonURLs.chunked(into: 25) {
                // Instead of using a predicate with contains, we'll use OR conditions
                var orPredicates: [Predicate<ArticleModel>] = []

                for url in urlBatch {
                    orPredicates.append(#Predicate<ArticleModel> { article in
                        article.jsonURL == url
                    })
                }

                // Combine the predicates with OR
                let combinedPredicate = orPredicates.reduce(Predicate<ArticleModel>.false) { result, predicate in
                    #Predicate<ArticleModel> { article in
                        result.evaluate(article) || predicate.evaluate(article)
                    }
                }

                let descriptor = FetchDescriptor<ArticleModel>(predicate: combinedPredicate)
                let articles = try context.fetch(descriptor)

                // Populate the local dictionary
                for article in articles {
                    localResults[article.jsonURL] = article
                }
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
                for urlBatch in urlsToCheck.chunked(into: 25) {
                    // We need to use OR conditions instead of contains for Swift 6 compatibility
                    var orPredicates: [Predicate<ArticleModel>] = []

                    for url in urlBatch {
                        orPredicates.append(#Predicate<ArticleModel> { article in
                            article.jsonURL == url
                        })
                    }

                    // Combine the predicates with OR
                    let combinedPredicate = orPredicates.reduce(Predicate<ArticleModel>.false) { result, predicate in
                        #Predicate<ArticleModel> { article in
                            result.evaluate(article) || predicate.evaluate(article)
                        }
                    }

                    var urlDescriptor = FetchDescriptor<ArticleModel>(predicate: combinedPredicate)

                    // Only fetch the specific properties we need
                    urlDescriptor.propertiesToFetch = [\.id, \.jsonURL]

                    let articles = try context.fetch(urlDescriptor)
                    for article in articles {
                        existingURLs.insert(article.jsonURL)
                        existingIDs.insert(article.id)
                    }

                    // Also check SeenArticle table with the same approach
                    var seenOrPredicates: [Predicate<SeenArticle>] = []

                    for url in urlBatch {
                        seenOrPredicates.append(#Predicate<SeenArticle> { seen in
                            seen.jsonURL == url
                        })
                    }

                    // Combine the predicates with OR
                    let seenCombinedPredicate = seenOrPredicates.reduce(Predicate<SeenArticle>.false) { result, predicate in
                        #Predicate<SeenArticle> { seen in
                            result.evaluate(seen) || predicate.evaluate(seen)
                        }
                    }

                    var seenDescriptor = FetchDescriptor<SeenArticle>(predicate: seenCombinedPredicate)
                    seenDescriptor.propertiesToFetch = [\.id, \.jsonURL]

                    let seenArticles = try context.fetch(seenDescriptor)
                    for seen in seenArticles {
                        existingURLs.insert(seen.jsonURL)
                        existingIDs.insert(seen.id)
                    }
                }
            }

            // Process IDs in batches if provided
            if !idsToCheck.isEmpty {
                for idBatch in idsToCheck.chunked(into: 25) {
                    // Use OR conditions for ID comparison to work with Swift 6
                    var idOrPredicates: [Predicate<ArticleModel>] = []

                    for id in idBatch {
                        idOrPredicates.append(#Predicate<ArticleModel> { article in
                            article.id.uuidString == id.uuidString
                        })
                    }

                    // Combine the predicates with OR
                    let combinedIdPredicate = idOrPredicates.reduce(Predicate<ArticleModel>.false) { result, predicate in
                        #Predicate<ArticleModel> { article in
                            result.evaluate(article) || predicate.evaluate(article)
                        }
                    }

                    var idDescriptor = FetchDescriptor<ArticleModel>(predicate: combinedIdPredicate)
                    idDescriptor.propertiesToFetch = [\.id, \.jsonURL]

                    let articles = try context.fetch(idDescriptor)
                    for article in articles {
                        existingIDs.insert(article.id)
                        existingURLs.insert(article.jsonURL)
                    }

                    // Also check SeenArticle table with same approach
                    var seenIdOrPredicates: [Predicate<SeenArticle>] = []

                    for id in idBatch {
                        seenIdOrPredicates.append(#Predicate<SeenArticle> { seen in
                            seen.id.uuidString == id.uuidString
                        })
                    }

                    // Combine the predicates with OR
                    let seenCombinedIdPredicate = seenIdOrPredicates.reduce(Predicate<SeenArticle>.false) { result, predicate in
                        #Predicate<SeenArticle> { seen in
                            result.evaluate(seen) || predicate.evaluate(seen)
                        }
                    }

                    var seenDescriptor = FetchDescriptor<SeenArticle>(predicate: seenCombinedIdPredicate)
                    seenDescriptor.propertiesToFetch = [\.id, \.jsonURL]

                    let seenArticles = try context.fetch(seenDescriptor)
                    for seen in seenArticles {
                        existingIDs.insert(seen.id)
                        existingURLs.insert(seen.jsonURL)
                    }
                }
            }

            self.logger.debug("Batch check: found \(existingURLs.count) URLs and \(existingIDs.count) IDs (including \(cachedURLsCopy.count) cached URLs)")

            return (existingURLs, existingIDs)
        }) ?? (cachedURLs, cachedIDs)
    }

    /// Save an article to the database
    /// - Parameter articleJSON: The article data to save
    /// - Returns: The saved ArticleModel object
    func saveArticle(_ articleJSON: ArticleJSON) async throws -> ArticleModel {
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

            // Create an ArticleModel instead of NotificationData
            let article = ArticleModel(
                id: articleID,
                jsonURL: articleJSON.jsonURL,
                url: articleJSON.url,
                title: articleJSON.title,
                body: articleJSON.body,
                domain: articleJSON.domain,
                articleTitle: articleJSON.articleTitle,
                affected: articleJSON.affected,
                publishDate: articleJSON.pubDate ?? date,
                addedDate: date,
                topic: articleJSON.topic,
                isViewed: false,
                isBookmarked: false,
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
                actionRecommendations: articleJSON.actionRecommendations,
                talkingPoints: articleJSON.talkingPoints,
                engineModel: articleJSON.engineModel,
                engineElapsedTime: articleJSON.engineElapsedTime,
                engineRawStats: articleJSON.engineRawStats,
                engineSystemInfo: articleJSON.engineSystemInfo,
                relatedArticles: articleJSON.relatedArticles
            )

            // Create seen article record
            let seenArticle = SeenArticle(
                id: articleID,
                jsonURL: articleJSON.jsonURL,
                date: date
            )

            // Double-check there's no article with this ID
            let finalIDCheck = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { existing in
                    existing.id.uuidString == articleID.uuidString
                }
            )

            // Last-minute duplicate check
            if let existingDuplicate = try? context.fetch(finalIDCheck).first {
                self.logger.debug("Last-minute duplicate detection - updating instead of inserting: \(articleID)")
                await self.updateFields(of: existingDuplicate, with: articleJSON)

                // Only insert the SeenArticle record if it doesn't exist
                let existingSeenCheck = FetchDescriptor<SeenArticle>(
                    predicate: #Predicate<SeenArticle> { seen in
                        seen.id.uuidString == articleID.uuidString
                    }
                )

                if (try? context.fetch(existingSeenCheck).first) == nil {
                    context.insert(seenArticle)
                }

                // Generate rich text synchronously for the duplicate - use ID to avoid capturing non-Sendable model
                let duplicateId = existingDuplicate.id
                // Create descriptor outside the MainActor closure to avoid capturing context
                let descriptor = FetchDescriptor<ArticleModel>(predicate: #Predicate<ArticleModel> { $0.id == duplicateId })
                await MainActor.run {
                    // Get a fresh context on the MainActor to avoid crossing actor boundaries
                    let mainContext = ModelContext(self.container)
                    if let article = try? mainContext.fetch(descriptor).first {
                        _ = getAttributedString(for: .title, from: article, createIfMissing: true)
                        _ = getAttributedString(for: .body, from: article, createIfMissing: true)
                    }
                }

                return existingDuplicate
            } else {
                // Insert both records
                context.insert(article)
                context.insert(seenArticle)

                // Extract the UUID which is Sendable before the closure to avoid capturing the non-Sendable ArticleModel
                let articleIdForClosure = article.id

                // Create descriptor outside the MainActor closure to avoid capturing context
                let descriptor = FetchDescriptor<ArticleModel>(predicate: #Predicate<ArticleModel> { $0.id == articleIdForClosure })

                // Generate rich text attributes synchronously on the main actor
                // This ensures rich text is created before the article is saved
                await MainActor.run {
                    // Get a fresh context on the MainActor to avoid crossing actor boundaries
                    let mainContext = ModelContext(self.container)
                    if let article = try? mainContext.fetch(descriptor).first {
                        _ = getAttributedString(for: .title, from: article, createIfMissing: true)
                        _ = getAttributedString(for: .body, from: article, createIfMissing: true)
                    }
                }

                return article
            }
        }
    }

    /// Update an existing article with new data
    /// - Parameters:
    ///   - article: The article to update
    ///   - data: The new data to apply
    /// - Returns: The updated article
    func updateArticle(_ article: ArticleModel, with data: ArticleJSON) async throws -> ArticleModel {
        // Extract the ID before the transaction to avoid capturing the non-Sendable article in a @Sendable closure
        let articleIdForTransaction = article.id

        return try await performTransaction { _, context in
            // Use the extracted ID (which is Sendable) within the transaction
            let fetchDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { notificationArticle in
                    notificationArticle.id.uuidString == articleIdForTransaction.uuidString
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
                    seen.id.uuidString == freshArticleId.uuidString
                }
            )

            if (try? context.fetch(seenCheckDescriptor).first) == nil {
                let seenArticle = SeenArticle(
                    id: freshArticle.id,
                    jsonURL: freshArticle.jsonURL, // Using ArticleModel's property name
                    date: Date()
                )
                context.insert(seenArticle)
            }

            // Generate rich text attributes synchronously on the main actor - use ID to avoid capturing non-Sendable model
            // This ensures rich text is created before the transaction completes
            // We reuse the freshArticleId that was already defined earlier
            // Create descriptor outside the MainActor closure to avoid capturing context
            let descriptor = FetchDescriptor<ArticleModel>(predicate: #Predicate<ArticleModel> { $0.id == freshArticleId })
            await MainActor.run {
                // Get a fresh context on the MainActor to avoid crossing actor boundaries
                let mainContext = ModelContext(self.container)
                if let article = try? mainContext.fetch(descriptor).first {
                    _ = getAttributedString(for: .title, from: article, createIfMissing: true)
                    _ = getAttributedString(for: .body, from: article, createIfMissing: true)
                }
            }

            return freshArticle
        }
    }

    /// Helper method to update the fields of an article
    /// - Parameters:
    ///   - article: The article to update
    ///   - data: The new data to apply
    private func updateFields(of article: ArticleModel, with data: ArticleJSON) async {
        // Update article fields
        article.title = data.title
        article.body = data.body
        article.jsonURL = data.jsonURL
        article.url = data.url
        article.topic = data.topic
        article.articleTitle = data.articleTitle
        article.affected = data.affected
        article.domain = data.domain
        
        // Update database ID
        article.databaseId = data.databaseId

        // Only update the pubDate if the new one has a value
        if let pubDate = data.pubDate {
            article.publishDate = pubDate
        }

        // Don't override user-specific flags
        // article.isViewed remains unchanged
        // article.isBookmarked remains unchanged

        // Update quality indicators
        article.sourcesQuality = data.sourcesQuality
        article.argumentQuality = data.argumentQuality
        article.sourceType = data.sourceType
        article.sourceAnalysis = data.sourceAnalysis
        article.quality = data.quality

        // Update content analysis
        article.summary = data.summary
        article.criticalAnalysis = data.criticalAnalysis
        article.logicalFallacies = data.logicalFallacies
        article.relationToTopic = data.relationToTopic
        article.additionalInsights = data.additionalInsights
        article.actionRecommendations = data.actionRecommendations
        article.talkingPoints = data.talkingPoints

        // Update metadata - use the individual engine fields
        article.engineModel = data.engineModel
        article.engineElapsedTime = data.engineElapsedTime
        article.engineRawStats = data.engineRawStats
        // Handle system info serialization
        if let sysInfo = data.engineSystemInfo {
            article.engineSystemInfoData = try? JSONSerialization.data(withJSONObject: sysInfo)
        }
        article.relatedArticles = data.relatedArticles
    }

    /// Helper method to update the fields of a NotificationData article
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
        
        // Update database ID if available in NotificationData model
        // Note: This is done with reflection since NotificationData may not have this field
        // in older versions of the app
        if let setter = Mirror(reflecting: article).children.first(where: { $0.label == "setDatabaseId" }) {
            // If setter exists, use it
            if let setterFunc = setter.value as? (Int?) -> Void {
                setterFunc(data.databaseId)
            }
        }

        // Only update the pubDate if the new one has a value
        if let pubDate = data.pubDate {
            article.pub_date = pubDate
        }

        // Don't override user-specific flags
        // article.isViewed remains unchanged
        // article.isBookmarked remains unchanged

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

        // Update metadata - Build engine_stats from individual fields
        if let model = data.engineModel, 
           let elapsedTime = data.engineElapsedTime,
           let stats = data.engineRawStats {
            // Create engine stats dictionary as a var since we modify it
            var engineStatsDict: [String: Any] = [
                "model": model,
                "elapsed_time": elapsedTime,
                "stats": stats
            ]
            
            // Add database ID if available
            if let dbId = data.databaseId {
                engineStatsDict["id"] = dbId
            }
            
            // Add system info if available
            if let systemInfo = data.engineSystemInfo {
                engineStatsDict["system_info"] = systemInfo
            }
            
            // Serialize to JSON string
            if let engineStatsData = try? JSONSerialization.data(withJSONObject: engineStatsDict),
               let engineStatsString = String(data: engineStatsData, encoding: .utf8) {
                article.engine_stats = engineStatsString
            }
        }
        
        // Convert RelatedArticles to JSON string if needed
        if let relatedArticles = data.relatedArticles {
            do {
                let jsonData = try JSONEncoder().encode(relatedArticles)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    article.similar_articles = jsonString
                }
            } catch {
                self.logger.error("Failed to encode relatedArticles to JSON: \(error)")
            }
        } else {
            article.similar_articles = nil
        }
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
    ) async -> [ArticleModel] {
        // Use a transaction that returns the result array directly
        let results = try? await performTransaction { _, context in
            // Build an optimized predicate based on filter combination
            var predicate: Predicate<ArticleModel>?

            // 1. Apply topic filter if not "All"
            if topic != "All" {
                predicate = #Predicate<ArticleModel> { article in
                    article.topic == topic
                }
            }

            // 2. Apply unread filter if needed
            if showUnreadOnly {
                let unreadPredicate = #Predicate<ArticleModel> { article in
                    !article.isViewed
                }

                if let existingPredicate = predicate {
                    predicate = #Predicate<ArticleModel> { article in
                        existingPredicate.evaluate(article) && unreadPredicate.evaluate(article)
                    }
                } else {
                    predicate = unreadPredicate
                }
            }

            // 3. Apply bookmarked filter if needed
            if showBookmarkedOnly {
                let bookmarkedPredicate = #Predicate<ArticleModel> { article in
                    article.isBookmarked
                }

                if let existingPredicate = predicate {
                    predicate = #Predicate<ArticleModel> { article in
                        existingPredicate.evaluate(article) && bookmarkedPredicate.evaluate(article)
                    }
                } else {
                    predicate = bookmarkedPredicate
                }
            }

            // Create the fetch descriptor with our optimized predicate
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
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

    /// Fetch just the JSON URLs from recent articles since a specified date
    /// - Parameter date: The date to fetch URLs from
    /// - Returns: Array of JSON URLs (strings, which are Sendable)
    func fetchRecentArticleURLs(since date: Date = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!) async -> [String] {
        // Use a transaction that returns just the URLs to avoid Swift 6 Sendability issues
        let urls = try? await performTransaction { _, context in
            var descriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seenArticle in
                    seenArticle.date >= date
                }
            )

            // Only fetch the JSON URL property to minimize data transfer
            descriptor.propertiesToFetch = [\.jsonURL]

            // Fetch the seen articles and extract just the URLs
            let articles = try context.fetch(descriptor)
            return articles.map { $0.jsonURL }
        }

        return urls ?? []
    }

    /// Fetch articles matching a predicate
    /// - Parameter predicate: The predicate to match
    /// - Returns: Array of matching articles
    func fetchArticles(matching predicate: Predicate<ArticleModel>) async -> [ArticleModel] {
        // Use a transaction that returns the results directly to avoid Swift 6 concurrency errors
        let results = try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<ArticleModel>(predicate: predicate)
            return try context.fetch(descriptor)
        }

        return results ?? []
    }

    /// Count articles matching a predicate
    /// - Parameter predicate: The predicate to match
    /// - Returns: The number of matching articles
    func countArticles(matching predicate: Predicate<ArticleModel>) async -> Int {
        // Use a transaction that returns the count directly to avoid Swift 6 concurrency errors
        let count = try? await performTransaction { _, context in
            let descriptor = FetchDescriptor<ArticleModel>(predicate: predicate)
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
            let articleCount = try context.fetchCount(FetchDescriptor<ArticleModel>())
            localStats["articleCount"] = articleCount

            // Count seen articles
            let seenCount = try context.fetchCount(FetchDescriptor<SeenArticle>())
            localStats["seenCount"] = seenCount

            // Count unread articles
            let unreadDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    !article.isViewed
                }
            )
            let unreadCount = try context.fetchCount(unreadDescriptor)
            localStats["unreadCount"] = unreadCount

            // Count bookmarked articles
            let bookmarkedDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
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
        
        // Extract engine stats fields directly from the JSON
        let engineModel = json["model"] as? String
        let engineElapsedTime = json["elapsed_time"] as? Double
        let engineRawStats = json["stats"] as? String
        let engineSystemInfo = json["system_info"] as? [String: Any]
        
        // Extract the new R2 URL JSON fields
        let actionRecommendations = json["action_recommendations"] as? String
        let talkingPoints = json["talking_points"] as? String
        
        // Extract the database ID with robust type handling
        var databaseId: Int? = nil
        
        // First try as direct Int
        if let intId = json["id"] as? Int {
            databaseId = intId
            logger.debug("✅ DatabaseCoordinator: Extracted database ID as Int: \(intId)")
        } 
        // Then try as String that can be converted to Int
        else if let stringId = json["id"] as? String, let intFromString = Int(stringId) {
            databaseId = intFromString
            logger.debug("✅ DatabaseCoordinator: Extracted database ID from String: \(intFromString)")
        } 
        // Finally try as Double with no fractional part
        else if let doubleId = json["id"] as? Double, doubleId.truncatingRemainder(dividingBy: 1) == 0 {
            databaseId = Int(doubleId)
            logger.debug("✅ DatabaseCoordinator: Extracted database ID from Double: \(Int(doubleId))")
        } 
        // Log if ID exists but couldn't be converted
        else if let rawId = json["id"] {
            let typeString = String(describing: type(of: rawId))
            logger.debug("⚠️ DatabaseCoordinator: ID found but couldn't convert to Int: \(String(describing: rawId)) (Type: \(typeString))")
        }
        
        // Final log to show if we got a database ID
        if let databaseId = databaseId {
            logger.debug("🔑 DatabaseCoordinator: Will use database ID: \(databaseId)")
        } else {
            logger.debug("🚫 DatabaseCoordinator: No database ID found in article JSON")
        }

        // Create the article JSON object
        
        // Extract string ID from available sources for new id parameter
        let stringId: String
        if let idValue = json["id"] {
            // Use string value or convert to string
            if let strValue = idValue as? String {
                stringId = strValue
            } else {
                stringId = String(describing: idValue)
            }
        } else if let fileName = jsonURL.split(separator: "/").last?.split(separator: ".").first {
            // Extract from URL (e.g., "articles/bbc-12345.json" → "bbc-12345")
            stringId = String(fileName)
        } else {
            // Fallback to URL as ID
            stringId = jsonURL
        }
        
        return ArticleJSON(
            id: stringId,  // Add the required id parameter
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
            engineModel: engineModel,
            engineElapsedTime: engineElapsedTime,
            engineRawStats: engineRawStats,
            engineSystemInfo: engineSystemInfo,
            relatedArticles: extractSimilarArticles(from: json),
            actionRecommendations: actionRecommendations,
            talkingPoints: talkingPoints,
            databaseId: databaseId
        )
    }

    // We're moving the domain extraction function directly into this file to avoid cloud build issues
    
    /// Helper function to extract the domain from a URL
    ///
    /// This extracts the domain portion from a URL string by:
    /// 1. Removing the scheme (http://, https://)
    /// 2. Removing any "www." prefix
    /// 3. Keeping only the domain part (removing paths)
    /// 4. Trimming whitespace
    ///
    /// - Parameter urlString: The URL to extract domain from
    /// - Returns: The domain string, or nil if the URL is invalid or malformed
    private func extractDomain(from urlString: String) -> String? {
        // Early check for empty or nil URLs
        guard !urlString.isEmpty else {
            return nil
        }

        // Try the URL-based approach first for properly formatted URLs
        if let url = URL(string: urlString), let host = url.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        // Fallback manual parsing for URLs that might not parse with URL initializer
        var working = urlString.lowercased()

        // Strip scheme
        if working.hasPrefix("http://") {
            working.removeFirst("http://".count)
        } else if working.hasPrefix("https://") {
            working.removeFirst("https://".count)
        }

        // Strip any leading "www."
        if working.hasPrefix("www.") {
            working.removeFirst("www.".count)
        }

        // Now split on first slash to remove any path
        if let slashIndex = working.firstIndex(of: "/") {
            working = String(working[..<slashIndex])
        }

        // Trim whitespace
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return nil if we ended up with an empty string
        return working.isEmpty ? nil : working
    }

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

    // Helper to extract similar articles from JSON and convert to RelatedArticle array
    private func extractSimilarArticles(from json: [String: Any]) -> [RelatedArticle]? {
        guard let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty else {
            return nil
        }

        do {
            // Convert dictionaries to JSON data
            let data = try JSONSerialization.data(withJSONObject: similarArticles)
            
            // Decode to RelatedArticle array
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let relatedArticles = try decoder.decode([RelatedArticle].self, from: data)
            if !relatedArticles.isEmpty {
                return relatedArticles
            }
        } catch {
            self.logger.error("Failed to decode similar articles: \(error)")
        }
        
        return nil
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
