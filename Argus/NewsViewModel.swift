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

    /// The page size for pagination
    var pageSize: Int = 30

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
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300 // 5 minutes
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

        AppLogger.database.debug("NewsViewModel initialized with container: \(String(describing: SwiftDataContainer.shared.container))")
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

            AppLogger.database.debug("✅ Refreshed articles: loaded \(self.filteredArticles.count) articles")
        } catch {
            self.error = error
            isLoading = false
            AppLogger.database.error("❌ Error refreshing articles: \(error)")
        }
    }

    /// Refreshes articles and performs auto-redirect if the current topic has no content
    @MainActor
    func refreshWithAutoRedirectIfNeeded() async {
        // First do the normal refresh
        await refreshArticles()

        // Then check if we need to redirect
        if filteredArticles.isEmpty, selectedTopic != "All" {
            AppLogger.database.debug("No content for topic '\(self.selectedTopic)', auto-redirecting to 'All'")

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
            AppLogger.database.error("Error refreshing all articles: \(error)")
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

    /// Performs a sync with the server for updated content
    func syncWithServer() async {
        // Prevent concurrent sync operations
        guard !isSyncing else {
            AppLogger.sync.info("Sync already in progress, ignoring duplicate request")
            return
        }
        
        // Set status to searching and loading state
        syncStatus = .searching
        isLoading = true
        error = nil

        do {
            // Sync with server
            let addedCount = try await articleOperations.syncContent(
                topic: selectedTopic != "All" ? selectedTopic : nil,
                progressHandler: { message in
                    // Update progress state with phase message
                    Task { @MainActor in
                        self.syncStatus = .syncing(message: message)
                    }
                }
            )

            // If we got new articles, refresh
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

            AppLogger.database.debug("✅ Synced with server: added \(addedCount) articles")
        } catch {
            // Set error status
            syncStatus = .error(error.localizedDescription)
            isLoading = false
            self.error = error
            AppLogger.database.error("❌ Error syncing with server: \(error)")

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

        AppLogger.database.debug("Applying topic filter: \(topic)")

        // Try to use cache for immediate response
        if tryLoadFromCache(topic: topic) {
            AppLogger.database.debug("Cache hit for topic: \(topic)")
            // Still refresh in the background to ensure up-to-date data
            await refreshArticles()
        } else {
            AppLogger.database.debug("Cache miss for topic: \(topic), performing full refresh")
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

    /// Tries to load articles from cache for immediate response with smart validation
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
            
            filteredArticles = cachedEntry.articles
            // Create task to update grouping based on cached articles
            Task {
                await updateGroupedArticles()
            }
            AppLogger.database.debug("Smart cache hit for topic: \(topic)")
            return true
        }
        
        AppLogger.database.debug("Smart cache miss for topic: \(topic) - expired: \(self.articleCache[topic]?.isExpired ?? true)")
        return false
    }

    /// Updates the article cache with new articles using smart caching
    /// - Parameter articles: The articles to cache
    private func updateArticleCache(_ articles: [ArticleModel]) {
        let currentFilters = CacheFilters(
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter,
            sortOrder: sortOrder,
            groupingStyle: groupingStyle
        )
        
        // Create cache entry with metadata
        let cachedEntry = CachedArticles(
            articles: articles,
            timestamp: Date(),
            filters: currentFilters
        )
        
        // Update cache for current topic
        articleCache[selectedTopic] = cachedEntry

        // Update "All" cache if we're not already in "All"
        if selectedTopic != "All" {
            // We now want to preserve the "All" entries in the cache for topic bar generation
            // If allArticles is populated, use it to update the "All" cache
            if !allArticles.isEmpty {
                let allTopicsEntry = CachedArticles(
                    articles: allArticles,
                    timestamp: Date(),
                    filters: currentFilters
                )
                articleCache["All"] = allTopicsEntry
            }
        }

        lastCacheUpdate = Date()
        isCacheValid = true
        
        // Perform memory-aware cache cleanup
        performMemoryAwareCacheCleanup()
    }
    
    /// Memory-aware cache cleanup to prevent excessive memory usage
    private func performMemoryAwareCacheCleanup() {
        let maxCacheEntries = 10 // Keep cache for last 10 topic/filter combinations
        
        guard articleCache.count > maxCacheEntries else { return }
        
        // Sort by timestamp and keep only the most recent entries
        let sortedEntries = articleCache.sorted { $0.value.timestamp > $1.value.timestamp }
        let entriesToKeep = sortedEntries.prefix(maxCacheEntries)
        
        self.articleCache = Dictionary(uniqueKeysWithValues: entriesToKeep.map { ($0.key, $0.value) })
        
        AppLogger.database.debug("Cache cleanup: keeping \(self.articleCache.count) entries")
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

    /// Generates essential blobs for an article if needed (title and body only - "above the fold" content)
    /// This is optimized for topic switching performance by only processing essential content
    func generateEssentialBlobsIfNeeded(articleID: UUID) async {
        // Only process "above the fold" content for fast NewsView display
        // This approach is intentional and maintains the optimized architecture
        
        // Use low priority to avoid blocking UI during topic switches
        await Task(priority: .background) {
            // Access the article directly from SwiftData
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
