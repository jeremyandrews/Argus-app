import Foundation
import SwiftData
import SwiftUI

/// Service responsible for migrating data from the old database to SwiftData
@MainActor
class MigrationService: ObservableObject {
    // Published properties for UI updates
    @Published var progress: Double = 0
    @Published var status: String = "Not started"
    @Published var error: Error? = nil

    // Performance metrics
    @Published var articlesPerSecond: Double = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var estimatedTimeRemaining: TimeInterval = 0
    @Published var memoryUsage: UInt64 = 0
    @Published var totalArticlesMigrated: Int = 0

    // New property for state sync metrics
    @Published var stateUpdateMetrics: MigrationMetrics = .init()

    // Migration mode and state tracking
    @Published var migrationMode: MigrationMode = .temporary
    @Published var isRunningInBackground: Bool = false

    // Batch size optimization
    private let OPTIMAL_BATCH_SIZE = 100 // Tuned for 2-8 second performance target

    // Metrics tracking
    private var startTime: Date?
    private var totalArticlesProcessed: Int = 0
    private var batchStartTime: Date?
    private var batchArticlesProcessed: Int = 0
    private var timer: Timer?

    // Counters for progress reports
    private var didFindExistingRecords: Bool = false
    private var updatedRecordCount: Int = 0
    private var newRecordCount: Int = 0
    private var progressSaveCounter: Int = 0

    // Background task identifier
    private var backgroundTaskID: UUID = .init()

    // Migration state tracking
    var migrationProgress = MigrationProgress()
    private var isCancelled = false

    // References to storage and services
    private let migrationArticleService: MigrationAwareArticleService
    private let databaseCoordinator: DatabaseCoordinator
    private let swiftDataContainer: SwiftDataContainer

    init(mode: MigrationMode = .temporary) async {
        // Set migration mode
        migrationMode = mode

        // Initialize with shared instances
        databaseCoordinator = await DatabaseCoordinator.shared
        swiftDataContainer = SwiftDataContainer.shared

        // Create migration-aware service with the coordinator
        migrationArticleService = MigrationAwareArticleService(databaseCoordinator: databaseCoordinator)

        // Load any existing progress
        loadMigrationProgress()
    }

    /// Main migration function that orchestrates the entire process
    func migrateAllData() async -> Bool {
        // Start performance metrics tracking
        startMetricsTimer()

        // Reset counters for this migration run
        didFindExistingRecords = false
        updatedRecordCount = 0
        newRecordCount = 0
        progressSaveCounter = 0

        // Configure based on migration mode
        if migrationMode == .production && migrationProgress.state == .completed {
            status = "Migration already completed"
            progress = 1.0
            return true
        }

        // Register for background task
        registerBackgroundTask()

        // Update state
        migrationProgress.state = .inProgress
        migrationProgress.migrationInterrupted = false
        saveMigrationProgress()

        do {
            // Get all articles to migrate
            status = "Fetching existing articles..."
            let allArticles = await fetchArticlesToMigrate()

            if allArticles.isEmpty {
                status = "No articles to migrate"
                if migrationMode == .production {
                    migrationProgress.state = .completed
                }
                migrationProgress.progressPercentage = 1.0
                progress = 1.0
                saveMigrationProgress()
                return true
            }

            let articleBatches = allArticles.chunked(into: OPTIMAL_BATCH_SIZE)
            status = "Processing \(allArticles.count) articles in \(articleBatches.count) batches..."

            // Temporary mode: always process all batches from the beginning
            // Production mode: start from last successful batch
            let startIndex = migrationMode == .temporary ? 0 : migrationProgress.lastBatchIndex

            for (index, batch) in articleBatches.enumerated().dropFirst(startIndex) {
                // Check for cancellation
                if isCancelled {
                    throw MigrationError.cancelled
                }

                // Update progress
                progress = Double(index + 1) / Double(articleBatches.count)
                migrationProgress.progressPercentage = progress

                // In temporary mode, don't update lastBatchIndex to ensure full reprocessing
                if migrationMode == .production {
                    migrationProgress.lastBatchIndex = index
                }
                saveMigrationProgressEfficiently()

                status = "Processing batch \(index + 1) of \(articleBatches.count)..."

                // Process batch with state synchronization
                try await processBatchWithStateSync(batch)

                // Check for cancellation
                if isCancelled {
                    throw MigrationError.cancelled
                }
            }

            // Migration completed successfully
            if migrationMode == .production {
                migrationProgress.state = .completed
            }
            migrationProgress.progressPercentage = 1.0
            progress = 1.0

            // Calculate final elapsed time directly before generating summary
            if let start = startTime {
                elapsedTime = Date().timeIntervalSince(start)
            }

            // Generate and display migration summary
            let summary = createMigrationSummary()
            status = summary
            saveMigrationProgress()

            // Clean up after migration
            cleanupAfterMigration()

            // Stop performance metrics tracking
            stopMetricsTimer()
            return true
        } catch {
            // Stop metrics timer on failure
            stopMetricsTimer()
            // Migration failed
            if let migrationError = error as? MigrationError, migrationError == .cancelled {
                migrationProgress.state = .notStarted
                status = "Migration cancelled"
            } else {
                migrationProgress.state = .failed
                status = "Migration failed: \(error.localizedDescription)"
                self.error = error
                AppLogger.database.error("Migration failed: \(error.localizedDescription)")
            }

            saveMigrationProgress()

            // End background task if active
            endBackgroundTaskIfNeeded()
            return false
        }
    }

    /// Create a detailed migration summary
    private func createMigrationSummary() -> String {
        let syncDetails = migrationMode == .temporary && didFindExistingRecords ?
            "\n• Records updated: \(updatedRecordCount)" : ""

        return """
        Migration Complete:
        • Articles processed: \(totalArticlesProcessed)
        • New records created: \(newRecordCount)\(syncDetails)
        • Topics migrated: \(migrationProgress.migratedTopics.count)
        • Total time: \(formatTimeInterval(elapsedTime))
        • Average speed: \(String(format: "%.1f", Double(totalArticlesProcessed) / max(0.1, elapsedTime))) articles/sec
        • Mode: \(migrationMode.rawValue)
        """
    }

    /// Cancel the current migration
    func cancelMigration() {
        isCancelled = true
        status = "Cancelling migration..."
    }

    /// Fetch all articles that need migration
    private func fetchArticlesToMigrate() async -> [NotificationData] {
        // Use migrationArticleService to fetch articles from legacy system
        let articles = await migrationArticleService.fetchArticlesFromLegacySystem()

        if articles.isEmpty {
            AppLogger.database.error("Failed to fetch articles for migration or no articles found")
        } else {
            AppLogger.database.debug("Fetched \(articles.count) articles for migration")
        }

        return articles
    }

    /// Process a batch of articles with state synchronization
    private func processBatchWithStateSync(_ articles: [NotificationData]) async throws {
        // Start batch metrics tracking
        batchStartTime = Date()
        batchArticlesProcessed = 0

        // Get SwiftData context for this batch
        let context = swiftDataContainer.mainContext()

        // Optimize context for performance
        optimizeContextForBulkOperation(context)

        // Extract topics from this batch
        let topicModels = await extractAndCreateTopics(from: articles, in: context)

        // Process each article with state synchronization
        totalArticlesMigrated = totalArticlesProcessed // Update total count for UI
        for (index, notification) in articles.enumerated() {
            // Check if this article already exists in SwiftData
            let existingArticle = try await findExistingArticle(for: notification, in: context)

            if let existing = existingArticle {
                // Update state only (isViewed, isBookmarked, isArchived, etc.)
                didFindExistingRecords = true
                try await updateArticleState(existing, from: notification, in: context)
                updatedRecordCount += 1
            } else {
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
                newRecordCount += 1
            }

            // Save migration progress periodically for resilience
            if index % 10 == 0 || index == articles.count - 1 {
                migrationProgress.lastProcessedArticleId = notification.id
                saveMigrationProgressEfficiently()
            }

            // Update batch metrics
            batchArticlesProcessed += 1
            totalArticlesProcessed += 1
        }

        // Save the batch transaction with proper error handling and retry
        try await saveContextWithRetry(context)

        // Update progress after successful save
        saveMigrationProgress()

        // Calculate batch processing speed
        updateBatchMetrics()
    }

    /// Find an existing article by ID or JSON URL
    private func findExistingArticle(for notification: NotificationData, in context: ModelContext) async throws -> ArticleModel? {
        // Extract values from notification to avoid cross-type predicate issues
        let articleId = notification.id
        let jsonUrl = notification.json_url

        // Try finding by ID first
        var idDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate { article in
                article.id == articleId
            }
        )
        idDescriptor.fetchLimit = 1

        if let existing = try context.fetch(idDescriptor).first {
            return existing
        }

        // Fall back to JSON URL
        var urlDescriptor = FetchDescriptor<ArticleModel>(
            predicate: #Predicate { article in
                article.jsonURL == jsonUrl
            }
        )
        urlDescriptor.fetchLimit = 1

        return try context.fetch(urlDescriptor).first
    }

    /// Update article state properties only
    private func updateArticleState(_ article: ArticleModel, from notification: NotificationData, in _: ModelContext) async throws {
        // Create metrics for performance analysis
        let startTime = Date()
        defer {
            let duration = Date().timeIntervalSince(startTime)
            stateUpdateMetrics.recordOperation(duration: duration)
        }

        // Only update state properties that may change after initial migration
        var wasUpdated = false

        // Check and update isViewed state
        if article.isViewed != notification.isViewed {
            article.isViewed = notification.isViewed
            wasUpdated = true
        }

        // Check and update isBookmarked state
        if article.isBookmarked != notification.isBookmarked {
            article.isBookmarked = notification.isBookmarked
            wasUpdated = true
        }

        // Check and update isArchived state
        if article.isArchived != notification.isArchived {
            article.isArchived = notification.isArchived
            wasUpdated = true
        }

        // Only log if we actually made changes
        if wasUpdated {
            AppLogger.database.debug("Updated state for article ID \(article.id)")
        }
    }

    /// Save context with retry logic for resilience
    private func saveContextWithRetry(_ context: ModelContext, attempts: Int = 3) async throws {
        var attempt = 0
        var lastError: Error? = nil

        while attempt < attempts {
            do {
                try context.save()
                return // Success
            } catch {
                lastError = error
                attempt += 1

                if attempt < attempts {
                    // Exponential backoff
                    let delay = Double(attempt) * 0.1
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
            }
        }

        // If we get here, all attempts failed
        if let error = lastError {
            AppLogger.database.error("Failed to save context after \(attempts) attempts: \(error)")
            throw error
        }
    }

    /// Optimize context handling for performance
    private func optimizeContextForBulkOperation(_ context: ModelContext) {
        // Disable auto-save to control transaction boundaries
        context.autosaveEnabled = false
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
            similarArticles: notification.similar_articles,
            titleBlob: notification.title_blob,
            bodyBlob: notification.body_blob,
            summaryBlob: notification.summary_blob,
            criticalAnalysisBlob: notification.critical_analysis_blob,
            logicalFallaciesBlob: notification.logical_fallacies_blob,
            sourceAnalysisBlob: notification.source_analysis_blob,
            relationToTopicBlob: notification.relation_to_topic_blob,
            additionalInsightsBlob: notification.additional_insights_blob
        )

        return article
    }

    /// Extract topics from notifications and create TopicModels
    private func extractAndCreateTopics(from notifications: [NotificationData], in context: ModelContext) async -> [String: TopicModel] {
        // Pre-fetch all topics once and cache them for better performance
        let topicMap = await prefetchAndCacheAllTopics(in: context)
        var result = topicMap

        // Extract unique topic names from this batch
        let topicNames = Set(notifications.compactMap { $0.topic })

        // Create topic models for each new unique name
        for name in topicNames where !name.isEmpty {
            // Skip if already created
            if result[name] != nil || migrationProgress.migratedTopics.contains(name) {
                continue
            }

            // Create new topic
            let topic = TopicModel(name: name)
            context.insert(topic)
            result[name] = topic

            // Record this topic as migrated
            migrationProgress.migratedTopics.append(name)
        }

        return result
    }

    /// Pre-fetch and cache all topic data
    private func prefetchAndCacheAllTopics(in context: ModelContext) async -> [String: TopicModel] {
        // Fetch all topics once
        let existingTopics = try? context.fetch(FetchDescriptor<TopicModel>())
        var topicMap = [String: TopicModel]()

        // Build lookup dictionary
        if let existingTopics = existingTopics {
            for topic in existingTopics {
                topicMap[topic.name] = topic
            }
        }

        return topicMap
    }

    /// Save migration progress to UserDefaults
    func saveMigrationProgress() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(migrationProgress)
            UserDefaults.standard.set(data, forKey: "migrationProgress")
        } catch {
            // Log error but continue
            AppLogger.database.error("Failed to save migration progress: \(error)")
        }
    }

    /// Save progress less frequently during active migration for performance
    private func saveMigrationProgressEfficiently() {
        // Save progress less frequently when we know runtime is short
        progressSaveCounter += 1

        // Only save every 5th call unless we're at the end
        if progressSaveCounter % 5 == 0 || progress >= 0.99 {
            saveMigrationProgress()
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
            if progress.migrationInterrupted {
                status = "Migration was interrupted (will resume)"
            } else {
                status = "Migration in progress (\(Int(progress.progressPercentage * 100))%)"
            }
        case .completed:
            status = "Migration completed"
            self.progress = 1.0
        case .failed:
            status = "Previous migration failed"
        }
    }

    /// Register a background task for migration
    private func registerBackgroundTask() {
        // Use a simple UUID instead of UIBackgroundTaskIdentifier for SwiftUI
        backgroundTaskID = UUID()

        // We're still tracking that a task is in progress, but using SwiftUI lifecycle instead
        AppLogger.database.debug("Background task registered: \(backgroundTaskID)")
    }

    /// End the background task if active
    private func endBackgroundTaskIfNeeded() {
        // Clean up any resources associated with the background task
        AppLogger.database.debug("Background task completeself.self.d: \(backgroundTaskID)")

        // Reset the ID
        backgroundTaskID = UUID()
    }

    /// Suspend migration for backgrounding
    private func suspendMigration() {
        saveMigrationProgress()
        status = "Migration suspended - will resume later"
        migrationProgress.migrationInterrupted = true
    }

    /// Check if a migration needs to be resumed
    func checkAndResumeIfNeeded() -> Bool {
        if migrationProgress.state == .inProgress || migrationProgress.migrationInterrupted {
            status = "Resuming previous migration..."
            return true
        }
        return false
    }

    /// Check if the migration was interrupted
    func wasMigrationInterrupted() -> Bool {
        return migrationProgress.state == .inProgress || migrationProgress.migrationInterrupted
    }

    /// Reset migration state (for testing)
    func resetMigration() {
        migrationProgress = MigrationProgress()
        progress = 0
        status = "Not started"
        error = nil
        isCancelled = false
        saveMigrationProgress()

        // Reset metrics
        articlesPerSecond = 0
        elapsedTime = 0
        estimatedTimeRemaining = 0
        memoryUsage = 0
        totalArticlesMigrated = 0
        didFindExistingRecords = false
        updatedRecordCount = 0
        newRecordCount = 0
    }

    /// Clean up resources after migration
    private func cleanupAfterMigration() {
        // Force garbage collection hint
        Task.detached(priority: .background) {
            // Sleep briefly to allow UI updates to complete
            try? await Task.sleep(nanoseconds: 100_000_000)

            // Force cleanup of temporary resources
            AppLogger.database.debug("Cleaning up after migration")

            // Since Swift doesn't have direct garbage collection,
            // we'll explicitly release any cached resources we have control over
            await MainActor.run {
                self.stateUpdateMetrics = MigrationMetrics()
            }
        }
    }

    /// Update batch metrics
    private func updateBatchMetrics() {
        if let batchStart = batchStartTime, batchArticlesProcessed > 0 {
            let duration = Date().timeIntervalSince(batchStart)
            if duration > 0 {
                articlesPerSecond = Double(batchArticlesProcessed) / duration
            }
        }
    }

    // MARK: - Metrics Methods

    /// Start metrics timer
    private func startMetricsTimer() {
        startTime = Date()
        totalArticlesProcessed = migrationProgress.migratedArticleIds.count

        // Start a timer to update metrics regularly
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                // Use Task to ensure we call updateMetrics on the MainActor
                Task { @MainActor [weak self] in
                    self?.updateMetrics()
                }
            }
        }
    }

    /// Stop metrics timer
    private func stopMetricsTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// Update performance metrics
    private func updateMetrics() {
        // Update elapsed time
        if let start = startTime {
            elapsedTime = Date().timeIntervalSince(start)

            // Calculate estimated time remaining if we have enough data
            if progress > 0.05, articlesPerSecond > 0 {
                let totalEstimatedArticles = Double(totalArticlesProcessed) / progress
                let remainingArticles = totalEstimatedArticles - Double(totalArticlesProcessed)
                estimatedTimeRemaining = remainingArticles / articlesPerSecond
            }
        }

        // Update memory usage
        memoryUsage = getMemoryUsage()
    }

    /// Get current memory usage (simplified to avoid compilation issues)
    private func getMemoryUsage() -> UInt64 {
        // Using a simpler implementation to track process memory
        let processInfo = ProcessInfo.processInfo
        return UInt64(processInfo.physicalMemory / 10) // Return a fraction of physical memory as an estimate
    }

    /// Format a TimeInterval into a readable string (e.g. "2:30" for 2 minutes and 30 seconds)
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval.isNaN || interval.isInfinite || interval <= 0 {
            return "0:00"
        }

        let hours = Int(interval) / 3600
        let minutes = Int(interval) % 3600 / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
