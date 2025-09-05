import Combine
import Foundation
import SwiftData
import SwiftUI

/// ViewModel for the NewsView that manages article listing, filtering, and operations
@MainActor
final class NewsViewModel: ObservableObject {
    // MARK: - Subscriptions for Settings Changes

    /// Subscriptions for observing UserDefaults changes
    private var userDefaultsSubscriptions = Set<AnyCancellable>()

    // MARK: - Published Properties

    /// Articles currently displayed in the view
    @Published var filteredArticles: [ArticleModel] = []

    /// All articles loaded from the database (may be more than what's displayed)
    @Published var allArticles: [ArticleModel] = []

    /// Grouped articles for display in sections
    @Published var groupedArticles: [(key: String, articles: [ArticleModel])] = []

    /// Set of selected article IDs when in edit mode
    @Published var selectedArticleIds: Set<UUID> = []

    /// Flag indicating if articles are currently being loaded
    @Published var isLoading = false

    /// Error that occurred during article operations
    @Published var error: Error?

    /// Flag indicating if more content is available for pagination
    @Published var hasMoreContent = true

    /// Flag indicating if loading more pages is in progress
    @Published var isLoadingMorePages = false

    /// Current sync status (for the indicator)
    @Published var syncStatus: SyncStatus = .idle

    /// Flag indicating if a sync operation is currently in progress
    var isSyncing: Bool {
        switch syncStatus {
        case .idle, .complete: return false  // UI responsive when idle or complete
        case .searching, .syncing, .error: return true
        }
    }

    // MARK: - Filter State

    /// The currently selected topic
    @Published var selectedTopic: String = "All"

    /// Flag indicating if only unread articles should be shown
    @Published var showUnreadOnly: Bool = false

    /// Flag indicating if only bookmarked articles should be shown
    @Published var showBookmarkedOnly: Bool = false

    /// The current sort order
    @Published var sortOrder: String = "newest"

    /// The current grouping style
    @Published var groupingStyle: String = "none"

    /// The current quality filter
    @Published var qualityFilter: String = "All"

    // MARK: - Pagination State

    /// The page size for pagination - optimized for large datasets with 1,000+ articles
    var pageSize: Int = 100

    /// The last loaded date for pagination
    var lastLoadedDate: Date?

    /// Flag indicating if an update is needed but pending due to active scrolling
    var pendingUpdateNeeded = false

    /// Timestamp of the most recent filter change
    private var lastFilterChangeTime = Date.distantPast

    /// Task that handles debounced filter updates
    private var filterChangeDebouncer: Task<Void, Never>?

    /// Cache of articles by topic for quick topic switching with metadata
    private var articleCache: [String: CachedArticles] = [:]
    
    /// Timestamp of the last cache update
    private var lastCacheUpdate = Date.distantPast
    
    /// Flag indicating if the cache is valid
    private var isCacheValid = false
    
    /// Track topic access for predictive loading
    private var topicAccessPatterns: [String: Date] = [:]
    
    /// Cache entry structure with metadata for smart invalidation
    private struct CachedArticles {
        let articles: [ArticleModel]
        let timestamp: Date
        let filters: CacheFilters
        let accessCount: Int
        let lastAccessTime: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300 // 5 minutes
        }
        
        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > 120 // 2 minutes - refresh in background
        }
        
        var accessFrequency: Double {
            let timeSinceCreation = max(Date().timeIntervalSince(timestamp), 1)
            return Double(accessCount) / timeSinceCreation
        }
    }
    
    /// Filter combination for cache validation
    private struct CacheFilters: Hashable {
        let showUnreadOnly: Bool
        let showBookmarkedOnly: Bool
        let qualityFilter: String
        let sortOrder: String
        let groupingStyle: String
    }
    
    /// Cache performance metrics for monitoring
    private struct CacheMetrics {
        var hitCount: Int = 0
        var missCount: Int = 0
        var totalRequests: Int = 0
        var backgroundWarmedTopics: Set<String> = []
        var lastMetricsReset: Date = Date()
        
        var hitRate: Double {
            guard totalRequests > 0 else { return 0.0 }
            return Double(hitCount) / Double(totalRequests)
        }
        
        mutating func recordHit() {
            hitCount += 1
            totalRequests += 1
        }
        
        mutating func recordMiss() {
            missCount += 1
            totalRequests += 1
        }
        
        mutating func reset() {
            hitCount = 0
            missCount = 0
            totalRequests = 0
            backgroundWarmedTopics.removeAll()
            lastMetricsReset = Date()
        }
    }
    
    /// Cache metrics instance for performance monitoring
    private var cacheMetrics = CacheMetrics()

    // MARK: - Phase 2.1: Rich Text Cache for Article Opening Performance
    
    /// Rich text content cache for immediate article opening
    private var richTextCache: [UUID: RichTextCacheEntry] = [:]
    
    /// Rich text cache entry with timestamp for expiration
    struct RichTextCacheEntry {
        let title: NSAttributedString?
        let body: NSAttributedString?
        let summary: NSAttributedString?
        let timestamp: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 600 // 10 minutes
        }
    }

    // MARK: - Dependencies

    /// Operations service for article business logic
    private let articleOperations: ArticleOperations

    /// Subscription dictionary for topic filtering
    private var _subscriptions: [String: Subscription] = [:]

    /// Public accessor for subscriptions
    var subscriptions: [String: Subscription] { _subscriptions }

    // MARK: - Initialization

    /// Initializes a new NewsViewModel
    /// - Parameter articleOperations: The article operations service to use
    init(articleOperations: ArticleOperations = ArticleOperations()) {
        self.articleOperations = articleOperations

        // Load initial values from UserDefaults
        loadUserPreferences()

        // Load subscriptions
        loadSubscriptions()

        // Setup observers for settings changes
        setupUserDefaultsObservers()

        // Add observer for background sync completion
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundSyncCompleted),
            name: Notification.Name.articleProcessingCompleted,
            object: nil
        )

    }

    /// Handler for background sync completion notification
    @objc private func handleBackgroundSyncCompleted() {
        Task {
            await refreshAfterBackgroundSync()
        }
    }

    deinit {
        // Clean up subscriptions
        userDefaultsSubscriptions.forEach { $0.cancel() }
        userDefaultsSubscriptions.removeAll()
    }

    // MARK: - Public Methods - Data Loading

    /// Refreshes articles based on current filters
    func refreshArticles() async {
        // Cancel any pending debounced update
        filterChangeDebouncer?.cancel()

        // Set loading state
        isLoading = true
        error = nil

        do {
            // First, fetch articles with non-topic filters only (for all visible topics)
            let allArticlesWithoutTopicFilter = try await articleOperations.fetchArticles(
                topic: "All", // This fetches articles for all topics
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                qualityFilter: qualityFilter
            )

            // Update allArticles for topic bar generation
            allArticles = allArticlesWithoutTopicFilter

            // If a specific topic is selected, fetch articles with that topic filter
            if selectedTopic != "All" {
                // Fetch articles with the selected topic AND quality filter
                let topicFilteredArticles = try await articleOperations.fetchArticles(
                    topic: selectedTopic,
                    showUnreadOnly: showUnreadOnly,
                    showBookmarkedOnly: showBookmarkedOnly,
                    qualityFilter: qualityFilter
                )

                // Update filteredArticles with the topic-filtered articles
                filteredArticles = topicFilteredArticles
            } else {
                // If "All" is selected, use the same articles for both
                filteredArticles = allArticlesWithoutTopicFilter
            }

            // Update grouping using filtered articles
            await updateGroupedArticles()

            // Update cache
            updateArticleCache(filteredArticles)

            // Reset pagination state
            lastLoadedDate = filteredArticles.last?.publishDate
            hasMoreContent = filteredArticles.count >= pageSize

            // Clear loading state
            isLoading = false

        } catch {
            self.error = error
            isLoading = false
            AppLogger.database.error("Error refreshing articles: \(error)")
        }
    }

    /// Refreshes articles and performs auto-redirect if the current topic has no content
    @MainActor
    func refreshWithAutoRedirectIfNeeded() async {
        // First do the normal refresh
        await refreshArticles()

        // Then check if we need to redirect
        if filteredArticles.isEmpty, selectedTopic != "All" {

            // Revert to "All" topic
            selectedTopic = "All"

            // Save the preference
            saveUserPreferences()

            // Refresh with "All" topics
            await refreshArticles()
        }
    }

    /// Refreshes the view after background sync completes
    @MainActor
    func refreshAfterBackgroundSync() async {
        // Refresh with current filters
        await refreshArticles()

        // Check for empty topic and auto-redirect if needed
        if filteredArticles.isEmpty, selectedTopic != "All" {
            selectedTopic = "All"
            saveUserPreferences()
            await refreshArticles()
        }

        // Check for new topics that might have appeared
        // and update the topic bar
        do {
            allArticles = try await articleOperations.fetchArticles(
                topic: "All",
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                qualityFilter: qualityFilter
            )
        } catch {
            AppLogger.database.error("Error loading articles: \(error)")
            // Keep existing articles if fetch fails
        }
    }

    /// Loads more articles for pagination
    func loadMoreArticles() async {
        guard hasMoreContent, !isLoadingMorePages else { return }

        isLoadingMorePages = true

        do {
            // Only fetch if we have a reference date for pagination
            guard lastLoadedDate != nil else {
                isLoadingMorePages = false
                return
            }

            // For pagination, we need to use a more complex approach
            // NOTE: Complex date filtering with predicates is causing compiler issues
            // so we're using a simpler approach for now

            // Fetch the next batch of articles with the existing method
            let nextPageArticles = try await articleOperations.fetchArticles(
                topic: selectedTopic,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                qualityFilter: qualityFilter,
                limit: pageSize
            )

            // Filter out any articles that we already have
            let filteredNextPageArticles = nextPageArticles.filter { article in
                !filteredArticles.contains { $0.id == article.id }
            }

            // If we got results, append them
            if !filteredNextPageArticles.isEmpty {
                // Update all articles
                allArticles.append(contentsOf: filteredNextPageArticles)

                // Update filtered articles
                filteredArticles.append(contentsOf: filteredNextPageArticles)

                // Update last loaded date
                lastLoadedDate = nextPageArticles.last?.publishDate

                // Update grouping
                await updateGroupedArticles()
            }

            // Update pagination state
            hasMoreContent = nextPageArticles.count >= pageSize
            isLoadingMorePages = false

        } catch {
            isLoadingMorePages = false
            self.error = error
            AppLogger.database.error("Error loading more articles: \(error)")
        }
    }

    /// Performs a sync with the server for updated content using the global sync coordinator
    func syncWithServer() async {
        // Use global sync coordinator to prevent race conditions
        do {
            // Set initial status
            syncStatus = .searching
            isLoading = true
            error = nil

            let addedCount = try await GlobalSyncCoordinator.shared.requestManualSync(
                topic: selectedTopic != "All" ? selectedTopic : nil
            ) { message in
                Task { @MainActor in
                    self.syncStatus = .syncing(message: message)
                }
            }

            // If we got new articles, refresh the view
            if addedCount > 0 {
                await refreshArticles()
            }

            // Set status to complete
            syncStatus = .complete
            isLoading = false

            // Schedule a task to reset to idle after a delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                if case .complete = syncStatus {
                    syncStatus = .idle
                }
            }

        } catch {
            // Set error status
            syncStatus = .error(error.localizedDescription)
            isLoading = false
            self.error = error
            AppLogger.database.error("Error syncing with server: \(error)")

            // Schedule a task to reset to idle after a delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                if case .error = syncStatus {
                    syncStatus = .idle
                }
            }
        }
    }

    // MARK: - Public Methods - Filter Operations

    /// Applies a new topic filter with smart caching and predictive loading
    /// - Parameter topic: The topic to filter by
    func applyTopicFilter(_ topic: String) async {
        let previousTopic = selectedTopic
        
        // Update the topic filter
        selectedTopic = topic

        // Track topic access for predictive loading
        topicAccessPatterns[topic] = Date()


        // Try to use cache for immediate response
        if tryLoadFromCache(topic: topic) {
            // Still refresh in the background to ensure up-to-date data
            await refreshArticles()
        } else {
            // If cache miss, do a full refresh
            await refreshArticles()
        }

        // Trigger predictive loading for adjacent topics
        await predictiveLoadAdjacentTopics(currentTopic: topic, previousTopic: previousTopic)

        // Auto-redirect to "All" if no content is available for the selected topic
        if filteredArticles.isEmpty, topic != "All" {
            AppLogger.database.debug("No content for topic '\(topic)', auto-redirecting to 'All'")

            // Revert to "All" topic
            selectedTopic = "All"

            // Save the preference
            saveUserPreferences()

            // Refresh with "All" topics
            await refreshArticles()
        }
    }
    
    /// Predictive loading for adjacent topics based on access patterns
    private func predictiveLoadAdjacentTopics(currentTopic: String, previousTopic: String?) async {
        // Get all available topics from our subscriptions
        let allTopics = Array(_subscriptions.keys).sorted()
        
        guard !allTopics.isEmpty else { return }
        
        // Use ArticleOperations background preloading with a background context
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self = self else { return }
                
                // Create a background context for preloading
                let container = SwiftDataContainer.shared.container
                let backgroundContext = ModelContext(container)
                
                await ArticleOperations.preloadAdjacentTopics(
                    currentTopic: currentTopic,
                    allTopics: allTopics,
                    showUnreadOnly: self.showUnreadOnly,
                    qualityFilter: self.qualityFilter,
                    context: backgroundContext
                )
            }
        }
    }

    /// Applies filters for read status and bookmarked status
    /// - Parameters:
    ///   - showUnreadOnly: Whether to show only unread articles
    ///   - showBookmarkedOnly: Whether to show only bookmarked articles
    func applyFilters(
        showUnreadOnly: Bool? = nil,
        showBookmarkedOnly: Bool? = nil
    ) async {
        // Update filter values if provided
        if let showUnreadOnly = showUnreadOnly {
            self.showUnreadOnly = showUnreadOnly
        }

        if let showBookmarkedOnly = showBookmarkedOnly {
            self.showBookmarkedOnly = showBookmarkedOnly
        }

        // Save filter preferences
        saveUserPreferences()

        // Refresh articles with new filters
        await refreshArticles()
    }

    /// Applies a new sort order
    /// - Parameter sortOrder: The sort order to apply
    func applySortOrder(_ sortOrder: String) async {
        self.sortOrder = sortOrder

        // Save preference
        saveUserPreferences()

        // Update grouping without re-fetching
        await updateGroupedArticles()
    }

    /// Applies a new grouping style
    /// - Parameter groupingStyle: The grouping style to apply
    func applyGroupingStyle(_ groupingStyle: String) async {
        self.groupingStyle = groupingStyle

        // Save preference
        saveUserPreferences()

        // Update grouping without re-fetching
        await updateGroupedArticles()
    }

    /// Applies a new quality filter with smart cache invalidation
    /// - Parameter qualityFilter: The quality filter to apply
    func applyQualityFilter(_ qualityFilter: String) async {
        AppLogger.database.debug("🔄 Applying quality filter: \(qualityFilter)")
        
        self.qualityFilter = qualityFilter

        // Save preference
        saveUserPreferences()

        // Smart cache invalidation - only clear entries that don't match new filter
        invalidateCacheForFilterChange()

        // Refresh articles with new quality filter
        await refreshArticles()
        
        AppLogger.database.debug("✅ Quality filter applied: \(qualityFilter) - Filtered articles: \(self.filteredArticles.count)")
        
        // Update badge count after quality filter change
        NotificationUtils.updateAppBadgeCount()
    }
    
    /// Smart cache invalidation - only invalidates affected cache entries
    private func invalidateCacheForFilterChange() {
        let currentFilters = CacheFilters(
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter,
            sortOrder: sortOrder,
            groupingStyle: groupingStyle
        )
        
        // Remove only cache entries that don't match current filters
        self.articleCache = self.articleCache.compactMapValues { cachedEntry in
            if cachedEntry.filters == currentFilters && !cachedEntry.isExpired {
                return cachedEntry // Keep valid cache entry
            }
            return nil // Remove invalid cache entry
        }
        
        // Update cache validity
        isCacheValid = !articleCache.isEmpty
        
        AppLogger.database.debug("Smart cache invalidation: kept \(self.articleCache.count) valid entries")
    }
    
    /// Get cache statistics for performance monitoring
    func getCacheStatistics() -> (hitRate: Double, entries: Int, oldestEntry: Date?) {
        let totalEntries = articleCache.count
        let oldestEntry = self.articleCache.values.map(\.timestamp).min()
        
        // Calculate approximate hit rate based on recent access patterns
        let recentAccesses = topicAccessPatterns.count
        let hitRate = totalEntries > 0 && recentAccesses > 0 
            ? min(1.0, Double(totalEntries) / Double(recentAccesses))
            : 0.0
        
        return (hitRate: hitRate, entries: totalEntries, oldestEntry: oldestEntry)
    }
    
    /// Get memory usage statistics for performance monitoring
    func getMemoryUsageStatistics() -> (memoryUsage: Double, cacheMemoryMB: Double, articlesInMemory: Int) {
        // Get current memory usage
        let memoryUsage = getCurrentMemoryUsage()
        
        // Estimate cache memory usage
        let cacheMemoryMB = estimateCacheMemoryUsage()
        
        // Count articles currently held in memory
        let articlesInMemory = filteredArticles.count + allArticles.count
        
        return (memoryUsage: memoryUsage, cacheMemoryMB: cacheMemoryMB, articlesInMemory: articlesInMemory)
    }
    
    /// Get current memory usage in MB
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0 // Convert to MB
        }
        
        return 0.0
    }
    
    /// Estimate cache memory usage in MB
    private func estimateCacheMemoryUsage() -> Double {
        let articlesPerEntry = articleCache.values.map { $0.articles.count }.reduce(0, +)
        // Rough estimate: each article ~2KB in memory
        let estimatedCacheSize = Double(articlesPerEntry) * 2.0 / 1024.0 // Convert to MB
        return estimatedCacheSize
    }

    // MARK: - Public Methods - Article Operations

    /// Toggles the read status of an article
    /// - Parameter article: The article to toggle
    func toggleReadStatus(for article: ArticleModel) async {
        do {
            // Use shared operation
            try await articleOperations.toggleReadStatus(for: article)

            // If unread filter is active, we might need to refresh
            if showUnreadOnly {
                await refreshArticles()
            } else {
                // Just update grouping
                await updateGroupedArticles()
            }

            AppLogger.database.debug("✅ Toggled read status for article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error toggling read status: \(error)")
        }
    }

    /// Toggles the bookmarked status of an article
    /// - Parameter article: The article to toggle
    func toggleBookmark(for article: ArticleModel) async {
        do {
            // Use shared operation
            try await articleOperations.toggleBookmark(for: article)

            // If bookmarked filter is active, we might need to refresh
            if showBookmarkedOnly {
                await refreshArticles()
            } else {
                // Just update grouping
                await updateGroupedArticles()
            }

            AppLogger.database.debug("✅ Toggled bookmark status for article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error toggling bookmark status: \(error)")
        }
    }

    /// Deletes an article
    /// - Parameter article: The article to delete
    func deleteArticle(_ article: ArticleModel) async {
        do {
            // Use shared operation
            try await articleOperations.deleteArticle(article)

            // Refresh the article list
            await refreshArticles()

            AppLogger.database.debug("✅ Deleted article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error deleting article: \(error)")
        }
    }

    // MARK: - Public Methods - Batch Operations

    /// Performs operations on selected articles in edit mode
    /// - Parameter operation: The operation to perform
    func performBatchOperation(_ operation: BatchOperation) async {
        guard !selectedArticleIds.isEmpty else { return }

        switch operation {
        case .markAsRead:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asRead: true)
        case .markAsUnread:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asRead: false)
        case .bookmark:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asBookmarked: true)
        case .unbookmark:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asBookmarked: false)
        case .delete:
            _ = await articleOperations.deleteArticles(ids: Array(selectedArticleIds))
        }

        // Clear selection
        selectedArticleIds.removeAll()

        // Refresh articles
        await refreshArticles()
    }

    /// Possible batch operations for selected articles
    enum BatchOperation {
        case markAsRead
        case markAsUnread
        case bookmark
        case unbookmark
        case delete
    }

    // MARK: - Private Methods

    /// Updates the groupedArticles array without re-fetching from the database
    /// - Note: This method is explicitly marked as MainActor-isolated to handle non-Sendable ArticleModel results
    @MainActor
    private func updateGroupedArticles() async {
        // Since we're explicitly on the MainActor, we can safely handle the non-Sendable result
        // containing ArticleModel objects which are not Sendable in Swift 6
        groupedArticles = await articleOperations.groupArticles(
            filteredArticles,
            by: groupingStyle,
            sortOrder: sortOrder
        )
    }

    /// Tries to load articles from cache for immediate response with enhanced metrics and stale-while-revalidate
    /// - Parameter topic: The topic to load
    /// - Returns: Whether articles were loaded from cache
    private func tryLoadFromCache(topic: String) -> Bool {
        let currentFilters = CacheFilters(
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter,
            sortOrder: sortOrder,
            groupingStyle: groupingStyle
        )
        
        // Check if cache entry exists and is valid
        if let cachedEntry = articleCache[topic],
           !cachedEntry.isExpired,
           cachedEntry.filters == currentFilters {
            
            // Record cache hit
            cacheMetrics.recordHit()
            
            // Update access tracking for this cache entry
            let updatedEntry = CachedArticles(
                articles: cachedEntry.articles,
                timestamp: cachedEntry.timestamp,
                filters: cachedEntry.filters,
                accessCount: cachedEntry.accessCount + 1,
                lastAccessTime: Date()
            )
            articleCache[topic] = updatedEntry
            
            filteredArticles = cachedEntry.articles
            
            // Create task to update grouping based on cached articles
            Task {
                await updateGroupedArticles()
            }
            
            // If cache is stale but not expired, schedule background refresh
            if cachedEntry.isStale {
                Task.detached(priority: .background) { [weak self] in
                    await self?.refreshArticlesInBackground(for: topic, filters: currentFilters)
                }
                AppLogger.database.debug("Cache hit with background refresh for stale topic: \(topic)")
            } else {
                AppLogger.database.debug("Fresh cache hit for topic: \(topic)")
            }
            
            return true
        }
        
        // Record cache miss
        cacheMetrics.recordMiss()
        
        let expiredStatus = articleCache[topic]?.isExpired ?? true
        let filtersMatch = articleCache[topic]?.filters == currentFilters
        AppLogger.database.debug("Cache miss for topic: \(topic) - expired: \(expiredStatus), filters match: \(filtersMatch)")
        
        return false
    }
    
    /// Background refresh for stale cache entries (stale-while-revalidate pattern)
    private func refreshArticlesInBackground(for topic: String, filters: CacheFilters) async {
        do {
            let backgroundArticles = try await articleOperations.fetchArticles(
                topic: topic == "All" ? nil : topic,
                showUnreadOnly: filters.showUnreadOnly,
                showBookmarkedOnly: filters.showBookmarkedOnly,
                qualityFilter: filters.qualityFilter
            )
            
            // Update cache with fresh data
            await MainActor.run {
                let freshEntry = CachedArticles(
                    articles: backgroundArticles,
                    timestamp: Date(),
                    filters: filters,
                    accessCount: articleCache[topic]?.accessCount ?? 1,
                    lastAccessTime: Date()
                )
                articleCache[topic] = freshEntry
                
                AppLogger.database.debug("Background refresh completed for topic: \(topic) - \(backgroundArticles.count) articles")
            }
        } catch {
            AppLogger.database.warning("Background refresh failed for topic: \(topic) - \(error)")
        }
    }

    /// Updates the article cache with new articles using smart caching with enhanced metadata
    /// - Parameter articles: The articles to cache
    private func updateArticleCache(_ articles: [ArticleModel]) {
        let currentFilters = CacheFilters(
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter,
            sortOrder: sortOrder,
            groupingStyle: groupingStyle
        )
        
        let now = Date()
        
        // Create cache entry with enhanced metadata - preserve access count if updating existing entry
        let existingAccessCount = articleCache[selectedTopic]?.accessCount ?? 0
        let cachedEntry = CachedArticles(
            articles: articles,
            timestamp: now,
            filters: currentFilters,
            accessCount: max(1, existingAccessCount), // Ensure at least 1 access
            lastAccessTime: now
        )
        
        // Update cache for current topic
        articleCache[selectedTopic] = cachedEntry

        // Update "All" cache if we're not already in "All"
        if selectedTopic != "All" {
            // We now want to preserve the "All" entries in the cache for topic bar generation
            // If allArticles is populated, use it to update the "All" cache
            if !allArticles.isEmpty {
                let existingAllAccessCount = articleCache["All"]?.accessCount ?? 0
                let allTopicsEntry = CachedArticles(
                    articles: allArticles,
                    timestamp: now,
                    filters: currentFilters,
                    accessCount: max(1, existingAllAccessCount),
                    lastAccessTime: now
                )
                articleCache["All"] = allTopicsEntry
            }
        }

        lastCacheUpdate = now
        isCacheValid = true
        
        // Perform memory-aware cache cleanup with frequency-based prioritization
        performIntelligentCacheCleanup()
    }
    
    /// Intelligent cache cleanup with frequency-based prioritization and memory awareness
    private func performIntelligentCacheCleanup() {
        let maxCacheEntries = 12 // Slightly higher limit for intelligent cleanup
        let memoryPressureThreshold = 80.0 // MB
        
        guard articleCache.count > maxCacheEntries else { return }
        
        let currentMemory = estimateCacheMemoryUsage()
        let isMemoryPressure = currentMemory > memoryPressureThreshold
        
        // Calculate cleanup priority: higher score = keep longer
        let scoredEntries = articleCache.map { (topic, entry) in
            var score = 0.0
            
            // Recency score (0-1, newer is better)
            let ageInMinutes = Date().timeIntervalSince(entry.timestamp) / 60.0
            let recencyScore = max(0, 1 - (ageInMinutes / 30.0)) // Decay over 30 minutes
            
            // Access frequency score (normalized)
            let frequencyScore = min(1.0, entry.accessFrequency * 10.0) // Scale frequency
            
            // Special topics score ("All" is always important)
            let specialScore = (topic == "All") ? 0.5 : 0.0
            
            // Recent access score
            let lastAccessAge = Date().timeIntervalSince(entry.lastAccessTime) / 60.0
            let accessRecencyScore = max(0, 1 - (lastAccessAge / 15.0)) // Decay over 15 minutes
            
            // Combine scores with weights
            score = (recencyScore * 0.3) + (frequencyScore * 0.3) + (specialScore * 0.2) + (accessRecencyScore * 0.2)
            
            return (topic: topic, entry: entry, score: score)
        }
        
        // Sort by score descending (keep highest scoring entries)
        let sortedByScore = scoredEntries.sorted { $0.score > $1.score }
        
        // Determine how many entries to keep based on memory pressure
        let targetCount = isMemoryPressure ? max(6, maxCacheEntries / 2) : maxCacheEntries
        let entriesToKeep = sortedByScore.prefix(targetCount)
        
        // Update cache
        let newCache = Dictionary(uniqueKeysWithValues: entriesToKeep.map { ($0.topic, $0.entry) })
        let removedCount = articleCache.count - newCache.count
        
        self.articleCache = newCache
        
        AppLogger.database.debug("Intelligent cache cleanup: removed \(removedCount) entries, keeping \(self.articleCache.count) (memory pressure: \(isMemoryPressure))")
    }
    
    /// Get comprehensive cache performance statistics for monitoring and optimization
    func getComprehensiveCacheStatistics() -> (
        hitRate: Double, 
        totalRequests: Int,
        entries: Int, 
        memoryUsageMB: Double,
        oldestEntry: Date?,
        averageAccessCount: Double,
        staleEntries: Int,
        topTopics: [(topic: String, accessCount: Int, lastAccess: Date)]
    ) {
        let totalEntries = articleCache.count
        let memoryUsage = estimateCacheMemoryUsage()
        let oldestEntry = articleCache.values.map(\.timestamp).min()
        
        // Calculate average access count
        let totalAccess = articleCache.values.map(\.accessCount).reduce(0, +)
        let averageAccessCount = totalEntries > 0 ? Double(totalAccess) / Double(totalEntries) : 0.0
        
        // Count stale entries
        let staleEntries = articleCache.values.filter(\.isStale).count
        
        // Get top accessed topics
        let topTopics = articleCache
            .map { (topic: $0.key, accessCount: $0.value.accessCount, lastAccess: $0.value.lastAccessTime) }
            .sorted { $0.accessCount > $1.accessCount }
            .prefix(5)
            .map { $0 }
        
        return (
            hitRate: cacheMetrics.hitRate,
            totalRequests: cacheMetrics.totalRequests,
            entries: totalEntries,
            memoryUsageMB: memoryUsage,
            oldestEntry: oldestEntry,
            averageAccessCount: averageAccessCount,
            staleEntries: staleEntries,
            topTopics: Array(topTopics)
        )
    }
    
    /// Reset cache metrics for fresh performance monitoring period
    func resetCacheMetrics() {
        cacheMetrics.reset()
        AppLogger.database.debug("Cache metrics reset")
    }
    
    /// Get detailed cache report for performance analysis
    func getCachePerformanceReport() -> String {
        let stats = getComprehensiveCacheStatistics()
        let memoryStats = getMemoryUsageStatistics()
        
        let report = """
        📊 Cache Performance Report
        
        🎯 Hit Rate: \(String(format: "%.1f", stats.hitRate * 100))%
        📈 Total Requests: \(stats.totalRequests)
        🗂️ Cache Entries: \(stats.entries)
        💾 Cache Memory: \(String(format: "%.1f", stats.memoryUsageMB)) MB
        📅 Oldest Entry: \(stats.oldestEntry?.formatted(date: .abbreviated, time: .shortened) ?? "None")
        🔄 Average Accesses: \(String(format: "%.1f", stats.averageAccessCount))
        ⏰ Stale Entries: \(stats.staleEntries)
        
        💻 Total Memory: \(String(format: "%.1f", memoryStats.memoryUsage)) MB
        📄 Articles in Memory: \(memoryStats.articlesInMemory)
        
        🏆 Top Topics:
        \(stats.topTopics.prefix(3).map { "   • \($0.topic): \($0.accessCount) accesses" }.joined(separator: "\n"))
        
        📈 Performance Metrics:
        • Cache Efficiency: \(stats.hitRate > 0.7 ? "Excellent" : stats.hitRate > 0.5 ? "Good" : "Needs Improvement")
        • Memory Usage: \(stats.memoryUsageMB < 50 ? "Optimal" : stats.memoryUsageMB < 100 ? "Acceptable" : "High")
        • Staleness: \(stats.staleEntries == 0 ? "All Fresh" : "\(stats.staleEntries) stale entries")
        """
        
        return report
    }

    /// Loads subscriptions for topic filtering
    private func loadSubscriptions() {
        _subscriptions = SubscriptionsView().loadSubscriptions()
    }

    /// Loads user preferences from UserDefaults
    private func loadUserPreferences() {
        // Use our standardized UserDefaults extensions
        let defaults = UserDefaults.standard
        showUnreadOnly = defaults.showUnreadOnly
        showBookmarkedOnly = defaults.showBookmarkedOnly
        sortOrder = defaults.sortOrder
        groupingStyle = defaults.groupingStyle // Now uses "date" as default
        selectedTopic = defaults.selectedTopic
        qualityFilter = defaults.qualityFilter
    }

    /// Sets up observers for UserDefaults changes
    private func setupUserDefaultsObservers() {
        let defaults = UserDefaults.standard

        // Observe sortOrder changes
        defaults.publisher(for: \.sortOrder)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { [weak self] newValue in
                guard let self = self, self.sortOrder != newValue else { return }

                Task { @MainActor in
                    self.sortOrder = newValue
                    await self.updateGroupedArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)

        // Observe groupingStyle changes
        defaults.publisher(for: \.groupingStyle)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { [weak self] newValue in
                guard let self = self, self.groupingStyle != newValue else { return }

                Task { @MainActor in
                    self.groupingStyle = newValue
                    await self.updateGroupedArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)

        // Observe showUnreadOnly changes
        defaults.publisher(for: \.showUnreadOnly)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { [weak self] newValue in
                guard let self = self, self.showUnreadOnly != newValue else { return }

                Task { @MainActor in
                    self.showUnreadOnly = newValue
                    await self.refreshArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)

        // Observe showBookmarkedOnly changes
        defaults.publisher(for: \.showBookmarkedOnly)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { [weak self] newValue in
                guard let self = self, self.showBookmarkedOnly != newValue else { return }

                Task { @MainActor in
                    self.showBookmarkedOnly = newValue
                    await self.refreshArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)

        // Observe qualityFilter changes
        defaults.publisher(for: \.qualityFilter)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { [weak self] newValue in
                guard let self = self, self.qualityFilter != newValue else { return }

                Task { @MainActor in
                    self.qualityFilter = newValue
                    await self.refreshArticles()
                    
                    // Update badge count after quality filter change
                    NotificationUtils.updateAppBadgeCount()
                }
            }
            .store(in: &userDefaultsSubscriptions)
    }

    /// Saves user preferences to UserDefaults
    private func saveUserPreferences() {
        let defaults = UserDefaults.standard
        defaults.showUnreadOnly = showUnreadOnly
        defaults.showBookmarkedOnly = showBookmarkedOnly
        defaults.sortOrder = sortOrder
        defaults.groupingStyle = groupingStyle
        defaults.selectedTopic = selectedTopic
        defaults.qualityFilter = qualityFilter
    }

    // MARK: - Additional Methods for the View

    /// Opens the article in the detail view
    func openArticle(_ article: ArticleModel) async {
        // Mark the article as viewed
        if !article.isViewed {
            // Use markArticles with array of one ID
            _ = await articleOperations.markArticles(ids: [article.id], asRead: true)
        }

        // Notify that an article has been opened
        NotificationCenter.default.post(name: Notification.Name("ArticleViewed"), object: nil)
    }

    /// Phase 2.1: Pre-extracts rich text content for fast article opening
    /// This provides immediate access to formatted content without waiting for blob extraction
    func preExtractRichText(for articleID: UUID) async {
        // Check if already cached and not expired
        if let cached = richTextCache[articleID], !cached.isExpired {
            return
        }
        
        // Use user-initiated priority for visible articles
        await Task(priority: .userInitiated) { @MainActor in
            if let article = await articleOperations.getArticleModelWithContext(byId: articleID) {
                // Extract rich text content sequentially on MainActor to avoid Sendable issues
                let title = await extractAttributedContent(.title, from: article)
                let body = await extractAttributedContent(.body, from: article)
                let summary = await extractAttributedContent(.summary, from: article)
                
                // Cache the results (already on main actor)
                let cacheEntry = RichTextCacheEntry(
                    title: title,
                    body: body,
                    summary: summary,
                    timestamp: Date()
                )
                richTextCache[articleID] = cacheEntry
                
                // Clean up expired entries periodically
                if richTextCache.count > 50 {
                    cleanupExpiredRichTextCache()
                }
            }
        }.value
    }
    
    /// Gets pre-extracted rich text content from cache for immediate use
    func getCachedRichText(for articleID: UUID) -> RichTextCacheEntry? {
        guard let cached = richTextCache[articleID], !cached.isExpired else {
            return nil
        }
        return cached
    }
    
    /// Extracts attributed content from blob or generates if missing
    @MainActor
    private func extractAttributedContent(_ field: RichTextField, from article: ArticleModel) async -> NSAttributedString? {
        // First try to extract from existing blob
        if let blob = field.getBlob(from: article),
           let attributedString = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: NSAttributedString.self,
               from: blob
           ) {
            return attributedString
        }
        
        // If blob doesn't exist, generate content (already on main actor)
        return articleOperations.getAttributedContent(
            for: field,
            from: article,
            createIfMissing: true
        )
    }
    
    /// Cleans up expired rich text cache entries
    private func cleanupExpiredRichTextCache() {
        let expiredKeys = richTextCache.compactMap { key, entry in
            entry.isExpired ? key : nil
        }
        
        for key in expiredKeys {
            richTextCache.removeValue(forKey: key)
        }
        
        AppLogger.database.debug("Cleaned up \(expiredKeys.count) expired rich text cache entries")
    }

    /// Generates essential blobs for an article if needed (title and body only - "above the fold" content)
    /// This is optimized for topic switching performance by only processing essential content
    func generateEssentialBlobsIfNeeded(articleID: UUID) async {
        // Phase 2.1: Pre-extract rich text for immediate access
        await preExtractRichText(for: articleID)
        
        // Also generate blobs in background for persistence
        await Task(priority: .background) {
            if let article = await articleOperations.getArticleModelWithContext(byId: articleID) {
                // Only generate essential fields if missing
                let needsTitle = article.titleBlob == nil
                let needsBody = article.bodyBlob == nil
                
                // Skip if both blobs already exist
                guard needsTitle || needsBody else { return }
                
                // Process on main actor since NSAttributedString requires it
                await MainActor.run {
                    // Generate title blob if needed
                    if needsTitle && !article.title.isEmpty {
                        _ = articleOperations.getAttributedContent(for: .title, from: article, createIfMissing: true)
                    }
                    
                    // Generate body blob if needed  
                    if needsBody && !article.body.isEmpty {
                        _ = articleOperations.getAttributedContent(for: .body, from: article, createIfMissing: true)
                    }
                }
            }
        }.value
    }
    

    /// Updates filtered articles based on current filters
    func updateFilteredArticles(isBackgroundUpdate _: Bool = false, force: Bool = false, isActivelyScrolling: Bool = false) async {
        // If actively scrolling, just mark that we need an update later
        if isActivelyScrolling, !force {
            pendingUpdateNeeded = true
            return
        }

        // Reset this flag since we're doing the update now
        pendingUpdateNeeded = false

        // Refresh articles with current filters
        await refreshArticles()
    }

    /// The batch size for pagination
    var batchSize: Int {
        return pageSize
    }

    /// Removes duplicate articles from the database
    /// - Returns: Number of duplicates removed
    func removeDuplicateArticles() async -> Int {
        do {
            isLoading = true
            let removedCount = try await articleOperations.cleanupDuplicateArticles()
            isLoading = false

            // Refresh the UI after cleanup
            await refreshArticles()

            return removedCount
        } catch {
            isLoading = false
            self.error = error
            AppLogger.database.error("Error removing duplicate articles: \(error)")
            return 0
        }
    }

    /// Diagnoses and repairs rich text blob issues in articles
    /// - Parameters:
    ///   - articleId: Optional article ID to diagnose a specific article, or nil for all articles
    ///   - forceRegenerate: Whether to force regeneration of all blobs, even if they seem valid
    ///   - limit: Optional limit on the number of articles to process
    /// - Returns: A diagnostic summary
    func diagnoseAndRepairRichTextBlobs(
        articleId: UUID? = nil,
        forceRegenerate: Bool = false,
        limit: Int? = nil
    ) async -> String {
        do {
            isLoading = true

            // Access the ArticleService directly since blob diagnostics are implemented there
            let articleService = ArticleService.shared

            // Run the diagnostic
            let (diagnosed, repaired, details) = try await articleService.diagnoseAndRepairRichTextBlobs(
                articleId: articleId,
                forceRegenerate: forceRegenerate,
                limit: limit
            )

            // Generate a summary
            let summary = """
            Rich Text Blob Diagnostic Results:
            - Articles diagnosed: \(diagnosed)
            - Articles repaired: \(repaired)

            Details:
            \(details)
            """

            AppLogger.database.debug("Completed blob diagnostics: \(diagnosed) diagnosed, \(repaired) repaired")

            isLoading = false

            // Refresh if repairs were made
            if repaired > 0 {
                await refreshArticles()
            }

            return summary
        } catch {
            isLoading = false
            self.error = error
            AppLogger.database.error("Error diagnosing rich text blobs: \(error)")
            return "Error during blob diagnostics: \(error.localizedDescription)"
        }
    }

    /// Gets an attributed string for a specific field of an article
    @MainActor
    func getAttributedContent(
        for field: RichTextField,
        from article: ArticleModel,
        createIfMissing: Bool = true
    ) -> NSAttributedString? {
        return articleOperations.getAttributedContent(
            for: field,
            from: article,
            createIfMissing: createIfMissing
        )
    }
}
