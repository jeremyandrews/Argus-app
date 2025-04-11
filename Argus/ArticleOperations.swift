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
    func toggleReadStatus(for article: ArticleModel) async throws -> Bool {
        let newReadStatus = !article.isViewed
        try await articleService.markArticle(id: article.id, asRead: newReadStatus)

        // Update UI state on the MainActor
        // Note: In Swift 6, we can't capture a PersistentModel directly in a @Sendable closure
        // So we extract the ID (which is Sendable) and use that in the Task
        let articleId = article.id // UUID is Sendable
        // Fire-and-forget task with explicit discard using underscore
        _ = Task { @MainActor in
            if let freshArticle = await getArticleModelWithContext(byId: articleId) {
                freshArticle.isViewed = newReadStatus
            }
        }

        AppLogger.database.debug("✅ Toggled read status to \(newReadStatus) for article \(article.id)")
        return newReadStatus
    }

    /// Toggles the bookmarked status of an article
    /// - Parameter article: The article to toggle the bookmarked status for
    /// - Returns: Boolean indicating the new bookmarked state
    @discardableResult
    func toggleBookmark(for article: ArticleModel) async throws -> Bool {
        let newBookmarkStatus = !article.isBookmarked
        try await articleService.markArticle(id: article.id, asBookmarked: newBookmarkStatus)

        // Update UI state on the MainActor
        // Note: In Swift 6, we can't capture a PersistentModel directly in a @Sendable closure
        // So we extract the ID (which is Sendable) and use that in the Task
        let articleId = article.id // UUID is Sendable
        // Fire-and-forget task with explicit discard using underscore
        _ = Task { @MainActor in
            if let freshArticle = await getArticleModelWithContext(byId: articleId) {
                freshArticle.isBookmarked = newBookmarkStatus
            }
        }

        AppLogger.database.debug("✅ Toggled bookmark status to \(newBookmarkStatus) for article \(article.id)")
        return newBookmarkStatus
    }

    // Archive functionality removed

    /// Deletes an article
    /// - Parameter article: The article to delete
    func deleteArticle(_ article: ArticleModel) async throws {
        try await articleService.deleteArticle(id: article.id)
        AppLogger.database.debug("✅ Deleted article \(article.id)")
    }

    /// Fetches a complete article by ID, ensuring all fields are loaded
    /// - Parameter id: The article ID to fetch
    /// - Returns: The complete article, or nil if not found
    @MainActor
    func getCompleteArticle(byId id: UUID) async -> ArticleModel? {
        do {
            // Get the article model directly using the context
            let model = await getArticleModelWithContext(byId: id)

            // Log for debugging
            if let model = model {
                let hasTitleBlob = model.titleBlob != nil
                let hasBodyBlob = model.bodyBlob != nil
                let hasSummaryBlob = model.summaryBlob != nil
                let hasEngineStats = model.engineStats != nil
                let hasSimilarArticles = model.similarArticles != nil

                AppLogger.database.debug("""
                Fetched complete ArticleModel \(id):
                - Title blob: \(hasTitleBlob)
                - Body blob: \(hasBodyBlob)
                - Summary blob: \(hasSummaryBlob)
                - Engine stats: \(hasEngineStats)
                - Similar articles: \(hasSimilarArticles)
                """)
            }

            return model
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
    @MainActor
    func fetchArticles(
        topic: String?,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool,
        limit: Int? = nil
    ) async throws -> [ArticleModel] {
        let container = SwiftDataContainer.shared.container
        let context = container.mainContext

        // Build predicates using modern compound approach
        var conditions = [Predicate<ArticleModel>]()

        // Topic filter (only if a specific topic is selected)
        if let topic = topic, topic != "All" {
            conditions.append(#Predicate<ArticleModel> { $0.topic == topic })
        }

        // Read status filter
        if showUnreadOnly {
            conditions.append(#Predicate<ArticleModel> { !$0.isViewed })
        }

        // Bookmark filter
        if showBookmarkedOnly {
            conditions.append(#Predicate<ArticleModel> { $0.isBookmarked })
        }

        // Create the fetch descriptor
        var descriptor = FetchDescriptor<ArticleModel>()

        // Apply predicates to the descriptor
        if !conditions.isEmpty {
            if conditions.count == 1 {
                // If only one condition, use it directly
                descriptor.predicate = conditions[0]
            } else {
                // For multiple conditions, we need to use one condition in the initial fetch
                // and then filter the results manually for the other conditions

                // First, apply the most restrictive predicate to limit the initial fetch
                if showUnreadOnly {
                    // This is typically the most restrictive filter
                    descriptor.predicate = #Predicate<ArticleModel> { !$0.isViewed }
                } else if showBookmarkedOnly {
                    descriptor.predicate = #Predicate<ArticleModel> { $0.isBookmarked }
                } else if let topic = topic, topic != "All" {
                    descriptor.predicate = #Predicate<ArticleModel> { $0.topic == topic }
                }
            }
        }

        // Sort by date (newest first)
        descriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]

        // Apply limit if needed
        if let limit = limit {
            descriptor.fetchLimit = limit
        }

        do {
            var articles = try context.fetch(descriptor)

            // Apply additional in-memory filtering for multiple filter conditions
            if conditions.count > 1 {
                AppLogger.database.debug("🔍 Applying additional in-memory filters")

                // Track which predicate was applied at the database level
                let appliedUnreadFilter = showUnreadOnly && descriptor.predicate != nil && conditions.count > 1
                let appliedBookmarkFilter = showBookmarkedOnly && !appliedUnreadFilter && descriptor.predicate != nil
                let appliedTopicFilter = topic != nil && topic != "All" && !appliedUnreadFilter && !appliedBookmarkFilter && descriptor.predicate != nil

                // Apply remaining filters in memory
                if let topic = topic, topic != "All", !appliedTopicFilter {
                    AppLogger.database.debug("🔍 Applying topic filter in memory: \(topic)")
                    articles = articles.filter { $0.topic == topic }
                }

                // Apply unread filter in memory if not applied at database level
                if showUnreadOnly, !appliedUnreadFilter {
                    AppLogger.database.debug("🔍 Applying unread filter in memory")
                    articles = articles.filter { !$0.isViewed }
                }

                // Apply bookmark filter in memory if not applied at database level
                if showBookmarkedOnly, !appliedBookmarkFilter {
                    AppLogger.database.debug("🔍 Applying bookmark filter in memory")
                    articles = articles.filter { $0.isBookmarked }
                }
            }

            AppLogger.database.debug("✅ Fetched \(articles.count) articles with filters")
            return articles
        } catch {
            AppLogger.database.error("❌ Error fetching articles: \(error)")
            throw error
        }
    }

    /// Fetches a specific article by ID
    /// - Parameter id: The unique identifier of the article
    /// - Returns: The article if found, nil otherwise
    @MainActor
    func fetchArticle(byId id: UUID) async throws -> ArticleModel? {
        return await getArticleModelWithContext(byId: id)
    }

    /// Gets the original ArticleModel with SwiftData context for direct persistence operations
    /// - Parameter id: The unique identifier of the article
    /// - Returns: The ArticleModel with a valid context if found, nil otherwise
    @MainActor
    func getArticleModelWithContext(byId id: UUID) async -> ArticleModel? {
        // Access the container directly since it's already a non-optional
        let container = SwiftDataContainer.shared.container

        AppLogger.database.debug("🔍 Getting ArticleModel with context for ID: \(id)")
        AppLogger.database.debug("🔍 Container: \(String(describing: container))")

        do {
            // First try with main context
            let descriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate<ArticleModel> { $0.id == id }
            )

            // Get article from main context
            let context = container.mainContext
            let results = try context.fetch(descriptor)

            if let model = results.first {
                if model.modelContext != nil {
                    AppLogger.database.debug("✅ Found ArticleModel with context for ID: \(id)")
                    return model
                } else {
                    AppLogger.database.warning("⚠️ Found ArticleModel but it has no context")
                }
            }

            // If not found or no context, try with a fresh context
            let newContext = ModelContext(container)
            let newResults = try newContext.fetch(descriptor)

            if let newModel = newResults.first {
                AppLogger.database.debug("✅ Found ArticleModel with fresh context for ID: \(id)")
                return newModel
            }
        } catch {
            AppLogger.database.error("❌ Error fetching ArticleModel: \(error)")
        }

        AppLogger.database.error("❌ Could not find ArticleModel with context for ID: \(id)")
        return nil
    }

    /// Gets the ArticleModel with context, previously handled by ArticleModelAdapter
    /// - Parameter id: The article ID to fetch
    /// - Returns: A tuple containing the ArticleModel and the database model with context
    @MainActor
    func getArticleWithContext(id: UUID) async -> (ArticleModel?, ArticleModel?) {
        // We now simply return the same model twice since we're using ArticleModel directly
        let model = await getArticleModelWithContext(byId: id)

        if let model = model {
            AppLogger.database.debug("✅ getArticleWithContext: Retrieved ArticleModel with id: \(id)")
            // Return the same model twice - this maintains backward compatibility with code
            // that expected a tuple of (NotificationData, ArticleModel)
            return (model, model)
        }

        AppLogger.database.error("❌ getArticleWithContext: Failed to retrieve ArticleModel with id: \(id)")
        return (nil, nil)
    }

    /// Saves blob data to an ArticleModel
    /// - Parameters:
    ///   - field: The field to save blob for
    ///   - blobData: The blob data to save
    ///   - articleModel: The ArticleModel to update
    /// - Returns: True if save was successful
    @MainActor
    func saveBlobToDatabase(field: RichTextField, blobData: Data, articleModel: ArticleModel) -> Bool {
        guard let context = articleModel.modelContext else {
            AppLogger.database.error("❌ ArticleModel has no context for saving")
            return false
        }

        // Get human-readable field name for better logging
        let fieldName = SectionNaming.nameForField(field)

        // Set the blob on the ArticleModel
        field.setBlob(blobData, on: articleModel)

        // Save the context
        do {
            try context.save()

            // Verify the blob was set correctly by reading it back
            let blobSet = verifyBlobSetProperly(field: field, articleModel: articleModel, expectedSize: blobData.count)

            if blobSet {
                AppLogger.database.debug("✅ Saved \(fieldName) blob to database (\(blobData.count) bytes) - verified")
                return true
            } else {
                AppLogger.database.warning("⚠️ Save appeared successful but blob verification failed for \(fieldName)")
                return false
            }
        } catch {
            AppLogger.database.error("❌ Error saving \(fieldName) blob: \(error)")
            return false
        }
    }

    /// Verifies that a blob was properly set on the ArticleModel
    /// - Parameters:
    ///   - field: The field to verify
    ///   - articleModel: The ArticleModel to check
    ///   - expectedSize: The expected size of the blob
    /// - Returns: True if the blob is present and has the expected size
    private func verifyBlobSetProperly(field: RichTextField, articleModel: ArticleModel, expectedSize: Int) -> Bool {
        let fieldName = SectionNaming.nameForField(field)
        let blob = field.getBlob(from: articleModel)

        guard let blobData = blob, !blobData.isEmpty else {
            AppLogger.database.warning("⚠️ \(fieldName) blob verification failed - blob is nil or empty")
            return false
        }

        if blobData.count != expectedSize {
            AppLogger.database.warning("⚠️ \(fieldName) blob size mismatch - expected \(expectedSize), got \(blobData.count)")
            return false
        }

        // Try to unarchive to verify it's a valid attributed string
        do {
            if let attributedString = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: blobData),
               attributedString.length > 0
            {
                AppLogger.database.debug("✅ \(fieldName) blob contains valid attributed string")
                return true
            } else {
                AppLogger.database.warning("⚠️ \(fieldName) blob unarchived to nil or empty string")
                return false
            }
        } catch {
            AppLogger.database.error("❌ \(fieldName) blob unarchive error: \(error)")
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
        from article: ArticleModel,
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
            let markdownText = field.getMarkdownText(from: article)

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
                // Save as blob for future use - explicitly discard result to avoid warning
                _ = saveAttributedString(attributedString, for: field, in: article)
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
    func generateAllRichTextContent(for article: ArticleModel) -> [RichTextField: NSAttributedString] {
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
    /// - Note: In Swift 6, this method must be isolated to the MainActor since it returns non-Sendable ArticleModel types
    @MainActor
    func groupArticles(
        _ articles: [ArticleModel],
        by groupingStyle: String,
        sortOrder: String
    ) async -> [(key: String, articles: [ArticleModel])] {
        // First, sort the articles according to the sort order
        let sortedArticles = sortArticles(articles, by: sortOrder)

        // Then group them according to the grouping style
        switch groupingStyle {
        case "date":
            // Create a dictionary mapping dates to articles
            var groupedByDay: [Date: [ArticleModel]] = [:]

            // Manually group rather than using Dictionary(grouping:) to avoid Sendable issues
            for article in sortedArticles {
                let day = Calendar.current.startOfDay(for: article.publishDate)
                if groupedByDay[day] == nil {
                    groupedByDay[day] = []
                }
                groupedByDay[day]?.append(article)
            }

            let sortedDayKeys = groupedByDay.keys.sorted { $0 > $1 }
            return sortedDayKeys.map { day in
                let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                let articles = groupedByDay[day] ?? []
                return (key: displayKey, articles: articles)
            }

        case "topic":
            // Create a dictionary mapping topics to articles
            var groupedByTopic: [String: [ArticleModel]] = [:]

            // Manually group rather than using Dictionary(grouping:) to avoid Sendable issues
            for article in sortedArticles {
                let topic = article.topic ?? "Uncategorized"
                if groupedByTopic[topic] == nil {
                    groupedByTopic[topic] = []
                }
                groupedByTopic[topic]?.append(article)
            }

            return groupedByTopic.map {
                (key: $0.key, articles: $0.value)
            }.sorted { $0.key < $1.key }

        default: // "none"
            return [("", sortedArticles)]
        }
    }

    /// Sorts articles by the specified sort order
    /// - Parameters:
    ///   - articles: The articles to sort
    ///   - sortOrder: The sort order to use
    /// - Returns: A sorted array of articles
    func sortArticles(
        _ articles: [ArticleModel],
        by sortOrder: String
    ) -> [ArticleModel] {
        return articles.sorted { a, b in
            switch sortOrder {
            case "oldest":
                return a.publishDate < b.publishDate
            case "bookmarked":
                if a.isBookmarked != b.isBookmarked {
                    return a.isBookmarked
                }
                return a.publishDate > b.publishDate
            default: // "newest"
                return a.publishDate > b.publishDate
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

    /// Centralized method to load content for a section with proper context management
    /// - Parameters:
    ///   - section: The section name to load
    ///   - articleId: The ID of the article
    /// - Returns: The attributed string for the section, or nil if unavailable
    @MainActor
    func loadContentForSection(section: String, articleId: UUID) async -> NSAttributedString? {
        AppLogger.database.debug("🔄 CENTRALIZED SECTION LOAD: \(section) for article \(articleId)")
        AppLogger.database.debug("🔄 Container: \(String(describing: SwiftDataContainer.shared.container))")

        // Get the article model with context directly - no more dual model approach
        guard let model = await getArticleModelWithContext(byId: articleId) else {
            AppLogger.database.error("❌ Could not retrieve article with ID: \(articleId)")
            return nil
        }

        // Get the field enum from section name
        let field = SectionNaming.fieldForSection(section)
        let normalizedKey = SectionNaming.normalizedKey(section)
        
        // Log section loading details for debugging
        let hasBlobField = field.getBlob(from: model) != nil
        let hasTextField = field.getMarkdownText(from: model) != nil
        AppLogger.database.debug("🔍 SECTION CHECK: \(section) (key: \(normalizedKey)) - Has blob: \(hasBlobField), Has text: \(hasTextField)")

        // PHASE 1: Try to directly extract from blob - we should always try this first
        // and cache the result to avoid unnecessary regeneration
        if let blob = field.getBlob(from: model), !blob.isEmpty {
            do {
                AppLogger.database.debug("⚙️ Attempting to extract attributed string from blob for \(section) (\(blob.count) bytes)")
                
                let attributedString = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSAttributedString.self,
                    from: blob
                )

                if let content = attributedString, content.length > 0 {
                    AppLogger.database.debug("✅ LOADED FROM BLOB: \(section) - \(blob.count) bytes")
                    // CRITICAL: Return the cached blob content instead of regenerating
                    return content
                } else {
                    // We found a blob but it was empty or invalid - log this problem
                    AppLogger.database.warning("⚠️ BLOB INVALID: \(section) - Blob exists but content is empty or nil")
                }
            } catch {
                AppLogger.database.error("❌ BLOB ERROR: \(section) - \(error.localizedDescription)")
            }
        } else {
            AppLogger.database.debug("ℹ️ No blob found for \(section), will need to generate")
        }

        // PHASE 2: Generate from markdown only if blob loading failed
        let markdownText = field.getMarkdownText(from: model)

        guard let text = markdownText, !text.isEmpty else {
            AppLogger.database.warning("⚠️ NO TEXT: \(section) - No source text available")
            return nil
        }

        AppLogger.database.debug("⚙️ PHASE 2: Blob loading failed, attempting rich text generation for \(section)")
        
        // Generate attributed string from markdown
        if let attributedString = markdownToAttributedString(text, textStyle: field.textStyle) {
            AppLogger.database.debug("⚙️ GENERATED: \(section) - Created attributed string")
            
            // IMPROVEMENT: Confirm the attributed string is valid
            if attributedString.length > 0 {
                AppLogger.database.debug("✅ \(section) blob contains valid attributed string")
            } else {
                AppLogger.database.warning("⚠️ Generated \(section) AttributedString is empty")
                // Still continue with save attempt since empty is better than nil
            }

            // Create blob data and save to the ArticleModel
            do {
                // Create blob data for storage
                let blobData = try NSKeyedArchiver.archivedData(
                    withRootObject: attributedString,
                    requiringSecureCoding: false
                )

                // Save to the model and ensure it's stored in the database
                AppLogger.database.debug("⚙️ Saving generated blob for \(section) (\(blobData.count) bytes)")
                
                // First try with the model we already have
                let saved = saveBlobToDatabase(field: field, blobData: blobData, articleModel: model)
                
                if saved {
                    AppLogger.database.debug("✅ SAVED TO MODEL: \(section) - Successfully stored blob")
                } else {
                    // If first attempt fails, try with a fresh model
                    AppLogger.database.warning("⚠️ Initial blob save failed for \(section), attempting with fresh model")
                    
                    if let freshModel = await getArticleModelWithContext(byId: articleId) {
                        let freshSaved = saveBlobToDatabase(field: field, blobData: blobData, articleModel: freshModel)
                        if freshSaved {
                            AppLogger.database.debug("✅ SAVED TO FRESH MODEL: \(section) - Successfully stored blob")
                        } else {
                            AppLogger.database.debug("❌ FAILED TO SAVE TO FRESH MODEL: \(section) - Context issue persists")
                        }
                    } else {
                        AppLogger.database.error("❌ SAVE FAILED: \(section) - Could not retrieve fresh model")
                    }
                }
                
                // Always verify the blob was stored properly
                Task {
                    await verifyBlobStorage(field: field, articleId: articleId)
                }
            } catch {
                AppLogger.database.error("❌ BLOB CREATION ERROR: \(section) - \(error.localizedDescription)")
            }

            // Return the generated attributed string regardless of save result
            return attributedString
        }

        AppLogger.database.error("❌ GENERATION FAILED: \(section) - Could not create attributed string")
        return nil
    }

    // MARK: - Verification

    /// Adds comprehensive verification for blob storage
    /// - Parameters:
    ///   - field: The field to verify
    ///   - articleId: The article ID to verify for
    @MainActor // Entire function must be MainActor-isolated for Swift 6 sendability rules
    func verifyBlobStorage(field: RichTextField, articleId: UUID) async {
        // Already MainActor-isolated so no need for nested @MainActor annotation
        func verifyWithArticle(_ article: ArticleModel?) {
            guard let article = article else {
                AppLogger.database.error("⚠️ VERIFICATION FAILED: Could not retrieve article model for ID: \(articleId)")
                return
            }

            let fieldName = SectionNaming.nameForField(field)

            // Check container and context
            AppLogger.database.debug("🔍 VERIFICATION: Using container: \(String(describing: SwiftDataContainer.shared.container))")
            AppLogger.database.debug("🔍 VERIFICATION: Article has context: \(article.modelContext != nil)")

            // Check if blob exists in ArticleModel
            let blob = field.getBlob(from: article)

            if let blob = blob, !blob.isEmpty {
                AppLogger.database.debug("✅ VERIFICATION: \(fieldName) blob exists in ArticleModel with size: \(blob.count) bytes")

                // Try to unarchive to verify content
                do {
                    if let attributedString = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: blob) {
                        AppLogger.database.debug("✅ VERIFICATION: \(fieldName) blob contains valid attributed string with length: \(attributedString.length)")
                    } else {
                        AppLogger.database.warning("⚠️ VERIFICATION: \(fieldName) blob unarchived to nil")
                    }
                } catch {
                    AppLogger.database.error("❌ VERIFICATION: \(fieldName) blob unarchive error: \(error)")
                }
            } else {
                AppLogger.database.warning("⚠️ VERIFICATION: \(fieldName) blob does not exist in ArticleModel")
            }
        }

        // Get article with context to verify
        let model = await getArticleModelWithContext(byId: articleId)
        // No need for await since verifyWithArticle is not async
        verifyWithArticle(model)
    }
}
