import Foundation
import SwiftData
import SwiftUI

/// Implementation of the ArticleServiceProtocol that provides CRUD operations and sync functionality
/// Thread safety: This class uses a serial dispatch queue for all cache operations. All methods
/// that read or modify the cache state are properly synchronized.
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

    // Serial queue for thread-safe cache operations
    private let cacheQueue = DispatchQueue(label: "com.argus.articleservice.cache")

    // Active tasks tracking
    private var activeSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    init(apiClient: APIClient = APIClient.shared, modelContainer: ModelContainer? = nil) {
        self.apiClient = apiClient

        // Use the provided container or get the SwiftDataContainer
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
    ) async throws -> [ArticleModel] {
        // Check cache first for common queries
        let cacheKey = createCacheKey(topic: topic, isRead: isRead, isBookmarked: isBookmarked, isArchived: isArchived)

        if let cachedResults = checkCache(for: cacheKey) {
            return cachedResults
        }

        // Build the predicate - we need to use ArticleModel predicates now
        var predicate: Predicate<ArticleModel>?

        // Topic predicate (most selective, so apply first)
        if let topic = topic, topic != "All" {
            predicate = #Predicate<ArticleModel> { $0.topic == topic }
        }

        // Read status predicate
        if let isRead = isRead {
            let readPredicate = #Predicate<ArticleModel> { $0.isViewed == isRead }
            if let existingPredicate = predicate {
                predicate = #Predicate<ArticleModel> { existingPredicate.evaluate($0) && readPredicate.evaluate($0) }
            } else {
                predicate = readPredicate
            }
        }

        // Bookmarked status predicate
        if let isBookmarked = isBookmarked {
            let bookmarkPredicate = #Predicate<ArticleModel> { $0.isBookmarked == isBookmarked }
            if let existingPredicate = predicate {
                predicate = #Predicate<ArticleModel> { existingPredicate.evaluate($0) && bookmarkPredicate.evaluate($0) }
            } else {
                predicate = bookmarkPredicate
            }
        }

        // Archive functionality removed
        // Since isArchived property no longer exists in ArticleModel, we don't need to filter on it
        // We kept the parameter in the API for backward compatibility

        // Create fetch descriptor for ArticleModel
        var fetchDescriptor = FetchDescriptor<ArticleModel>(predicate: predicate)

        // Apply sorting - default to newest first (use publishDate instead of pub_date)
        fetchDescriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]

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
            let articleModels = try context.fetch(fetchDescriptor)

            // Cache the results directly without conversion
            cacheResults(articleModels, for: cacheKey)

            return articleModels
        } catch {
            AppLogger.database.error("Error fetching articles: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func fetchArticle(byId id: UUID) async throws -> ArticleModel? {
        let fetchDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.id == id }
        )

        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)

            if let articleModel = results.first {
                // Log diagnostics info for debugging
                let hasEngineStats = articleModel.engineStats != nil
                let hasSimilarArticles = articleModel.similarArticles != nil
                let hasTitleBlob = articleModel.titleBlob != nil
                let hasBodyBlob = articleModel.bodyBlob != nil
                let hasSummaryBlob = articleModel.summaryBlob != nil

                AppLogger.database.debug("""
                Fetched ArticleModel \(articleModel.id):
                - Has engine stats: \(hasEngineStats)
                - Has similar articles: \(hasSimilarArticles)
                - Has title blob: \(hasTitleBlob)
                - Has body blob: \(hasBodyBlob)
                - Has summary blob: \(hasSummaryBlob)
                """)

                return articleModel
            }
            return nil
        } catch {
            AppLogger.database.error("Error fetching article by ID: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func fetchArticle(byJsonURL jsonURL: String) async throws -> ArticleModel? {
        let fetchDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.jsonURL == jsonURL }
        )

        do {
            let context = ModelContext(modelContainer)
            let results = try context.fetch(fetchDescriptor)

            if let articleModel = results.first {
                AppLogger.database.debug("Fetched ArticleModel with jsonURL: \(jsonURL)")
                return articleModel
            }
            return nil
        } catch {
            AppLogger.database.error("Error fetching article by JSON URL: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    func searchArticles(queryText: String, limit: Int?) async throws -> [ArticleModel] {
        guard !queryText.isEmpty else {
            return []
        }

        // Build the search predicate - search title and body
        let searchPredicate = #Predicate<ArticleModel> {
            $0.title.localizedStandardContains(queryText) ||
                $0.body.localizedStandardContains(queryText)
        }

        var fetchDescriptor = FetchDescriptor<ArticleModel>(predicate: searchPredicate)

        // Apply limit if specified
        if let limit = limit {
            fetchDescriptor.fetchLimit = limit
        }

        // Sort by relevance (approximated by date for now)
        fetchDescriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]

        do {
            let context = ModelContext(modelContainer)
            let articleModels = try context.fetch(fetchDescriptor)
            
            AppLogger.database.debug("Found \(articleModels.count) articles matching search: \(queryText)")
            return articleModels
        } catch {
            AppLogger.database.error("Error searching articles: \(error)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    // MARK: - State Management Operations

    func markArticle(id: UUID, asRead isRead: Bool) async throws {
        // Find the ArticleModel by ID
        let fetchDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.id == id }
        )

        do {
            let context = ModelContext(modelContainer)
            let articleModels = try context.fetch(fetchDescriptor)

            guard let articleInContext = articleModels.first else {
                throw ArticleServiceError.articleNotFound
            }

            // Only proceed if the state is actually changing
            if articleInContext.isViewed == isRead {
                return
            }

            // Update the property
            articleInContext.isViewed = isRead

            // Save the changes
            try context.save()

            // Clear cache safely since article state has changed
            await withCheckedContinuation { continuation in
                clearCache() // This now runs on cacheQueue
                continuation.resume()
            }

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
        // Find the ArticleModel by ID
        let fetchDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.id == id }
        )

        do {
            let context = ModelContext(modelContainer)
            let articleModels = try context.fetch(fetchDescriptor)

            guard let articleInContext = articleModels.first else {
                throw ArticleServiceError.articleNotFound
            }

            // Only proceed if the state is actually changing
            if articleInContext.isBookmarked == isBookmarked {
                return
            }

            // Update the property
            articleInContext.isBookmarked = isBookmarked

            // Save the changes
            try context.save()

            // Clear cache safely since article state has changed
            await withCheckedContinuation { continuation in
                clearCache() // This now runs on cacheQueue
                continuation.resume()
            }

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

    // Archive functionality removed

    func deleteArticle(id: UUID) async throws {
        do {
            let context = ModelContext(modelContainer)

            // Re-fetch in this context
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate { $0.id == id }
            )

            guard let articleInContext = try context.fetch(descriptor).first else {
                throw ArticleServiceError.articleNotFound
            }

            // Save the JSON URL for notification removal
            let jsonURL = articleInContext.jsonURL

            // Delete the article
            context.delete(articleInContext)

            // Save the changes
            try context.save()

            // Clear cache safely since articles have changed
            await withCheckedContinuation { continuation in
                clearCache() // This now runs on cacheQueue
                continuation.resume()
            }

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

    /// Process a collection of articles fetched from the remote server
    /// - Parameters:
    ///   - articles: Array of ArticleJSON objects to process
    ///   - progressHandler: Optional handler for progress updates (current, total)
    /// - Returns: Number of new articles added to the database
    func processArticleData(_ articles: [ArticleJSON], progressHandler: ((Int, Int) -> Void)? = nil) async throws -> Int {
        return try await processRemoteArticles(articles, progressHandler: progressHandler)
    }

    func syncArticlesFromServer(topic: String?, limit _: Int?, progressHandler: ((Int, Int) -> Void)? = nil) async throws -> Int {
        do {
            // Signal that we're searching for articles
            progressHandler?(0, 0)
            
            // Fetch articles from server with default limits
            // Note: The API sends all unseen articles, so we'll handle limiting after fetch
            let remoteArticles = try await apiClient.fetchArticles(
                topic: topic,
                progressHandler: progressHandler
            )

            // Process the articles with progress updates
            return try await processRemoteArticles(remoteArticles, progressHandler: progressHandler)

        } catch {
            AppLogger.sync.error("Error syncing articles from server: \(error)")
            throw ArticleServiceError.networkError(underlyingError: error)
        }
    }

    func performBackgroundSync(progressHandler: ((Int, Int) -> Void)? = nil) async throws -> SyncResultSummary {
        // Cancel any existing task
        activeSyncTask?.cancel()

        // Start timing
        let startTime = Date()
        var addedCount = 0
        let updatedCount = 0
        let deletedCount = 0
        
        // Initial progress - searching
        progressHandler?(0, 0)

        // Create a new task for syncing
        do {
            // Fetch subscribed topics
            let subscriptions = await SubscriptionsView().loadSubscriptions()
            let subscribedTopics = subscriptions.filter { $0.value.isSubscribed }.keys
            
            // Create a progress tracker across all topics
            var currentProgress = 0
            let totalTopics = 1 + subscribedTopics.count // "All" + subscribed topics
            var topicProgress: ((Int, Int) -> Void)? = nil
            
            if let progressHandler = progressHandler {
                topicProgress = { current, total in
                    if total > 0 {
                        // Map the progress of this topic to the overall progress
                        let topicWeight = 1.0 / Double(totalTopics)
                        let topicCompletion = Double(current) / Double(total)
                        let overallProgress = Int(Double(currentProgress) + topicCompletion * 100.0 * topicWeight)
                        progressHandler(overallProgress, 100)
                    } else {
                        // Just pass the searching state
                        progressHandler(0, 0)
                    }
                }
            }

            // Start with "All" topics sync (limited count)
            addedCount += try await syncArticlesFromServer(topic: nil, limit: 30, progressHandler: topicProgress)
            currentProgress += 100 / totalTopics

            // Sync each subscribed topic
            for (index, topic) in subscribedTopics.enumerated() {
                // Check for cancellation before each topic
                try Task.checkCancellation()

                // Sync this topic (limited count)
                addedCount += try await syncArticlesFromServer(topic: topic, limit: 20, progressHandler: topicProgress)
                currentProgress = ((index + 1) * 100) / totalTopics
            }

            // Update last sync time
            UserDefaults.standard.set(Date(), forKey: "lastSyncTime")

            // Calculate duration
            let duration = Date().timeIntervalSince(startTime)

            // Clear cache safely as we have new data
            await withCheckedContinuation { continuation in
                clearCache() // This now runs on cacheQueue
                continuation.resume()
            }

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

    // MARK: - Background Maintenance Operations

    /// Performs a quick maintenance operation suitable for BGAppRefreshTask
    /// - Parameter timeLimit: Maximum time in seconds to spend on maintenance
    func performQuickMaintenance(timeLimit: TimeInterval) async throws {
        // Start timing
        let startTime = Date()

        // Create a task that can be cancelled when time limit is reached
        return try await withThrowingTaskGroup(of: Void.self) { group in
            // Add the maintenance task
            group.addTask {
                // Fetch only the most recent articles (limit count)
                let articlesAdded = try await self.syncArticlesFromServer(topic: nil, limit: 10)

                // Log the result
                AppLogger.sync.debug("Quick maintenance added \(articlesAdded) new articles")

                // Skip topic-specific sync in quick maintenance
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeLimit * 1_000_000_000))
                // When timeout occurs, just exit without error
                // The task group will complete when this task finishes
            }

            // Wait for either task to complete
            try await group.next()

            // Cancel any remaining tasks
            group.cancelAll()

            // Log duration
            let duration = Date().timeIntervalSince(startTime)
            AppLogger.sync.debug("Quick maintenance completed in \(String(format: "%.2f", duration))s")
        }
    }

    // MARK: - Rich Text Operations

    /// Generates initial rich text content for a new article
    /// This must run on the main actor to properly handle NSAttributedString
    @MainActor
    private func generateInitialRichText(for article: ArticleModel) {
        // Generate the basic rich text for immediate display directly on ArticleModel
        AppLogger.database.debug("Generating initial rich text for article \(article.id)")
        
        // Generate for title
        if article.titleBlob == nil || article.titleBlob?.isEmpty == true {
            let titleText = article.title
            if !titleText.isEmpty {
                if let attributedString = markdownToAttributedString(titleText, textStyle: RichTextField.title.textStyle) {
                    AppLogger.database.debug("✅ Generated title rich text")
                    
                    // Archive to data
                    do {
                        let blobData = try NSKeyedArchiver.archivedData(
                            withRootObject: attributedString,
                            requiringSecureCoding: false
                        )
                        
                        // Set the blob directly on ArticleModel
                        article.titleBlob = blobData
                    } catch {
                        AppLogger.database.error("❌ Failed to create title blob: \(error)")
                    }
                }
            }
        }
        
        // Generate for body
        if article.bodyBlob == nil || article.bodyBlob?.isEmpty == true {
            let bodyText = article.body
            if !bodyText.isEmpty {
                if let attributedString = markdownToAttributedString(bodyText, textStyle: RichTextField.body.textStyle) {
                    AppLogger.database.debug("✅ Generated body rich text")
                    
                    // Archive to data
                    do {
                        let blobData = try NSKeyedArchiver.archivedData(
                            withRootObject: attributedString,
                            requiringSecureCoding: false
                        )
                        
                        // Set the blob directly on ArticleModel
                        article.bodyBlob = blobData
                    } catch {
                        AppLogger.database.error("❌ Failed to create body blob: \(error)")
                    }
                }
            }
        }
    }

    /// Diagnoses and repairs rich text blob issues in articles
    /// - Parameters:
    ///   - articleId: Optional article ID to diagnose a specific article, or nil for all articles
    ///   - forceRegenerate: Whether to force regeneration of all blobs, even if they seem valid
    ///   - limit: Optional limit on the number of articles to process
    /// - Returns: A summary of diagnostics and repairs performed
    @MainActor
    func diagnoseAndRepairRichTextBlobs(
        articleId: UUID? = nil,
        forceRegenerate: Bool = false,
        limit: Int? = nil
    ) async throws -> (diagnosed: Int, repaired: Int, details: String) {
        // Log start of operation
        AppLogger.database.debug("🔍 Starting rich text blob diagnosis\(articleId != nil ? " for article \(articleId!)" : " for all articles")")

        // Create fetch descriptor for ArticleModel
        var fetchDescriptor: FetchDescriptor<ArticleModel>

        if let id = articleId {
            // Fetch specific article
            fetchDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { $0.id == id }
            )
        } else {
            // Fetch all articles, optionally limited
            fetchDescriptor = FetchDescriptor<ArticleModel>()

            if let limit = limit {
                fetchDescriptor.fetchLimit = limit
            }

            // Sort by date for consistent results
            fetchDescriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]
        }

        // Execute the fetch
        let context = ModelContext(modelContainer)
        let articleModels = try context.fetch(fetchDescriptor)

        if articleModels.isEmpty {
            AppLogger.database.debug("❌ No articles found to diagnose")
            return (0, 0, "No articles found to diagnose")
        }

        AppLogger.database.debug("📊 Found \(articleModels.count) articles to diagnose")

        // Track statistics
        var diagnosedCount = 0
        var repairedCount = 0
        var detailsLog = ""

        // Process each article
        for articleModel in articleModels {
            diagnosedCount += 1
            
            // Add to details log
            detailsLog += "Article \(articleModel.id): "
            
            // Directly check if blobs exist and are valid
            let verificationResults = verifyArticleBlobs(articleModel)
            let allBlobsValid = verificationResults.allValid
            let missingBlobs = verificationResults.missingFields

            if !allBlobsValid || forceRegenerate {
                // Regenerate blobs if needed or forced
                if !allBlobsValid {
                    detailsLog += "Found \(missingBlobs.count) invalid/missing blobs: \(missingBlobs.joined(separator: ", ")). "
                } else {
                    detailsLog += "Force regenerating blobs. "
                }

                // Regenerate each field that needs it
                var regeneratedCount = 0
                
                for field in RichTextField.allCases {
                    if !verificationResults.validFields.contains(field.rawValue) || forceRegenerate {
                        if regenerateRichTextForField(field, on: articleModel) {
                            regeneratedCount += 1
                        }
                    }
                }

                if regeneratedCount > 0 {
                    repairedCount += 1
                    detailsLog += "Regenerated \(regeneratedCount) blobs.\n"
                    
                    // Save the changes
                    try context.save()
                } else {
                    detailsLog += "No blobs needed regeneration.\n"
                }
            } else {
                detailsLog += "All blobs valid. No action needed.\n"
            }
        }

        // Log completion
        AppLogger.database.debug("✅ Blob diagnosis complete: \(diagnosedCount) articles diagnosed, \(repairedCount) articles repaired")

        return (diagnosedCount, repairedCount, detailsLog)
    }
    
    /// Verifies all blobs in an ArticleModel
    /// - Parameter article: The article to verify
    /// - Returns: A tuple containing validation results and missing fields
    private func verifyArticleBlobs(_ article: ArticleModel) -> (allValid: Bool, validFields: Set<String>, missingFields: [String]) {
        var validFields = Set<String>()
        var missingFields = [String]()
        
        // Check each field
        for field in RichTextField.allCases {
            let blobData = field.getBlob(from: article)
            
            // A field is valid if it has blob data and it can be unarchived
            if let data = blobData, !data.isEmpty {
                do {
                    if try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) != nil {
                        validFields.insert(field.rawValue)
                        continue
                    }
                } catch {
                    // Failed to unarchive
                }
            }
            
            // If we get here, the field is invalid or missing
            missingFields.append(field.rawValue)
        }
        
        return (missingFields.isEmpty, validFields, missingFields)
    }
    
    /// Regenerates rich text for a specific field on an ArticleModel
    /// - Parameters:
    ///   - field: The field to regenerate
    ///   - article: The article model
    /// - Returns: True if successful, false otherwise
    private func regenerateRichTextForField(_ field: RichTextField, on article: ArticleModel) -> Bool {
        // Get the text for this field
        let text: String?
        switch field {
        case .title:
            text = article.title
        case .body:
            text = article.body
        case .summary:
            text = article.summary
        case .criticalAnalysis:
            text = article.criticalAnalysis
        case .sourceAnalysis:
            text = article.sourceAnalysis
        case .logicalFallacies:
            text = article.logicalFallacies
        case .relationToTopic:
            text = article.relationToTopic
        case .additionalInsights:
            text = article.additionalInsights
        }
        
        // Skip if no text
        guard let unwrappedText = text, !unwrappedText.isEmpty else {
            return false
        }
        
        // Generate attributed string
        guard let attributedString = markdownToAttributedString(unwrappedText, textStyle: field.textStyle) else {
            return false
        }
        
        // Archive and save
        do {
            let blobData = try NSKeyedArchiver.archivedData(
                withRootObject: attributedString,
                requiringSecureCoding: false
            )
            
            // Set the blob on the article model
            field.setBlob(blobData, on: article)
            return true
        } catch {
            AppLogger.database.error("Failed to save blob for \(String(describing: field)): \(error)")
            return false
        }
    }

    /// Generates rich text content for a specific field of an article
    /// This entire method runs on the main actor to properly handle NSAttributedString
    @MainActor
    func generateRichTextContent(
        for articleId: UUID,
        field: RichTextField
    ) async throws -> NSAttributedString? {
        do {
            // Fetch the ArticleModel
            let fetchDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { $0.id == articleId }
            )

            let context = ModelContext(modelContainer)
            let articleModels = try context.fetch(fetchDescriptor)

            guard let articleModel = articleModels.first else {
                AppLogger.database.error("Article not found with ID: \(articleId)")
                return nil
            }
            
            AppLogger.database.debug("Generating rich text content for field: \(String(describing: field)) on article \(articleId)")

            // First try to get from existing blob
            if let blobData = field.getBlob(from: articleModel), !blobData.isEmpty {
                do {
                    if let attributedString = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: blobData
                    ) {
                        AppLogger.database.debug("✅ Retrieved existing blob for \(String(describing: field))")
                        return attributedString
                    }
                } catch {
                    AppLogger.database.error("Failed to unarchive blob for \(String(describing: field)): \(error)")
                }
            }
            
            // If no blob or failed to load, create fresh
            let markdownText: String?
            switch field {
            case .title:
                markdownText = articleModel.title
            case .body:
                markdownText = articleModel.body
            case .summary:
                markdownText = articleModel.summary
            case .criticalAnalysis:
                markdownText = articleModel.criticalAnalysis
            case .sourceAnalysis:
                markdownText = articleModel.sourceAnalysis
            case .logicalFallacies:
                markdownText = articleModel.logicalFallacies
            case .relationToTopic:
                markdownText = articleModel.relationToTopic
            case .additionalInsights:
                markdownText = articleModel.additionalInsights
            }
            
            guard let unwrappedText = markdownText, !unwrappedText.isEmpty else {
                AppLogger.database.warning("No text available for field: \(String(describing: field))")
                return nil
            }
            
            AppLogger.database.debug("⚙️ Converting markdown to attributed string (length: \(unwrappedText.count), preview: \"\(unwrappedText.prefix(50))...\")")
            
            // Generate the attributed string
            let startTime = Date()
            let attributedString = markdownToAttributedString(
                unwrappedText,
                textStyle: field.textStyle
            )
            
            let duration = Date().timeIntervalSince(startTime)
            AppLogger.database.debug("✅ Markdown conversion completed in \(String(format: "%.4f", duration))s (result length: \(unwrappedText.count))")
            
            if let attributedString = attributedString {
                // Archive to data
                do {
                    let blobData = try NSKeyedArchiver.archivedData(
                        withRootObject: attributedString,
                        requiringSecureCoding: false
                    )
                    
                    // Set the blob on the article model
                    field.setBlob(blobData, on: articleModel)
                    
                    // Save the context
                    try context.save()
                    AppLogger.database.debug("✅ Saved \(String(describing: field)) blob to database (\(blobData.count) bytes) - verified")
                } catch {
                    AppLogger.database.error("❌ Failed to save blob for \(String(describing: field)): \(error)")
                }
                
                return attributedString
            }
            
            return nil
        } catch {
            AppLogger.database.error("Error generating rich text content: \(error)")
            return nil
        }
    }

    // MARK: - Private Helper Methods

    private func processRemoteArticles(_ articles: [ArticleJSON], progressHandler: ((Int, Int) -> Void)? = nil) async throws -> Int {
        guard !articles.isEmpty else { return 0 }

        // Define missing topics to watch for
        let missingTopics = Set(["Rust", "Space", "Tuscany", "Vulnerability"])
        
        var addedCount = 0
        let totalCount = articles.count
        
        // Report initial progress
        progressHandler?(0, totalCount)
        
        // Create a fresh context for this transaction
        let context = ModelContext(modelContainer)
        
        AppLogger.database.debug("🔄 Starting article processing with batched transaction management")
        
        // Process articles in batches for better memory management and transactional safety
        let batchSize = 10
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            // Calculate the end index for this batch
            let batchEnd = min(batchStart + batchSize, totalCount)
            AppLogger.database.debug("📝 Starting batch \(batchStart/batchSize + 1): articles \(batchStart+1)-\(batchEnd) of \(totalCount)")
            
            // Process each article in the batch
            for index in batchStart..<batchEnd {
                let article = articles[index]
                
                // Report progress every few articles
                if index % 2 == 0 || index == totalCount - 1 {
                    progressHandler?(index + 1, totalCount)
                }
                
                // Special logging for missing topics only
                if let topic = article.topic, missingTopics.contains(topic) {
                    AppLogger.database.debug("📊 MISSING TOPIC: Processing article with topic '\(topic)' - jsonURL: \(article.jsonURL)")
                }
                
                // Extract the jsonURL for checking duplicates
                let jsonURLString = article.jsonURL

                // Skip articles with empty jsonURL
                guard !jsonURLString.isEmpty else {
                    AppLogger.database.warning("⚠️ Skipping article with empty jsonURL")
                    continue
                }

                // Efficiently check for duplicates using a direct predicate query
                // All checks and insertions within this batch are part of the same transaction
                let existingArticlePredicate = #Predicate<ArticleModel> { $0.jsonURL == jsonURLString }
                let existingArticleDescriptor = FetchDescriptor<ArticleModel>(predicate: existingArticlePredicate)
                let existingArticles = try context.fetch(existingArticleDescriptor)

                if existingArticles.isEmpty {
                    // Create a new ArticleModel
                    let date = Date()
                    let newArticle = ArticleModel(
                        id: UUID(),
                        jsonURL: article.jsonURL,
                        url: article.url,
                        title: article.title,
                        body: article.body,
                        domain: article.domain,
                        articleTitle: article.articleTitle,
                        affected: article.affected,
                        publishDate: article.pubDate ?? date,
                        addedDate: date,
                        topic: article.topic,
                        isViewed: false,
                        isBookmarked: false,
                        sourcesQuality: article.sourcesQuality,
                        argumentQuality: article.argumentQuality,
                        sourceType: article.sourceType,
                        sourceAnalysis: article.sourceAnalysis,
                        quality: article.quality,
                        summary: article.summary,
                        criticalAnalysis: article.criticalAnalysis,
                        logicalFallacies: article.logicalFallacies,
                        relationToTopic: article.relationToTopic,
                        additionalInsights: article.additionalInsights
                    )

                    context.insert(newArticle)
                    
                    // Special logging for missing topics only
                    if let topic = article.topic, missingTopics.contains(topic) {
                        AppLogger.database.debug("✅ MISSING TOPIC: Added new article with topic '\(topic)' - title: \(article.title)")
                    }

                    addedCount += 1
                } else {
                    // Special logging for missing topics only
                    if let topic = article.topic, missingTopics.contains(topic) {
                        AppLogger.database.debug("⚠️ MISSING TOPIC: Skipping duplicate article with topic '\(topic)'")
                    } else {
                        // Log that we're skipping a duplicate (normal logging)
                        AppLogger.database.debug("Skipping duplicate article with jsonURL: \(jsonURLString)")
                    }

                    // We already have this article - update any missing fields if needed
                    // This could be expanded to update specific fields that might change
                }
            }
            
            // Save after each batch to ensure changes are committed
            // This creates transaction boundaries after each batch
            try context.save()
            AppLogger.database.debug("✅ Completed and saved batch \(batchStart/batchSize + 1)")
        }
        
        AppLogger.database.debug("✅ All batches processed - added \(addedCount) new articles")
        
        // Now that all articles are saved, generate rich text content
        // This is done as a separate step to avoid overloading the initial insertion transaction
        if addedCount > 0 {
            AppLogger.database.debug("⚙️ Generating rich text for \(addedCount) new articles")
            
            // Fetch all the new articles we just added
            var newArticlesFetchDescriptor = FetchDescriptor<ArticleModel>()
            newArticlesFetchDescriptor.sortBy = [SortDescriptor(\.addedDate, order: .reverse)]
            newArticlesFetchDescriptor.fetchLimit = addedCount
            
            let newArticles = try context.fetch(newArticlesFetchDescriptor)
            
            // Process rich text generation in smaller batches too
            let richTextBatchSize = 5
            for batchStart in stride(from: 0, to: newArticles.count, by: richTextBatchSize) {
                let batchEnd = min(batchStart + richTextBatchSize, newArticles.count)
                AppLogger.database.debug("⚙️ Generating rich text for batch \(batchStart/richTextBatchSize + 1): articles \(batchStart+1)-\(batchEnd) of \(newArticles.count)")
                
                for i in batchStart..<batchEnd {
                    // Generate rich text directly on the ArticleModel
                    await generateInitialRichText(for: newArticles[i])
                }
                
                // Save after each batch of rich text generation
                try context.save()
                AppLogger.database.debug("✅ Completed and saved rich text batch \(batchStart/richTextBatchSize + 1)")
            }
            
            AppLogger.database.debug("✅ Rich text generation completed for all \(addedCount) new articles")
        }

        // Clear cache safely as we have new data
        await withCheckedContinuation { continuation in
            clearCache() // This now runs on cacheQueue
            continuation.resume()
        }

        // Return count of new articles
        return addedCount
    }

    /// Removes duplicate articles from the database, keeping only the newest version of each article
    /// - Returns: The number of duplicate articles removed
    func removeDuplicateArticles() async throws -> Int {
        AppLogger.database.info("Starting duplicate article cleanup...")
        let context = ModelContext(modelContainer)
        var removedCount = 0

        // Get all articles
        let fetchDescriptor = FetchDescriptor<ArticleModel>()
        let allArticles = try context.fetch(fetchDescriptor)

        AppLogger.database.info("Analyzing \(allArticles.count) articles for duplicates")

        // Group by jsonURL
        var articlesByURL: [String: [ArticleModel]] = [:]
        for article in allArticles {
            if !article.jsonURL.isEmpty {
                var articles = articlesByURL[article.jsonURL] ?? []
                articles.append(article)
                articlesByURL[article.jsonURL] = articles
            }
        }

        // Count duplicates
        var duplicateCount = 0
        for (_, articles) in articlesByURL {
            if articles.count > 1 {
                duplicateCount += articles.count - 1
            }
        }

        AppLogger.database.info("Found \(duplicateCount) duplicate articles to remove")

        // Keep only the newest of each duplicate set
        for (jsonURL, articles) in articlesByURL {
            if articles.count > 1 {
                // Sort by addedDate, newest first
                let sortedArticles = articles.sorted { ($0.addedDate) > ($1.addedDate) }

                // Keep the first one (newest), delete the rest
                AppLogger.database.debug("Removing \(articles.count - 1) duplicates for article with jsonURL: \(jsonURL)")
                for i in 1 ..< sortedArticles.count {
                    context.delete(sortedArticles[i])
                    removedCount += 1
                }
            }
        }

        // Save changes
        try context.save()

        // Clear cache safely
        await withCheckedContinuation { continuation in
            clearCache() // This now runs on cacheQueue
            continuation.resume()
        }

        AppLogger.database.info("Removed \(removedCount) duplicate articles")

        return removedCount
    }

    /// Counts the number of unviewed articles in the database
    /// - Returns: The count of unviewed articles
    @MainActor
    func countUnviewedArticles() async throws -> Int {
        do {
            let container = SwiftDataContainer.shared.container
            let context = container.mainContext

            // Create a fetch descriptor for ArticleModel with predicate for !isViewed
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { article in
                    !article.isViewed
                }
            )

            // Fetch count with detailed logging
            let count = try context.fetchCount(descriptor)
            ModernizationLogger.log(.debug, component: .articleService,
                                    message: "Fetched unviewed article count: \(count)")
            return count
        } catch {
            ModernizationLogger.log(.error, component: .articleService,
                                    message: "Error fetching unviewed article count: \(error.localizedDescription)")
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }
    
    // MARK: - Topic Statistics
    
    /// Get statistics for all topics in the database
    func getTopicStatistics() async throws -> [TopicStatistic] {
        let context = ModelContext(modelContainer)
        
        // Fetch all articles
        let allArticles = try context.fetch(FetchDescriptor<ArticleModel>())
        
        // Group by topic
        var topicStats: [String: TopicStatistic] = [:]
        
        for article in allArticles {
            let topic = article.topic ?? "Uncategorized"
            
            var stat = topicStats[topic] ?? TopicStatistic(
                topic: topic,
                totalCount: 0,
                unreadCount: 0,
                bookmarkedCount: 0
            )
            
            // Update counts
            stat = TopicStatistic(
                topic: topic,
                totalCount: stat.totalCount + 1,
                unreadCount: stat.unreadCount + (article.isViewed ? 0 : 1),
                bookmarkedCount: stat.bookmarkedCount + (article.isBookmarked ? 1 : 0)
            )
            
            topicStats[topic] = stat
        }
        
        return Array(topicStats.values).sorted { $0.topic < $1.topic }
    }
    
    /// Get total article count
    func getTotalArticleCount() async throws -> Int {
        let context = ModelContext(modelContainer)
        return try context.fetchCount(FetchDescriptor<ArticleModel>())
    }

    // MARK: - Cache Management

    // Helper methods for safe cache access
    private func hasCacheKey(_ key: String) -> Bool {
        return cacheQueue.sync {
            self.cacheKeys.contains(key)
        }
    }

    private func cacheSize() -> Int {
        return cacheQueue.sync {
            self.cacheKeys.count
        }
    }

    private func isCacheExpired() -> Bool {
        return cacheQueue.sync {
            let now = Date()
            return now.timeIntervalSince(self.lastCacheUpdate) > self.cacheExpiration
        }
    }

    // Safe method for general cache operations
    private func withSafeCache<T>(_ operation: @escaping () -> T) -> T {
        return cacheQueue.sync {
            operation()
        }
    }

    private func createCacheKey(
        topic: String?,
        isRead: Bool?,
        isBookmarked: Bool?,
        isArchived _: Bool?
    ) -> String {
        let topicPart = topic ?? "all"
        let readPart = isRead == nil ? "any" : (isRead! ? "read" : "unread")
        let bookmarkPart = isBookmarked == nil ? "any" : (isBookmarked! ? "bookmarked" : "notBookmarked")
        // Archive functionality removed - parameter kept for API compatibility
        let archivedPart = "any"

        return "\(topicPart)_\(readPart)_\(bookmarkPart)_\(archivedPart)"
    }

    private func checkCache(for key: String) -> [ArticleModel]? {
        return cacheQueue.sync {
            // Check if cache is valid (not expired)
            let now = Date()
            if now.timeIntervalSince(self.lastCacheUpdate) > self.cacheExpiration {
                self.doClearCache() // Use a private implementation for synchronous clearing
                return nil
            }

            // Check if we have this key in cache
            if let cachedArray = self.cache.object(forKey: key as NSString) as? [ArticleModel] {
                ModernizationLogger.log(.debug, component: .articleService,
                                        message: "Cache hit for key: \(key)")
                return cachedArray
            }

            ModernizationLogger.log(.debug, component: .articleService,
                                    message: "Cache miss for key: \(key)")
            return nil
        }
    }

    private func cacheResults(_ results: [ArticleModel], for key: String) {
        cacheQueue.async {
            // Log before accessing cacheKeys
            ModernizationLogger.log(.debug, component: .articleService,
                                    message: "Caching results for key: \(key)")

            self.cache.setObject(results as NSArray, forKey: key as NSString)
            self.cacheKeys.insert(key) // This is where the crash was happening
            self.lastCacheUpdate = Date()

            ModernizationLogger.log(.debug, component: .articleService,
                                    message: "Cache updated, keys count: \(self.cacheKeys.count)")
        }
    }

    private func clearCache() {
        cacheQueue.async {
            self.doClearCache()
        }
    }

    // Private implementation for synchronous clearing
    private func doClearCache() {
        ModernizationLogger.log(.debug, component: .articleService,
                                message: "Clearing cache with \(cacheKeys.count) keys")

        cache.removeAllObjects()
        cacheKeys.removeAll()
        lastCacheUpdate = Date.distantPast

        ModernizationLogger.log(.debug, component: .articleService,
                                message: "Cache cleared")
    }
}
