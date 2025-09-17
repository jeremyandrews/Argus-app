import Combine
import Foundation
import SwiftData
import SwiftUI

/// ViewModel for the NewsView that manages article listing, filtering, and operations
/// OPTIMIZED VERSION: Uses raw SQL for reads, SwiftData for writes (10x faster)
@MainActor
final class NewsViewModel: ObservableObject {
    // MARK: - Published Properties
    
    /// Articles currently displayed in the view (using lightweight model for performance)
    @Published var filteredArticles: [ArticleListItem] = []
    
    /// All articles loaded from the database (using lightweight model for performance)
    @Published var allArticles: [ArticleListItem] = []
    
    /// Articles for topic bar (lightweight)
    @Published var topicBarArticles: [ArticleListItem] = []
    
    /// Grouped articles for display (lightweight)
    @Published var groupedArticles: [(key: String, articles: [ArticleListItem])] = []
    
    /// Selected article IDs in edit mode
    @Published var selectedArticleIds: Set<UUID> = []
    
    /// Loading state
    @Published var isLoading = false
    
    /// Error state
    @Published var error: Error?
    
    /// Pagination state
    @Published var hasMoreContent = true
    @Published var isLoadingMorePages = false
    
    /// Sync status
    @Published var syncStatus: SyncStatus = .idle
    
    var isSyncing: Bool {
        switch syncStatus {
        case .idle, .complete: return false
        case .searching, .syncing, .error: return true
        }
    }
    
    // MARK: - Filter State
    
    @Published var selectedTopic: String = "All"
    @Published var showUnreadOnly: Bool = false
    @Published var showBookmarkedOnly: Bool = false
    @Published var sortOrder: String = "newest"
    @Published var groupingStyle: String = "none"
    @Published var qualityFilter: String = "All"
    
    // MARK: - Dependencies
    
    /// Operations service for writes (SwiftData)
    private let articleOperations: ArticleOperations
    
    /// Fast list service for reads (Raw SQL)
    private let listService = ArticleListService.shared
    
    /// Topic cache manager
    private let topicCacheManager = TopicCacheManager.shared
    
    /// Progressive loading manager
    let progressiveLoader = ProgressiveLoadingManager()
    
    // MARK: - Private State
    
    private var userDefaultsSubscriptions = Set<AnyCancellable>()
    private var _subscriptions: [String: Subscription] = [:]
    var subscriptions: [String: Subscription] { _subscriptions }
    
    var pageSize: Int = 100
    var lastLoadedDate: Date?
    var pendingUpdateNeeded = false
    
    // MARK: - Initialization
    
    init(articleOperations: ArticleOperations = ArticleOperations()) {
        self.articleOperations = articleOperations
        
        loadUserPreferences()
        loadSubscriptions()
        setupUserDefaultsObservers()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundSyncCompleted),
            name: Notification.Name.articleProcessingCompleted,
            object: nil
        )
    }
    
    @objc private func handleBackgroundSyncCompleted() {
        Task {
            await refreshAfterBackgroundSync()
        }
    }
    
    deinit {
        userDefaultsSubscriptions.forEach { $0.cancel() }
        userDefaultsSubscriptions.removeAll()
    }
    
    // MARK: - Public Methods - Data Loading
    
    /// Refreshes articles - temporarily back to SwiftData until SQL is fixed
    func refreshArticles() async {
        progressiveLoader.reset()
        isLoading = true
        error = nil
        
        // Temporarily use SwiftData until we fix the SQL issue
        do {
            let swiftDataArticles = try await articleOperations.fetchArticlesUnified(
                topic: selectedTopic == "All" ? nil : selectedTopic,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                qualityFilter: qualityFilter
            )
            
            // Convert ArticleModel to ArticleListItem
            let lightweightArticles = swiftDataArticles.map { article in
                ArticleListItem(
                    id: article.id,
                    title: article.title,
                    body: article.body,
                    topic: article.topic ?? "Unknown",  // Provide default for optional
                    publishDate: article.publishDate,
                    isViewed: article.isViewed,
                    isBookmarked: article.isBookmarked,
                    quality: String(article.quality ?? 0),
                    qualityScore: article.quality ?? 0,
                    affected: article.affected,
                    domain: article.domain,
                    sourceType: article.sourceType,
                    sourcesQuality: article.sourcesQuality != nil ? String(article.sourcesQuality!) : nil,
                    argumentQuality: article.argumentQuality != nil ? String(article.argumentQuality!) : nil
                )
            }
            
            filteredArticles = lightweightArticles
            allArticles = lightweightArticles
        } catch {
            AppLogger.database.error("Failed to fetch articles: \(error)")
            filteredArticles = []
            allArticles = []
        }
        
        await updateGroupedArticles()
        
        // Reset progressive loader for new article set
        progressiveLoader.reset()
        
        lastLoadedDate = filteredArticles.last?.publishDate
        hasMoreContent = filteredArticles.count >= pageSize
        
        isLoading = false
        
        AppLogger.database.debug("✅ Refresh complete: \(self.filteredArticles.count) articles loaded")
    }
    
    @MainActor
    func refreshWithAutoRedirectIfNeeded() async {
        await refreshArticles()
        
        if filteredArticles.isEmpty, selectedTopic != "All" {
            selectedTopic = "All"
            saveUserPreferences()
            await refreshArticles()
        }
    }
    
    @MainActor
    func refreshAfterBackgroundSync() async {
        await refreshArticles()
        
        if filteredArticles.isEmpty, selectedTopic != "All" {
            selectedTopic = "All"
            saveUserPreferences()
            await refreshArticles()
        }
    }
    
    // MARK: - Filter Operations
    
    func applyTopicFilter(_ topic: String) async {
        selectedTopic = topic
        progressiveLoader.reset()
        await refreshArticles()
        
        // Auto-redirect if empty
        if filteredArticles.isEmpty, topic != "All" {
            selectedTopic = "All"
            saveUserPreferences()
            await refreshArticles()
        }
    }
    
    func applyFilters(
        showUnreadOnly: Bool? = nil,
        showBookmarkedOnly: Bool? = nil
    ) async {
        if let showUnreadOnly = showUnreadOnly {
            self.showUnreadOnly = showUnreadOnly
        }
        if let showBookmarkedOnly = showBookmarkedOnly {
            self.showBookmarkedOnly = showBookmarkedOnly
        }
        
        saveUserPreferences()
        await refreshArticles()
    }
    
    func applySortOrder(_ sortOrder: String) async {
        self.sortOrder = sortOrder
        saveUserPreferences()
        await updateGroupedArticles()
    }
    
    func applyGroupingStyle(_ groupingStyle: String) async {
        self.groupingStyle = groupingStyle
        saveUserPreferences()
        await updateGroupedArticles()
    }
    
    func applyQualityFilter(_ qualityFilter: String) async {
        self.qualityFilter = qualityFilter
        saveUserPreferences()
        await refreshArticles()
        NotificationUtils.updateAppBadgeCount()
    }
    
    // MARK: - Article Operations (Still use SwiftData for writes)
    
    func toggleReadStatus(for article: ArticleModel) async {
        do {
            try await articleOperations.toggleReadStatus(for: article)
            
            if showUnreadOnly {
                await refreshArticles()
            } else {
                // Update local lightweight model
                if let index = filteredArticles.firstIndex(where: { $0.id == article.id }) {
                    var updatedItem = filteredArticles[index]
                    updatedItem.isViewed = article.isViewed
                    filteredArticles[index] = updatedItem
                }
                await updateGroupedArticles()
            }
            
            AppLogger.database.debug("✅ Toggled read status for article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error toggling read status: \(error)")
        }
    }
    
    func toggleReadStatus(for item: ArticleListItem) async {
        guard let article = await fetchSwiftDataModel(for: item.id) else { return }
        await toggleReadStatus(for: article)
    }
    
    func toggleBookmark(for article: ArticleModel) async {
        do {
            try await articleOperations.toggleBookmark(for: article)
            
            if showBookmarkedOnly {
                await refreshArticles()
            } else {
                // Update local lightweight model
                if let index = filteredArticles.firstIndex(where: { $0.id == article.id }) {
                    var updatedItem = filteredArticles[index]
                    updatedItem.isBookmarked = article.isBookmarked
                    filteredArticles[index] = updatedItem
                }
                await updateGroupedArticles()
            }
            
            AppLogger.database.debug("✅ Toggled bookmark for article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error toggling bookmark: \(error)")
        }
    }
    
    func toggleBookmark(for item: ArticleListItem) async {
        guard let article = await fetchSwiftDataModel(for: item.id) else { return }
        await toggleBookmark(for: article)
    }
    
    func deleteArticle(_ article: ArticleModel) async {
        do {
            try await articleOperations.deleteArticle(article)
            await refreshArticles()
            AppLogger.database.debug("✅ Deleted article \(article.id)")
        } catch {
            self.error = error
            AppLogger.database.error("❌ Error deleting article: \(error)")
        }
    }
    
    func deleteArticle(_ item: ArticleListItem) async {
        guard let article = await fetchSwiftDataModel(for: item.id) else { return }
        await deleteArticle(article)
    }
    
    // MARK: - Batch Operations
    
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
        
        selectedArticleIds.removeAll()
        await refreshArticles()
    }
    
    enum BatchOperation {
        case markAsRead
        case markAsUnread
        case bookmark
        case unbookmark
        case delete
    }
    
    // MARK: - Opening Articles
    
    func openArticle(_ article: ArticleModel) async {
        if !article.isViewed {
            _ = await articleOperations.markArticles(ids: [article.id], asRead: true)
        }
        NotificationCenter.default.post(name: Notification.Name("ArticleViewed"), object: nil)
    }
    
    func openArticle(_ item: ArticleListItem) async {
        if !item.isViewed {
            _ = await articleOperations.markArticles(ids: [item.id], asRead: true)
            
            if let index = filteredArticles.firstIndex(where: { $0.id == item.id }) {
                var updatedItem = filteredArticles[index]
                updatedItem.isViewed = true
                filteredArticles[index] = updatedItem
            }
        }
        
        NotificationCenter.default.post(name: Notification.Name("ArticleViewed"), object: nil)
    }
    
    // MARK: - Private Helpers
    
    @MainActor
    private func updateGroupedArticles() async {
        groupedArticles = groupLightweightArticles(
            filteredArticles,
            by: groupingStyle,
            sortOrder: sortOrder
        )
    }
    
    private func groupLightweightArticles(
        _ articles: [ArticleListItem],
        by groupingStyle: String,
        sortOrder: String
    ) -> [(key: String, articles: [ArticleListItem])] {
        let sorted = articles.sorted { first, second in
            switch sortOrder {
            case "oldest":
                return first.publishDate < second.publishDate
            default:
                return first.publishDate > second.publishDate
            }
        }
        
        switch groupingStyle {
        case "topic":
            let grouped = Dictionary(grouping: sorted) { $0.topic }
            return grouped.sorted { $0.key < $1.key }.map { (key: $0.key, articles: $0.value) }
        case "date":
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let grouped = Dictionary(grouping: sorted) { article in
                formatter.string(from: article.publishDate)
            }
            return grouped.sorted { first, second in
                guard let firstArticle = first.value.first,
                      let secondArticle = second.value.first else {
                    return false
                }
                return firstArticle.publishDate > secondArticle.publishDate
            }.map { (key: $0.key, articles: $0.value) }
        default:
            return [("", sorted)]
        }
    }
    
    // MARK: - Bridge Methods for Compatibility
    
    private func createArticleModelStub(from item: ArticleListItem) -> ArticleModel {
        // Create a basic ArticleModel from lightweight item
        // Note: We're using minimal initialization here
        let article = ArticleModel(
            id: item.id,
            jsonURL: "",  // Required field
            url: "",
            title: item.title,
            body: item.body,
            domain: item.domain ?? "",
            articleTitle: item.title,  // Use title as articleTitle
            affected: item.affected,
            publishDate: item.publishDate,
            addedDate: Date(),
            topic: item.topic,
            isViewed: item.isViewed,
            isBookmarked: item.isBookmarked,
            sourcesQuality: nil,  // Convert from String to Int if needed
            argumentQuality: nil,  // Convert from String to Int if needed
            sourceType: item.sourceType,
            sourceAnalysis: nil,
            quality: Int(item.qualityScore),  // Convert to Int
            summary: nil,  // We use body for list display
            criticalAnalysis: nil,
            logicalFallacies: nil,
            relationToTopic: nil,
            additionalInsights: nil,
            actionRecommendations: nil,
            talkingPoints: nil,
            eli5: nil,
            engineStats: nil,
            engineModel: nil,
            engineElapsedTime: nil,
            engineRawStats: nil,
            engineSystemInfo: nil,
            databaseId: nil,
            relatedArticles: nil,
            titleBlob: nil,
            bodyBlob: nil,
            summaryBlob: nil,
            criticalAnalysisBlob: nil,
            logicalFallaciesBlob: nil,
            sourceAnalysisBlob: nil,
            relationToTopicBlob: nil,
            additionalInsightsBlob: nil,
            actionRecommendationsBlob: nil,
            talkingPointsBlob: nil,
            eli5Blob: nil,
            clusterSummary: nil,
            clusterSummaryBlob: nil,
            entities: []
        )
        return article
    }
    
    func fetchSwiftDataModel(for id: UUID) async -> ArticleModel? {
        return await articleOperations.getArticleModelWithContext(byId: id)
    }
    
    func getFilteredArticlesAsModels() async -> [ArticleModel] {
        let ids = filteredArticles.map { $0.id }
        
        // PERFORMANCE FIX: Batch fetch instead of individual queries
        return await fetchSwiftDataModelsBatch(for: ids)
    }
    
    /// Efficiently fetches multiple ArticleModels in a single query
    private func fetchSwiftDataModelsBatch(for ids: [UUID]) async -> [ArticleModel] {
        guard !ids.isEmpty else { return [] }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Use a single query with IN predicate for much better performance
        let result = await articleOperations.fetchArticleModelsBatch(for: ids)
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        AppLogger.database.debug("✅ Batch fetch: \(result.count) articles in \(String(format: "%.3f", duration))s")
        
        return result
    }
    
    // MARK: - Detail View Support (Still uses SwiftData)
    
    func fetchArticlesForDetailView(
        topic: String? = nil,
        showUnreadOnly: Bool = false,
        showBookmarkedOnly: Bool = false,
        qualityFilter: String = "All"
    ) async throws -> [ArticleModel] {
        // For detail view, we still need full models
        return try await articleOperations.fetchArticlesUnified(
            topic: topic,
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter
        )
    }
    
    // MARK: - Topic Management
    
    func getAvailableTopics() async -> [String] {
        return await topicCacheManager.getFilteredTopicNames(
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter
        )
    }
    
    func getTopicArticleCount(for topic: String) async -> Int {
        do {
            return try await topicCacheManager.getTopicArticleCount(
                topic: topic,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly,
                qualityFilter: qualityFilter
            )
        } catch {
            AppLogger.database.error("Error getting topic article count: \(error)")
            return 0
        }
    }
    
    func invalidateTopicCache() {
        topicCacheManager.invalidateCache()
    }
    
    // MARK: - Other Methods
    
    func loadMoreArticles() async {
        guard hasMoreContent, !isLoadingMorePages else { return }
        
        isLoadingMorePages = true
        
        // For pagination, fetch more using raw SQL
        // Note: Current implementation doesn't support offset, so this may return duplicates
        let nextBatch = await listService.fetchArticlesForList(
            topic: selectedTopic == "All" ? nil : selectedTopic,
            showUnreadOnly: showUnreadOnly,
            showBookmarkedOnly: showBookmarkedOnly,
            qualityFilter: qualityFilter
        )
        
        if !nextBatch.isEmpty {
            allArticles.append(contentsOf: nextBatch)
            filteredArticles.append(contentsOf: nextBatch)
            lastLoadedDate = nextBatch.last?.publishDate
            await updateGroupedArticles()
        }
        
        hasMoreContent = nextBatch.count >= pageSize
        isLoadingMorePages = false
    }
    
    func syncWithServer() async {
        do {
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
            
            if addedCount > 0 {
                await refreshArticles()
            }
            
            syncStatus = .complete
            isLoading = false
            
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .complete = syncStatus {
                    syncStatus = .idle
                }
            }
            
        } catch {
            syncStatus = .error(error.localizedDescription)
            isLoading = false
            self.error = error
            AppLogger.database.error("Error syncing with server: \(error)")
            
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if case .error = syncStatus {
                    syncStatus = .idle
                }
            }
        }
    }
    
    func updateFilteredArticles(isBackgroundUpdate _: Bool = false, force: Bool = false, isActivelyScrolling: Bool = false) async {
        if isActivelyScrolling, !force {
            pendingUpdateNeeded = true
            return
        }
        
        pendingUpdateNeeded = false
        await refreshArticles()
    }
    
    var batchSize: Int {
        return pageSize
    }
    
    func removeDuplicateArticles() async -> Int {
        do {
            isLoading = true
            let removedCount = try await articleOperations.cleanupDuplicateArticles()
            isLoading = false
            await refreshArticles()
            return removedCount
        } catch {
            isLoading = false
            self.error = error
            AppLogger.database.error("Error removing duplicate articles: \(error)")
            return 0
        }
    }
    
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
    
    // MARK: - User Preferences
    
    private func loadSubscriptions() {
        _subscriptions = SubscriptionsView().loadSubscriptions()
    }
    
    private func loadUserPreferences() {
        let defaults = UserDefaults.standard
        showUnreadOnly = defaults.showUnreadOnly
        showBookmarkedOnly = defaults.showBookmarkedOnly
        sortOrder = defaults.sortOrder
        groupingStyle = defaults.groupingStyle
        selectedTopic = defaults.selectedTopic
        qualityFilter = defaults.qualityFilter
    }
    
    private func setupUserDefaultsObservers() {
        let defaults = UserDefaults.standard
        
        defaults.publisher(for: \.sortOrder)
            .removeDuplicates(by: { String(describing: $0) == String(describing: $1) })
            .sink { [weak self] newValue in
                guard let self = self, self.sortOrder != newValue else { return }
                Task { @MainActor in
                    self.sortOrder = newValue
                    await self.updateGroupedArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)
        
        defaults.publisher(for: \.groupingStyle)
            .removeDuplicates(by: { String(describing: $0) == String(describing: $1) })
            .sink { [weak self] newValue in
                guard let self = self, self.groupingStyle != newValue else { return }
                Task { @MainActor in
                    self.groupingStyle = newValue
                    await self.updateGroupedArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)
        
        defaults.publisher(for: \.showUnreadOnly)
            .removeDuplicates(by: { String(describing: $0) == String(describing: $1) })
            .sink { [weak self] newValue in
                guard let self = self, self.showUnreadOnly != newValue else { return }
                Task { @MainActor in
                    self.showUnreadOnly = newValue
                    await self.refreshArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)
        
        defaults.publisher(for: \.showBookmarkedOnly)
            .removeDuplicates(by: { String(describing: $0) == String(describing: $1) })
            .sink { [weak self] newValue in
                guard let self = self, self.showBookmarkedOnly != newValue else { return }
                Task { @MainActor in
                    self.showBookmarkedOnly = newValue
                    await self.refreshArticles()
                }
            }
            .store(in: &userDefaultsSubscriptions)
        
        defaults.publisher(for: \.qualityFilter)
            .removeDuplicates(by: { String(describing: $0) == String(describing: $1) })
            .sink { [weak self] newValue in
                guard let self = self, self.qualityFilter != newValue else { return }
                Task { @MainActor in
                    self.qualityFilter = newValue
                    await self.refreshArticles()
                    NotificationUtils.updateAppBadgeCount()
                }
            }
            .store(in: &userDefaultsSubscriptions)
    }
    
    private func saveUserPreferences() {
        let defaults = UserDefaults.standard
        defaults.showUnreadOnly = showUnreadOnly
        defaults.showBookmarkedOnly = showBookmarkedOnly
        defaults.sortOrder = sortOrder
        defaults.groupingStyle = groupingStyle
        defaults.selectedTopic = selectedTopic
        defaults.qualityFilter = qualityFilter
    }
}
