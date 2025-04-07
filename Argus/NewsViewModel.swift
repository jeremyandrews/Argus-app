import Combine
import Foundation
import SwiftData
import SwiftUI

/// ViewModel for the NewsView that manages article listing, filtering, and operations
@MainActor
final class NewsViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Articles currently displayed in the view
    @Published var filteredArticles: [NotificationData] = []

    /// All articles loaded from the database (may be more than what's displayed)
    @Published var allArticles: [NotificationData] = []

    /// Grouped articles for display in sections
    @Published var groupedArticles: [(key: String, notifications: [NotificationData])] = []

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

    // MARK: - Filter State

    /// The currently selected topic
    @Published var selectedTopic: String = "All"

    /// Flag indicating if only unread articles should be shown
    @Published var showUnreadOnly: Bool = false

    /// Flag indicating if only bookmarked articles should be shown
    @Published var showBookmarkedOnly: Bool = false

    /// Flag indicating if archived articles should be shown
    @Published var showArchivedContent: Bool = false

    /// The current sort order
    @Published var sortOrder: String = "newest"

    /// The current grouping style
    @Published var groupingStyle: String = "none"

    // MARK: - Pagination State

    /// The page size for pagination
    var pageSize: Int = 30

    /// The last loaded date for pagination
    var lastLoadedDate: Date? = nil

    /// Flag indicating if an update is needed but pending due to active scrolling
    var pendingUpdateNeeded = false

    /// Timestamp of the most recent filter change
    private var lastFilterChangeTime = Date.distantPast

    /// Task that handles debounced filter updates
    private var filterChangeDebouncer: Task<Void, Never>? = nil

    /// Cache of articles by topic for quick topic switching
    private var articleCache: [String: [NotificationData]] = [:]

    /// Timestamp of the last cache update
    private var lastCacheUpdate = Date.distantPast

    /// Flag indicating if the cache is valid
    private var isCacheValid = false

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
            // Fetch articles with current filters
            let articles = try await articleOperations.fetchArticles(
                topic: selectedTopic,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                showArchivedContent: showArchivedContent
            )

            // Update the UI
            allArticles = articles
            filteredArticles = articles

            // Update grouping
            await updateGroupedArticles()

            // Update cache
            updateArticleCache(articles)

            // Reset pagination state
            lastLoadedDate = articles.last?.pub_date ?? articles.last?.date
            hasMoreContent = articles.count >= pageSize

            // Clear loading state
            isLoading = false
        } catch {
            self.error = error
            isLoading = false
            AppLogger.database.error("Error refreshing articles: \(error)")
        }
    }

    /// Loads more articles for pagination
    func loadMoreArticles() async {
        guard hasMoreContent && !isLoadingMorePages else { return }

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
                showArchivedContent: showArchivedContent,
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
                lastLoadedDate = nextPageArticles.last?.pub_date ?? nextPageArticles.last?.date

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
        isLoading = true
        error = nil

        do {
            // Sync with server
            let addedCount = try await articleOperations.syncContent(
                topic: selectedTopic != "All" ? selectedTopic : nil
            )

            // If we got new articles, refresh
            if addedCount > 0 {
                await refreshArticles()
            }

            isLoading = false
        } catch {
            isLoading = false
            self.error = error
            AppLogger.database.error("Error syncing with server: \(error)")
        }
    }

    // MARK: - Public Methods - Filter Operations

    /// Applies a new topic filter
    /// - Parameter topic: The topic to filter by
    func applyTopicFilter(_ topic: String) async {
        // Store the previous topic for transition if needed in the future
        // let previousTopic = selectedTopic (removed - unused)

        // Update the topic filter
        selectedTopic = topic

        // Try to use cache for immediate response
        if tryLoadFromCache(topic: topic) {
            // Still refresh in the background to ensure up-to-date data
            await refreshArticles()
        } else {
            // If cache miss, do a full refresh
            await refreshArticles()
        }
    }

    /// Applies filters for read status, bookmarked status, and archived status
    /// - Parameters:
    ///   - showUnreadOnly: Whether to show only unread articles
    ///   - showBookmarkedOnly: Whether to show only bookmarked articles
    ///   - showArchivedContent: Whether to show archived content
    func applyFilters(
        showUnreadOnly: Bool? = nil,
        showBookmarkedOnly: Bool? = nil,
        showArchivedContent: Bool? = nil
    ) async {
        // Update filter values if provided
        if let showUnreadOnly = showUnreadOnly {
            self.showUnreadOnly = showUnreadOnly
        }

        if let showBookmarkedOnly = showBookmarkedOnly {
            self.showBookmarkedOnly = showBookmarkedOnly
        }

        if let showArchivedContent = showArchivedContent {
            self.showArchivedContent = showArchivedContent
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

    // MARK: - Public Methods - Article Operations

    /// Toggles the read status of an article
    /// - Parameter article: The article to toggle
    func toggleReadStatus(for article: NotificationData) async {
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
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling read status: \(error)")
        }
    }

    /// Toggles the bookmarked status of an article
    /// - Parameter article: The article to toggle
    func toggleBookmark(for article: NotificationData) async {
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
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling bookmark status: \(error)")
        }
    }

    /// Toggles the archived status of an article
    /// - Parameter article: The article to toggle
    func toggleArchive(for article: NotificationData) async {
        do {
            // Use shared operation
            try await articleOperations.toggleArchive(for: article)

            // If showing archived content is off, we need to refresh
            if !showArchivedContent {
                await refreshArticles()
            } else {
                // Just update grouping
                await updateGroupedArticles()
            }
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling archive status: \(error)")
        }
    }

    /// Deletes an article
    /// - Parameter article: The article to delete
    func deleteArticle(_ article: NotificationData) async {
        do {
            // Use shared operation
            try await articleOperations.deleteArticle(article)

            // Refresh the article list
            await refreshArticles()
        } catch {
            self.error = error
            AppLogger.database.error("Error deleting article: \(error)")
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
        case .archive:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asArchived: true)
        case .unarchive:
            _ = await articleOperations.markArticles(ids: Array(selectedArticleIds), asArchived: false)
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
        case archive
        case unarchive
        case delete
    }

    // MARK: - Private Methods

    /// Updates the groupedArticles array without re-fetching from the database
    private func updateGroupedArticles() async {
        groupedArticles = await articleOperations.groupArticles(
            filteredArticles,
            by: groupingStyle,
            sortOrder: sortOrder
        )
    }

    /// Tries to load articles from cache for immediate response
    /// - Parameter topic: The topic to load
    /// - Returns: Whether articles were loaded from cache
    private func tryLoadFromCache(topic: String) -> Bool {
        // Check if cache is valid
        if isCacheValid && Date().timeIntervalSince(lastCacheUpdate) < 60.0 {
            if let cachedArticles = articleCache[topic] {
                filteredArticles = cachedArticles
                // Create task to update grouping based on cached articles
                Task {
                    await updateGroupedArticles()
                }
                return true
            }
        }
        return false
    }

    /// Updates the article cache with new articles
    /// - Parameter articles: The articles to cache
    private func updateArticleCache(_ articles: [NotificationData]) {
        // Update cache for current topic
        articleCache[selectedTopic] = articles

        // Update "All" cache if we're not already in "All"
        if selectedTopic != "All" {
            // We don't have enough information to update the "All" cache,
            // so we'll invalidate it
            articleCache.removeValue(forKey: "All")
        }

        lastCacheUpdate = Date()
        isCacheValid = true
    }

    /// Loads subscriptions for topic filtering
    private func loadSubscriptions() {
        _subscriptions = SubscriptionsView().loadSubscriptions()
    }

    /// Loads user preferences from UserDefaults
    private func loadUserPreferences() {
        showUnreadOnly = UserDefaults.standard.bool(forKey: "showUnreadOnly")
        showBookmarkedOnly = UserDefaults.standard.bool(forKey: "showBookmarkedOnly")
        showArchivedContent = UserDefaults.standard.bool(forKey: "showArchivedContent")
        sortOrder = UserDefaults.standard.string(forKey: "sortOrder") ?? "newest"
        groupingStyle = UserDefaults.standard.string(forKey: "groupingStyle") ?? "none"
        selectedTopic = UserDefaults.standard.string(forKey: "selectedTopic") ?? "All"
    }

    /// Saves user preferences to UserDefaults
    private func saveUserPreferences() {
        UserDefaults.standard.set(showUnreadOnly, forKey: "showUnreadOnly")
        UserDefaults.standard.set(showBookmarkedOnly, forKey: "showBookmarkedOnly")
        UserDefaults.standard.set(showArchivedContent, forKey: "showArchivedContent")
        UserDefaults.standard.set(sortOrder, forKey: "sortOrder")
        UserDefaults.standard.set(groupingStyle, forKey: "groupingStyle")
        UserDefaults.standard.set(selectedTopic, forKey: "selectedTopic")
    }

    // MARK: - Additional Methods for the View

    /// Opens the article in the detail view
    func openArticle(_ article: NotificationData) async {
        // Mark the article as viewed
        if !article.isViewed {
            // Use markArticles with array of one ID
            _ = await articleOperations.markArticles(ids: [article.id], asRead: true)
        }

        // Notify that an article has been opened
        NotificationCenter.default.post(name: Notification.Name("ArticleViewed"), object: nil)
    }

    /// Generates a blob for an article body if needed
    func generateBodyBlobIfNeeded(notificationID: UUID) async {
        // Find the article in our collections
        if let article = allArticles.first(where: { $0.id == notificationID }) {
            if article.body_blob == nil {
                // Use the rich text generation capabilities
                // Since this needs to run on the main actor for UI work
                await MainActor.run {
                    // This runs on the main actor which is required for NSAttributedString handling
                    _ = articleOperations.getAttributedContent(for: .body, from: article, createIfMissing: true)
                }
            }
        }
    }

    /// Updates filtered articles based on current filters
    func updateFilteredArticles(isBackgroundUpdate _: Bool = false, force: Bool = false, isActivelyScrolling: Bool = false) async {
        // If actively scrolling, just mark that we need an update later
        if isActivelyScrolling && !force {
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
}
