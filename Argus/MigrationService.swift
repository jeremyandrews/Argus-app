import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Tracks the state of the data migration process
enum MigrationState: String, Codable {
    case notStarted
    case inProgress
    case completed
    case failed
}

/// Stores migration progress for resilience against app termination
struct MigrationProgress: Codable {
    var state: MigrationState = .notStarted
    var progressPercentage: Double = 0
    var lastBatchIndex: Int = 0
    var migratedArticleIds: [UUID] = []
    var migratedTopics: [String] = []
    var lastUpdated: Date = .init()
}

/// Migration-specific errors
enum MigrationError: Error, LocalizedError, Equatable {
    case cancelled
    case dataError(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Migration was cancelled"
        case let .dataError(message):
            return "Data error: \(message)"
        }
    }

    static func == (lhs: MigrationError, rhs: MigrationError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled):
            return true
        case let (.dataError(lhsMsg), .dataError(rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Service responsible for migrating data from the old database to SwiftData
@MainActor
class MigrationService: ObservableObject {
    // Published properties for UI updates
    @Published var progress: Double = 0
    @Published var status: String = "Not started"
    @Published var error: Error? = nil

    // Background task identifier
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Migration state tracking
    private var migrationProgress = MigrationProgress()
    private var isCancelled = false

    // References to old and new storage
    private let databaseCoordinator: DatabaseCoordinator
    private let swiftDataContainer: SwiftDataContainer

    init() async {
        // Initialize with shared instances
        databaseCoordinator = await DatabaseCoordinator.shared
        swiftDataContainer = SwiftDataContainer.shared

        // Load any existing progress
        loadMigrationProgress()
    }

    /// Main migration function that orchestrates the entire process
    func migrateAllData() async -> Bool {
        // Check if we're using in-memory storage which can't be used for migration
        if swiftDataContainer.isUsingInMemoryFallback {
            status = "Migration unavailable - using in-memory storage only"
            error = MigrationError.dataError("Migration requires persistent storage. Currently using in-memory mode.")
            progress = 0
            return false
        }

        // Skip completed migrations
        if migrationProgress.state == .completed {
            status = "Migration already completed"
            progress = 1.0
            return true
        }

        // Register for background task
        registerBackgroundTask()

        // Update state
        migrationProgress.state = .inProgress
        saveMigrationProgress()

        do {
            // Get all articles to migrate
            status = "Fetching existing articles..."
            let allArticles = await fetchArticlesToMigrate()

            if allArticles.isEmpty {
                status = "No articles to migrate"
                migrationProgress.state = .completed
                migrationProgress.progressPercentage = 1.0
                progress = 1.0
                saveMigrationProgress()
                return true
            }

            let articleBatches = allArticles.chunked(into: 50)
            status = "Migrating \(allArticles.count) articles in \(articleBatches.count) batches..."

            // Start migration from last successful batch
            for (index, batch) in articleBatches.enumerated().dropFirst(migrationProgress.lastBatchIndex) {
                // Check for cancellation
                if isCancelled {
                    throw MigrationError.cancelled
                }

                // Update progress
                progress = Double(index + 1) / Double(articleBatches.count)
                migrationProgress.progressPercentage = progress
                migrationProgress.lastBatchIndex = index
                saveMigrationProgress()

                status = "Migrating batch \(index + 1) of \(articleBatches.count)..."

                // Process batch
                try await migrateBatch(batch)

                // Check for cancellation
                if isCancelled {
                    throw MigrationError.cancelled
                }
            }

            // Migration completed successfully
            migrationProgress.state = .completed
            migrationProgress.progressPercentage = 1.0
            progress = 1.0
            status = "Migration completed successfully!"
            saveMigrationProgress()

            return true
        } catch {
            // Migration failed
            if let migrationError = error as? MigrationError, migrationError == .cancelled {
                migrationProgress.state = .notStarted
                status = "Migration cancelled"
            } else {
                migrationProgress.state = .failed
                status = "Migration failed: \(error.localizedDescription)"
                self.error = error
                print("Migration failed: \(error.localizedDescription)")
            }

            saveMigrationProgress()

            // End background task if active
            endBackgroundTaskIfNeeded()
            return false
        }
    }

    /// Cancel the current migration
    func cancelMigration() {
        isCancelled = true
        status = "Cancelling migration..."
    }

    /// Fetch all articles that need migration
    private func fetchArticlesToMigrate() async -> [NotificationData] {
        // Fetch all articles from the old database
        do {
            return try await databaseCoordinator.performTransaction { _, context in
                let descriptor = FetchDescriptor<NotificationData>()
                let articles = try context.fetch(descriptor)
                return articles
            }
        } catch {
            AppLogger.database.error("Failed to fetch articles for migration: \(error)")
            return []
        }
    }

    /// Migrate a batch of articles
    private func migrateBatch(_ articles: [NotificationData]) async throws {
        // Get SwiftData context for this batch
        let context = swiftDataContainer.mainContext()

        // Verify context is available - if not, we can't continue with migration
        guard !swiftDataContainer.isUsingInMemoryFallback else {
            throw MigrationError.dataError("Cannot migrate to in-memory storage - persistent store is required")
        }

        // Extract topics from this batch
        let topicModels = extractAndCreateTopics(from: articles, in: context)

        // Convert and insert articles
        for notification in articles {
            // Skip already migrated articles
            if migrationProgress.migratedArticleIds.contains(notification.id) {
                continue
            }

            // Create new article model
            let article = convertToArticleModel(notification)

            // Set up topic relationships
            if let topicName = notification.topic,
               let topic = topicModels[topicName]
            {
                article.topics = [topic]
            }

            // Insert article
            context.insert(article)

            // Create seen article record
            let seenArticle = SeenArticleModel(
                id: notification.id,
                jsonURL: notification.json_url
            )
            context.insert(seenArticle)

            // Record this article as migrated
            migrationProgress.migratedArticleIds.append(notification.id)
        }

        // Save the batch transaction with proper error handling
        do {
            try context.save()

            // Update progress after successful save
            saveMigrationProgress()
        } catch {
            AppLogger.database.error("Error saving migration batch: \(error)")
            throw MigrationError.dataError("Failed to save migrated data: \(error.localizedDescription)")
        }
    }

    /// Convert from NotificationData to ArticleModel
    private func convertToArticleModel(_ notification: NotificationData) -> ArticleModel {
        let article = ArticleModel(
            id: notification.id,
            jsonURL: notification.json_url,
            url: notification.article_url,
            title: notification.title,
            body: notification.body,
            domain: notification.domain,
            articleTitle: notification.article_title,
            affected: notification.affected,
            publishDate: notification.pub_date ?? notification.date,
            addedDate: Date(),
            topic: notification.topic,
            isViewed: notification.isViewed,
            isBookmarked: notification.isBookmarked,
            isArchived: notification.isArchived,
            sourcesQuality: notification.sources_quality,
            argumentQuality: notification.argument_quality,
            sourceType: notification.source_type,
            sourceAnalysis: notification.source_analysis,
            quality: notification.quality,
            summary: notification.summary,
            criticalAnalysis: notification.critical_analysis,
            logicalFallacies: notification.logical_fallacies,
            relationToTopic: notification.relation_to_topic,
            additionalInsights: notification.additional_insights,
            engineStats: notification.engine_stats,
            similarArticles: notification.similar_articles
        )

        return article
    }

    /// Extract topics from notifications and create TopicModels
    private func extractAndCreateTopics(from notifications: [NotificationData], in context: ModelContext) -> [String: TopicModel] {
        // Fetch existing topics to avoid duplicates
        let existingTopics = try? context.fetch(FetchDescriptor<TopicModel>())
        var topicMap = [String: TopicModel]()

        // Add existing topics to our map
        if let existingTopics = existingTopics {
            for topic in existingTopics {
                topicMap[topic.name] = topic
            }
        }

        // Extract unique topic names from this batch
        let topicNames = Set(notifications.compactMap { $0.topic })

        // Create topic models for each new unique name
        for name in topicNames where !name.isEmpty {
            // Skip if already created
            if topicMap[name] != nil || migrationProgress.migratedTopics.contains(name) {
                continue
            }

            // Create new topic
            let topic = TopicModel(name: name)
            context.insert(topic)
            topicMap[name] = topic

            // Record this topic as migrated
            migrationProgress.migratedTopics.append(name)
        }

        return topicMap
    }

    /// Save migration progress to UserDefaults
    private func saveMigrationProgress() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(migrationProgress)
            UserDefaults.standard.set(data, forKey: "migrationProgress")
        } catch {
            // Log error but continue
            AppLogger.database.error("Failed to save migration progress: \(error)")
        }
    }

    /// Load migration progress from UserDefaults
    private func loadMigrationProgress() {
        guard let data = UserDefaults.standard.data(forKey: "migrationProgress"),
              let progress = try? JSONDecoder().decode(MigrationProgress.self, from: data)
        else {
            return
        }

        migrationProgress = progress
        self.progress = progress.progressPercentage

        switch progress.state {
        case .notStarted:
            status = "Not started"
        case .inProgress:
            status = "Migration in progress (\(Int(progress.progressPercentage * 100))%)"
        case .completed:
            status = "Migration completed"
            self.progress = 1.0
        case .failed:
            status = "Previous migration failed"
        }
    }

    /// Register a background task for migration
    private func registerBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            // When background time is about to expire:
            self?.suspendMigration()
            self?.endBackgroundTaskIfNeeded()
        }
    }

    /// End the background task if active
    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    /// Suspend migration for backgrounding
    private func suspendMigration() {
        saveMigrationProgress()
        status = "Migration suspended - will resume later"
    }

    /// Check if a migration needs to be resumed
    func checkAndResumeIfNeeded() -> Bool {
        if migrationProgress.state == .inProgress {
            status = "Resuming previous migration..."
            return true
        }
        return false
    }

    /// Reset migration state (for testing)
    func resetMigration() {
        migrationProgress = MigrationProgress()
        progress = 0
        status = "Not started"
        error = nil
        isCancelled = false
        saveMigrationProgress()
    }
}
