import Foundation
import SwiftData
import SwiftUI

/// A specialized ArticleService implementation that handles one-time migration needs
/// This service acts as a bridge during the one-time migration process
@available(*, deprecated, message: "Use ArticleService directly. This class exists only for the one-time migration process and will be removed in a future update.")
class MigrationAwareArticleService: ArticleServiceProtocol {
    // MARK: - Properties

    // Dependencies
    private let articleService: ArticleService
    private let migrationAdapter: MigrationAdapter
    private var databaseCoordinator: DatabaseCoordinator?
    private var initializationTask: Task<DatabaseCoordinator, Error>?
    private let initializationTimeout: UInt64 = 5_000_000_000 // 5 seconds in nanoseconds

    // MARK: - Initialization

    init(
        articleService: ArticleService = .shared,
        migrationAdapter: MigrationAdapter = .shared,
        databaseCoordinator: DatabaseCoordinator? = nil
    ) {
        self.articleService = articleService
        self.migrationAdapter = migrationAdapter
        self.databaseCoordinator = databaseCoordinator

        // Initialize task to nil - we'll create it after full initialization
        initializationTask = nil

        // After all properties initialized, create the async task
        createInitializationTaskIfNeeded()
    }

    /// Creates an initialization task if needed
    private func createInitializationTaskIfNeeded() {
        // If coordinator is already available, we don't need a task
        if databaseCoordinator != nil {
            return
        }

        // If we don't have a task yet, create one
        if initializationTask == nil {
            // Create a weak reference to avoid retain cycles
            weak var weakSelf = self

            // Create a task that will fetch the coordinator asynchronously
            initializationTask = Task {
                // Get the shared coordinator asynchronously
                let coordinator = await DatabaseCoordinator.shared

                // Update the stored reference on the main actor
                if let strongSelf = weakSelf {
                    await MainActor.run {
                        strongSelf.databaseCoordinator = coordinator
                        AppLogger.database.debug("DatabaseCoordinator initialized in MigrationAwareArticleService")
                    }
                }

                return coordinator
            }
        }
    }

    // MARK: - ArticleServiceProtocol Implementation

    // Forward most standard operations to the regular ArticleService

    func fetchArticles(
        topic: String?,
        isRead: Bool?,
        isBookmarked: Bool?,
        isArchived: Bool?,
        limit: Int?,
        offset: Int?
    ) async throws -> [NotificationData] {
        // Simply pass through to the underlying service
        return try await articleService.fetchArticles(
            topic: topic,
            isRead: isRead,
            isBookmarked: isBookmarked,
            isArchived: isArchived,
            limit: limit,
            offset: offset
        )
    }

    func fetchArticle(byId id: UUID) async throws -> NotificationData? {
        // Simply pass through to the underlying service
        return try await articleService.fetchArticle(byId: id)
    }

    func fetchArticle(byJsonURL jsonURL: String) async throws -> NotificationData? {
        // Simply pass through to the underlying service
        return try await articleService.fetchArticle(byJsonURL: jsonURL)
    }

    func searchArticles(queryText: String, limit: Int?) async throws -> [NotificationData] {
        // Simply pass through to the underlying service
        return try await articleService.searchArticles(queryText: queryText, limit: limit)
    }

    @available(*, deprecated, message: "Use ArticleService.shared directly instead")
    func markArticle(id: UUID, asRead isRead: Bool) async throws {
        // Simply forward to the regular article service - no more legacy database updates
        try await articleService.markArticle(id: id, asRead: isRead)
    }

    @available(*, deprecated, message: "Use ArticleService.shared directly instead")
    func markArticle(id: UUID, asBookmarked isBookmarked: Bool) async throws {
        // Simply forward to the regular article service - no more legacy database updates
        try await articleService.markArticle(id: id, asBookmarked: isBookmarked)
    }

    // Archive functionality removed

    @available(*, deprecated, message: "Use ArticleService.shared directly instead")
    func deleteArticle(id: UUID) async throws {
        // Simply forward to the regular article service - no more legacy database updates
        try await articleService.deleteArticle(id: id)
    }

    func processArticleData(_ articles: [ArticleJSON]) async throws -> Int {
        try await articleService.processArticleData(articles)
    }

    func syncArticlesFromServer(topic: String?, limit: Int?) async throws -> Int {
        try await articleService.syncArticlesFromServer(topic: topic, limit: limit)
    }

    func performBackgroundSync() async throws -> SyncResultSummary {
        try await articleService.performBackgroundSync()
    }

    /// Generates rich text content for a specific field of an article
    /// - Parameters:
    ///   - articleId: The unique identifier of the article
    ///   - field: The field to generate rich text for
    /// - Returns: The generated NSAttributedString if successful, nil otherwise
    @MainActor
    func generateRichTextContent(
        for articleId: UUID,
        field: RichTextField
    ) async throws -> NSAttributedString? {
        // Delegate to the main ArticleService implementation
        try await articleService.generateRichTextContent(for: articleId, field: field)
    }

    /// Removes duplicate articles from the database
    /// - Returns: The number of duplicate articles removed
    func removeDuplicateArticles() async throws -> Int {
        // Forward to the main ArticleService implementation
        try await articleService.removeDuplicateArticles()
    }

    // MARK: - Migration-Specific Methods

    /// Handles article processing via MigrationAdapter for compatibility with the legacy system
    func processArticleViaLegacySystem(jsonURL: String) async -> Bool {
        return await migrationAdapter.directProcessArticle(jsonURL: jsonURL)
    }

    /// Processes a batch of articles using the MigrationAdapter
    func processBatchViaLegacySystem(urls: [String]) async {
        await migrationAdapter.processArticlesDirectly(urls: urls)
    }

    /// Fetch articles from legacy system for migration
    /// - Note: This method is isolated to the MainActor since it returns non-Sendable ArticleModel objects
    @MainActor
    func fetchArticlesFromLegacySystem() async -> [ArticleModel] {
        do {
            // Create a fresh context on the MainActor - no need to get coordinator
            // since we're using the container directly
            let context = SwiftDataContainer.shared.container.mainContext
            let descriptor = FetchDescriptor<ArticleModel>()

            // Directly fetch using the MainActor-isolated context instead of using performTransaction
            // This avoids crossing actor boundaries with non-Sendable types
            return try context.fetch(descriptor)
        } catch {
            AppLogger.database.error("Failed to fetch articles from legacy system: \(error)")
            return []
        }
    }

    /// Find legacy article by ID or JSON URL
    /// - Note: This method is isolated to the MainActor since it returns a non-Sendable ArticleModel object
    @MainActor
    func findLegacyArticle(id: UUID, jsonURL: String) async -> ArticleModel? {
        // Store Sendable values for use across actor boundaries
        let targetId = id
        let targetURL = jsonURL

        // Check if article exists in the legacy system before attempting to find it
        // Using a direct boolean check instead of binding to unused variable
        if await migrationAdapter.findExistingArticle(jsonURL: targetURL, articleID: targetId) != nil {
            // We're already on the MainActor, so get the context directly
            let context = SwiftDataContainer.shared.container.mainContext

            do {
                // Try to find by URL first (most reliable) using a direct predicate
                if !targetURL.isEmpty {
                    let urlDescriptor = FetchDescriptor<ArticleModel>(
                        predicate: #Predicate<ArticleModel> { $0.jsonURL == targetURL }
                    )
                    let urlMatches = try context.fetch(urlDescriptor)

                    if let matchByURL = urlMatches.first {
                        return matchByURL
                    }
                }

                // If not found by URL, try by ID
                let idDescriptor = FetchDescriptor<ArticleModel>(
                    predicate: #Predicate<ArticleModel> { $0.id == targetId }
                )
                let idMatches = try context.fetch(idDescriptor)

                return idMatches.first
            } catch {
                AppLogger.database.error("Error in findLegacyArticle: \(error)")
            }
        }

        return nil
    }

    /// Check if article exists in legacy system
    func legacyArticleExists(id: UUID, jsonURL: String) async -> Bool {
        return await migrationAdapter.standardizedArticleExistsCheck(jsonURL: jsonURL, articleID: id)
    }

    // MARK: - Helper Methods

    /// Get the initialized database coordinator, waiting if necessary
    private func getInitializedCoordinator() async throws -> DatabaseCoordinator {
        do {
            // Try to get the coordinator if already available
            if let coordinator = databaseCoordinator {
                return coordinator
            }

            // Create the initialization task if it hasn't been created yet
            createInitializationTaskIfNeeded()

            // Make sure we have a task
            guard let task = initializationTask else {
                throw ArticleServiceError.databaseError(underlyingError:
                    NSError(domain: "MigrationAwareArticleService", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to create initialization task"]))
            }

            // Wait for the initialization task with a timeout
            AppLogger.database.debug("Waiting for DatabaseCoordinator initialization...")

            // Use a timeout with the Task.value to enforce a time limit
            let coordinatorResult = try await withTimeout(duration: .seconds(5)) {
                try await task.value
            }

            // Store the result for future use
            await MainActor.run {
                self.databaseCoordinator = coordinatorResult
            }

            return coordinatorResult
        } catch is TimeoutError {
            // Handle task timeout
            throw ArticleServiceError.databaseError(underlyingError:
                NSError(domain: "MigrationAwareArticleService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for DatabaseCoordinator initialization"]))
        } catch {
            // Handle other errors from the initialization task
            throw ArticleServiceError.databaseError(underlyingError: error)
        }
    }

    /// Helper for adding timeout to async operations
    private func withTimeout<T>(duration: Duration, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Start the actual operation
            group.addTask {
                try await operation()
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }

            // Return the first completed task (either the operation or the timeout)
            // If the operation completes first, the timeout task will be cancelled
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Error type for timeout
    private struct TimeoutError: Error {}

    /// Update article state in legacy system
    /// - Note: This method is isolated to the MainActor to handle SwiftData operations properly
    @MainActor
    private func updateLegacyArticleState(id: UUID, field: String, value: Any) async throws {
        // Store Sendable properties before actor transitions
        let targetId = id
        let targetField = field

        // Get a fresh context on the MainActor
        let context = SwiftDataContainer.shared.container.mainContext

        // Create descriptor and fetch articles on the MainActor
        let descriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.id == targetId }
        )
        let matchingArticles = try context.fetch(descriptor)

        // Find the article with matching ID
        guard let article = matchingArticles.first else {
            // Article not found - log and return early
            AppLogger.database.debug("Article with ID \(targetId) not found in legacy system for update")
            return
        }

        // Update the appropriate field
        switch targetField {
        case "isViewed":
            if let boolValue = value as? Bool {
                article.isViewed = boolValue
                AppLogger.database.debug("Updated isViewed=\(boolValue) for article \(targetId)")
            }
        case "isBookmarked":
            if let boolValue = value as? Bool {
                article.isBookmarked = boolValue
                AppLogger.database.debug("Updated isBookmarked=\(boolValue) for article \(targetId)")
            }
        // Archive functionality removed
        default:
            AppLogger.database.warning("Attempted to update unsupported field \(targetField) for article \(targetId)")
        }

        // Save the changes
        try context.save()
    }

    /// Delete article in legacy system
    /// - Note: This method is isolated to the MainActor to handle SwiftData operations properly
    @MainActor
    private func deleteLegacyArticle(id: UUID) async throws {
        // Store the ID as Sendable value before actor transition
        let targetId = id

        // Get a fresh context on the MainActor
        let context = SwiftDataContainer.shared.container.mainContext

        // Create descriptor with predicate matching the ID
        let descriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate<ArticleModel> { $0.id == targetId }
        )
        let matchingArticles = try context.fetch(descriptor)

        // Find the article with matching ID
        guard let article = matchingArticles.first else {
            // Not found - log and exit early
            AppLogger.database.debug("Article with ID \(targetId) not found in legacy system for deletion")
            return
        }

        // Delete the article
        context.delete(article)
        AppLogger.database.debug("Deleted article \(targetId) from legacy system")

        // Save the changes
        try context.save()
    }
}

// The implementation is now complete and properly conforms to Swift 6 concurrency requirements
