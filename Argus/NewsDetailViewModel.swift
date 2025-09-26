import Combine
import Foundation
import SwiftData
import SwiftUI

/// ViewModel for the NewsDetailView that manages article display, navigation, and operations
@MainActor
final class NewsDetailViewModel: ObservableObject {
    // MARK: - Subscriptions for Settings Changes

    /// Subscriptions for observing UserDefaults changes
    private var userDefaultsSubscriptions = Set<AnyCancellable>()

    /// The database model for the current article (for persistence operations)
    @Published private(set) var currentArticleModel: ArticleModel?

    // MARK: - Published Properties

    /// The initially expanded section, if any
    let initiallyExpandedSection: String?

    /// The currently displayed article
    @Published var currentArticle: ArticleModel?

    /// The index of the current article in the articles array
    @Published var currentIndex: Int

    /// All available articles for navigation (unfiltered to prevent "1 of 0" issues)
    @Published var articles: [ArticleModel]

    /// All articles in the database (may be used for related articles)
    @Published var allArticles: [ArticleModel]
    
    /// The original filtered articles from the list view (for reference and position display)
    private var originalFilteredArticles: [ArticleModel] = []
    
    /// The original index in the filtered articles (for correct position display)
    private var originalFilteredIndex: Int = 0
    
    /// The original count that the user saw when they opened the article (IMMUTABLE)
    /// This preserves the count that was displayed in the list view and should never change
    private let originalDisplayCount: Int
    
    /// The IMMUTABLE navigation reference array - set once at initialization and NEVER changed
    /// This ensures position and count calculations remain consistent throughout the entire session
    private let navigationReferenceArray: [ArticleModel]
    
    /// Whether to use original filtered position for display (true until background fetch completes)
    @Published var useOriginalPosition: Bool = true

    /// Flag indicating if content is being loaded
    @Published var isLoading = false

    /// Error that occurred during article operations
    @Published var error: Error?

    /// Content sections that are currently expanded
    @Published var expandedSections: [String: Bool] = getDefaultExpandedSections()

    /// The content transition ID for forcing view updates
    @Published var contentTransitionID = UUID()

    /// Flag indicating if the next article is being loaded
    @Published var isLoadingNextArticle = false

    /// The current scroll to section, if any
    @Published var scrollToSection: String? = nil

    /// The scroll to top trigger for forcing scroll resets
    @Published var scrollToTopTrigger = UUID()

    /// Set of deleted article IDs
    @Published var deletedIDs: Set<UUID> = []
    
    /// Flag indicating if summary is being generated/loaded
    @Published var isSummaryLoading = false
    
    // MARK: - LRU Caches for Performance
    private let contextCache = LRUCache<UUID, ArticleModel>(capacity: 10)
    private let richTextCache = LRUCache<UUID, RichTextContent>(capacity: 10)

    // Helper struct for rich text caching
    struct RichTextContent {
        let title: NSAttributedString?
        let body: NSAttributedString?
        let summary: NSAttributedString?
    }
    
    // MARK: - Enhanced Model Cache (Phase 1.2) - CRITICAL FIX
    private var modelCache: [UUID: ArticleModel] = [:]
    private let maxCacheSize = 10
    
    /// Gets an article model with context, using cache when available
    /// This eliminates redundant database fetches that cause 200-800ms delays
    private func getCachedModelWithContext(for articleId: UUID) async -> ArticleModel? {
        // Use LRU cache's get method
        if let cachedModel = contextCache.get(articleId) {
            AppLogger.database.debug("✅ CONTEXT CACHE HIT: Article \(articleId.uuidString.prefix(8)) - avoiding database fetch")
            return cachedModel
        }
        
        AppLogger.database.debug("⚠️ CONTEXT CACHE MISS: Fetching article \(articleId.uuidString.prefix(8)) from database")
        let startTime = Date()
        
        // Fetch from database using background method with Swift 6 compatibility
        let operations = ArticleOperations()
        // Swift 6 FIX: Use synchronous method that returns sendable result
        guard let model = await operations.getArticleModelWithContext(byId: articleId) else {
            return nil
        }
        
        let fetchTime = Date().timeIntervalSince(startTime)
        AppLogger.database.debug("🔄 DATABASE FETCH: \(String(format: "%.3f", fetchTime * 1000))ms for article \(articleId.uuidString.prefix(8))")
        
        // Cache the result using LRU cache
        contextCache.set(articleId, model)
        AppLogger.database.debug("📦 CACHED: Article \(articleId.uuidString.prefix(8))")
        
        return model
    }
    
    // Track navigation history for instant back navigation
    private var navigationHistory: [UUID] = []
    private let maxHistorySize = 5

    // MARK: - Section Content Cache (Non-Rich Text Only)
    
    /// Additional cached content by section (for sections that don't need rich text)
    @Published var cachedContentBySection: [String: NSAttributedString] = [:]

    /// Container diagnostics
    @Published var containerDiagnostics: String = ""

    // MARK: - Section Loading State

    /// Tasks for loading content for each section
    private var sectionLoadingTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Dependencies

    /// Operations service for article business logic
    private let articleOperations: ArticleOperations
    
    /// Reference to NewsViewModel for rich text cache access (Phase 2.1)
    weak var newsViewModel: NewsViewModel?

    // MARK: - Background Processing (Phase 2.2)

    /// SWIFT 6 FIX: Extract blobs on MainActor to avoid Sendable conformance issues
    /// NSAttributedString is not Sendable, so we keep extraction on main thread but yield between operations
    /// - Parameter model: The ArticleModel containing the blobs
    /// - Returns: A tuple containing extracted title, body, and summary attributed strings
    private func extractBlobsInTrueBackground(from model: ArticleModel) async -> (title: NSAttributedString?, body: NSAttributedString?, summary: NSAttributedString?) {
        // Extract blob data (this is quick)
        let titleBlob = model.titleBlob
        let bodyBlob = model.bodyBlob
        let summaryBlob = model.summaryBlob
        
        var title: NSAttributedString?
        var body: NSAttributedString?
        var summary: NSAttributedString?
        
        // Extract title blob if available
        if let titleBlobData = titleBlob {
            title = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: titleBlobData
            )
            // Yield to avoid blocking UI
            await Task.yield()
        }
        
        // Extract body blob if available  
        if let bodyBlobData = bodyBlob {
            body = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: bodyBlobData
            )
            // Yield to avoid blocking UI
            await Task.yield()
        }
        
        // Extract summary blob if available
        if let summaryBlobData = summaryBlob {
            summary = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: summaryBlobData
            )
            // Yield to avoid blocking UI
            await Task.yield()
        }
        
        return (title: title, body: body, summary: summary)
    }

    // MARK: - Initialization

    /// Initializes a new NewsDetailViewModel
    /// - Parameters:
    ///   - articles: Articles available for navigation
    ///   - allArticles: All articles in the database
    ///   - currentIndex: The index of the current article
    ///   - initiallyExpandedSection: Initial section to expand
    ///   - preloadedArticle: Optional preloaded article
    ///   - preloadedTitle: Optional preloaded title attributed string
    ///   - preloadedBody: Optional preloaded body attributed string
    ///   - articleOperations: The article operations service to use
    ///   - newsViewModel: NewsViewModel instance for rich text cache access
    ///   - needsFullDataset: Whether to fetch the complete dataset for comprehensive navigation
    init(
        articles: [ArticleModel],
        allArticles: [ArticleModel],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil,
        preloadedArticle: ArticleModel? = nil,
        preloadedTitle: NSAttributedString? = nil,
        preloadedBody: NSAttributedString? = nil,
        preloadedSummary: NSAttributedString? = nil,
        articleOperations: ArticleOperations = ArticleOperations(),
        newsViewModel: NewsViewModel? = nil,
        needsFullDataset: Bool = false
    ) {
        // ULTRA-SIMPLIFIED: Absolute minimum for instant display
        self.articles = articles
        self.allArticles = allArticles
        self.currentIndex = currentIndex
        self.articleOperations = articleOperations
        self.newsViewModel = newsViewModel
        self.initiallyExpandedSection = initiallyExpandedSection
        
        // CRITICAL N-1 BUG FIX: Preserve the original count the user saw
        // This count should NEVER change, even if background operations filter out articles
        self.originalDisplayCount = articles.count
        AppLogger.database.debug("🔒 N-1 BUG FIX: Preserved original display count: \(self.originalDisplayCount)")
        
        // ULTIMATE N-1 BUG FIX: Set immutable navigation reference array that NEVER changes
        // This ensures position and count calculations remain consistent throughout the entire session
        self.navigationReferenceArray = articles
        AppLogger.database.debug("🔒 N-1 BUG FIX: Locked navigation reference array with \(articles.count) articles")

        // Set current article - this is all we need for display
        if currentIndex >= 0 && currentIndex < articles.count {
            let article = articles[currentIndex]
            currentArticle = article
            
            // OPTIMIZATION: Use preloaded content if available
            if let preloadedArticle = preloadedArticle, preloadedArticle.id == article.id {
                currentArticleModel = preloadedArticle
                cacheModel(preloadedArticle)
            }
            
            // Cache preloaded rich text if available
            if preloadedTitle != nil || preloadedBody != nil || preloadedSummary != nil {
                cacheRichText(for: article.id, 
                             title: preloadedTitle, 
                             body: preloadedBody, 
                             summary: preloadedSummary)
                
                // Set initial content
                if let title = preloadedTitle {
                    cachedContentBySection["Title"] = title
                }
                if let body = preloadedBody {
                    cachedContentBySection["Body"] = body
                }
                if let summary = preloadedSummary {
                    cachedContentBySection["Summary"] = summary
                }
            }
        }

        // EVERYTHING ELSE DEFERRED - zero blocking
        
        // Store the original filtered articles and index for correct position display
        self.originalFilteredArticles = articles
        self.originalFilteredIndex = currentIndex
        
        // CRITICAL FIX: Re-enable background dataset fetching but with sort order consistency
        // This ensures position counters are correct while preventing the n-1 bug
        Task(priority: .background) {
            await fetchCompleteDatasetForNavigation()
        }
    }

    deinit {
        // Clean up subscriptions
        userDefaultsSubscriptions.forEach { $0.cancel() }
        userDefaultsSubscriptions.removeAll()
    }
    
    // MARK: - Lazy Initialization
    
    /// Performs deferred initialization after the view has appeared
    /// This keeps the initial presentation fast by deferring non-critical work
    @MainActor
    func performDeferredInitialization() {
        // Setup observers (lightweight but not needed for initial display)
        setupUserDefaultsObservers()
        
        // Load context and preload in background
        Task(priority: .background) {
            // Get article with context if needed
            if let currentArticleId = currentArticle?.id {
                if let model = await getCachedModelWithContext(for: currentArticleId) {
                    await MainActor.run {
                        currentArticleModel = model
                        cacheModel(model)
                    }
                }
            }
            
            // Preload adjacent articles for smooth navigation
            await preloadAdjacentArticles()
        }
    }

    // MARK: - Settings Observers

    /// Sets up observers for relevant UserDefaults changes
    private func setupUserDefaultsObservers() {
        let defaults = UserDefaults.standard

        // Observe any settings that might affect the detail view
        // For example, if there are reader preferences that affect how articles are displayed

        // Example: Monitor useReaderMode setting for potential preview section behavior
        defaults.publisher(for: \.useReaderMode)
            .removeDuplicates(by: { first, second in
                // Custom equality check to avoid compiler warning
                String(describing: first) == String(describing: second)
            })
            .sink { _ in
                // Refresh any UI or state that depends on this setting
                // For future implementation if needed
                // Note: No need to capture self if not using it in the closure
            }
            .store(in: &userDefaultsSubscriptions)
    }

    // MARK: - Public Methods - Navigation

    /// Navigates to the next or previous article
    /// - Parameter direction: The direction to navigate (next or previous)
    func navigateToArticle(direction: NavigationDirection) {
        let navigationStartTime = Date()
        
        // OPTIMIZATION: Don't cancel ongoing tasks unnecessarily
        // Only cancel if we're changing direction rapidly
        
        // STEP 1: Get and validate the next index FIRST
        guard let nextIndex = getNextValidIndex(direction: direction) else {
            AppLogger.database.debug("❌ No valid next index for navigation")
            return
        }
        
        // STEP 2: Double-check bounds before ANY state changes
        guard nextIndex >= 0 && nextIndex < articles.count else {
            AppLogger.database.debug("❌ Index out of bounds: \(nextIndex) (total: \(self.articles.count))")
            return
        }
        
        // STEP 3: Get the article and validate it exists
        let targetArticle = articles[nextIndex]
        let nextArticleId = targetArticle.id
        let currentArticleId = currentArticle?.id

        // OPTIMIZATION: Check cache FIRST before any logging
        let cachedModel = getCachedModel(for: nextArticleId)
        let cachedRichText = getCachedRichText(for: nextArticleId)
        
        // STEP 4: UPDATE STATE ATOMICALLY
        currentIndex = nextIndex
        currentArticle = targetArticle
        
        // Use cached model if available for instant update
        if let cached = cachedModel {
            currentArticleModel = cached
        }
        
        // Use cached rich text if available
        if let richText = cachedRichText {
            cachedContentBySection["Title"] = richText.title
            cachedContentBySection["Body"] = richText.body
            cachedContentBySection["Summary"] = richText.summary
        } else {
            // Clear content for clean slate
            cachedContentBySection = [:]
        }
        
        // Reset UI state
        expandedSections = Self.getDefaultExpandedSections()
        contentTransitionID = UUID()
        scrollToTopTrigger = UUID()
        isLoadingNextArticle = false
        
        // Add to navigation history
        if let currentId = currentArticleId {
            addToNavigationHistory(currentId)
        }
        
        // CRITICAL FIX: Ensure the count is accurate after navigation
        // This prevents situations where the total changes during navigation
        if !useOriginalPosition {
            updateNavigationCount(articles.count)
        }
        
        // Single UI update notification
        objectWillChange.send()
        
        let immediateTime = Date().timeIntervalSince(navigationStartTime)
        AppLogger.database.debug("⚡ NAVIGATION: \(String(format: "%.3f", immediateTime * 1000))ms")
        
        // OPTIMIZATION: Only do background work if not cached
        if cachedModel == nil {
            Task(priority: .high) { [weak self] in
                guard let self = self else { return }
                
                let model = await self.getCachedModelWithContext(for: nextArticleId)
                if let fetchedModel = model {
                    await MainActor.run {
                        self.cacheModel(fetchedModel)
                        self.currentArticleModel = fetchedModel
                        self.currentArticle = fetchedModel
                    }
                }
            }
        }
        
        // Mark as viewed in background
        Task(priority: .background) { [weak self] in
            try? await self?.markAsViewed()
        }
        
        // Preload adjacent (low priority)
        Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.preloadAdjacentArticles()
        }
    }
    
    // MARK: - Smart Content Preloading (Phase 2.3)
    
    /// Public wrapper for preloading adjacent articles - called from view
    func preloadAdjacentArticles() async {
        await preloadAdjacentArticlesInternal()
    }
    
    /// Preloads adjacent articles to improve navigation performance
    /// This implements Phase 2.3 of the optimization plan using enhanced PreloadManager
    /// Swift 6 compatible version using only sendable types
    private func preloadAdjacentArticlesInternal() async {
        // Extract only sendable data (UUIDs and current index) on MainActor to avoid Sendable issues
        let (currentIdx, currentId, articleIds) = await MainActor.run { 
            (currentIndex, currentArticle?.id, articles.map { $0.id })
        }
        
        guard !articleIds.isEmpty, currentId != nil else { return }
        
        AppLogger.database.debug("🚀 NewsDetailViewModel: Starting enhanced detail view preloading around index \(currentIdx)")
        
        // ENHANCED: Use specialized detail view summary preloading for smooth navigation
        let preloadManager = PreloadManager.shared
        
        // Use sendable article IDs for broader preloading coverage
        preloadManager.preloadArticlesByIds(articleIds, currentIndex: currentIdx)
        
        AppLogger.database.debug("✅ NewsDetailViewModel: Enhanced detail view preloading completed")
    }

    /// Validates and adjusts the current index if needed
    func validateAndAdjustIndex() {
        if !isCurrentIndexValid {
            if let targetID = currentArticle?.id,
               let newIndex = articles.firstIndex(where: { $0.id == targetID })
            {
                currentIndex = newIndex
            } else {
                currentIndex = max(0, articles.count - 1)
            }
        }
    }

    // MARK: - Full Dataset Access for Navigation
    
    /// Fetches the complete dataset for comprehensive navigation when needed
    /// This method bypasses memory-aware limits to ensure NewsDetailView can access all articles
    private func fetchCompleteDatasetForNavigation() async {
        guard let newsViewModel = newsViewModel else {
            AppLogger.database.debug("⚠️ No NewsViewModel reference available for full dataset fetch")
            return
        }
        
        AppLogger.database.debug("🔄 Fetching complete unfiltered dataset to prevent n-1 bug...")
        
        do {
            // CRITICAL N-1 BUG FIX: Fetch ALL articles for the topic WITHOUT ANY filtering
            // The n-1 bug occurs when navigation dataset has fewer articles than the list view
            // This happens because filters (bookmark, quality, read status) can exclude articles
            // that were visible in the original list due to race conditions or data inconsistencies
            let fullArticles = try await articleOperations.fetchArticlesWithSortOrder(
                topic: newsViewModel.selectedTopic == "All Topics" ? nil : newsViewModel.selectedTopic,
                showUnreadOnly: false, // CRITICAL: Always false - no read/unread filtering
                showBookmarkedOnly: false, // CRITICAL: Always false - no bookmark filtering  
                qualityFilter: "All", // CRITICAL: Always "All" - no quality filtering
                sortOrder: newsViewModel.sortOrder, // CRITICAL: Use same sort order as list view
                limit: nil, // No limit for full dataset
                context: .detailView // Use detail view context to bypass memory limits
            )
            
            await MainActor.run {
                // Store the current article ID before updating the array
                let currentArticleId = self.currentArticle?.id
                
                // Update articles array with complete unfiltered dataset
                self.articles = fullArticles.uniqued()
                
                // COMPREHENSIVE N-1 BUG FIX: Update the navigation count immediately
                self.updateNavigationCount(self.articles.count)
                
                // Find the current article in the new dataset and update index
                if let currentId = currentArticleId,
                   let newIndex = self.articles.firstIndex(where: { $0.id == currentId }) {
                    self.currentIndex = newIndex
                    AppLogger.database.debug("✅ Updated current index to \(newIndex) in unfiltered dataset")
                } else {
                    // Fallback: validate and adjust current index
                    self.validateAndAdjustIndex()
                }
                
                // CRITICAL FIX: Switch to using the complete dataset for position display
                // This ensures navigation position counters update correctly
                self.useOriginalPosition = false
                
                AppLogger.database.debug("✅ Complete unfiltered dataset loaded: \(fullArticles.count) articles available for navigation")
                AppLogger.database.debug("📍 Current article position: \(self.displayPosition) of \(self.displayTotal)")
                AppLogger.database.debug("🔄 Switched to complete dataset for position display")
            }
            
        } catch {
            AppLogger.database.error("❌ Failed to fetch complete dataset: \(error)")
        }
    }

    // MARK: - Public Methods - Content Loading

    /// Loads minimal content needed for the article header
    /// OPTIMIZATION: Skip if already cached
    func loadMinimalContent() async {
        guard let article = currentArticleModel ?? currentArticle else { return }
        
        // OPTIMIZATION: Check if we already have cached content
        if getCachedRichText(for: article.id) != nil {
            return // Already loaded
        }
        
        // Extract blobs and cache them
        let (title, body, summary) = await extractBlobsInTrueBackground(from: article)
        
        // Cache the extracted content
        if title != nil || body != nil || summary != nil {
            cacheRichText(for: article.id, title: title, body: body, summary: summary)
            
            // Update UI if this is still the current article
            if currentArticle?.id == article.id {
                await MainActor.run {
                    if let title = title {
                        cachedContentBySection["Title"] = title
                    }
                    if let body = body {
                        cachedContentBySection["Body"] = body
                    }
                    if let summary = summary {
                        cachedContentBySection["Summary"] = summary
                    }
                    objectWillChange.send()
                }
            }
        }
    }

    /// Verifies if an article blob was actually saved to the database
    /// - Parameters:
    ///   - field: The field to check
    ///   - articleId: The ID of the article
    /// - Returns: Boolean indicating if the blob exists in the database
    private func verifyBlobInDatabase(field: RichTextField, articleId: UUID) async -> Bool {
        // Try to fetch a completely fresh article from the database
        guard let freshArticle = await articleOperations.getArticleModelWithContext(byId: articleId) else {
            AppLogger.database.error("❌ Verification failed: Could not retrieve article model")
            return false
        }

        // Check if the blob exists
        let blob = field.getBlob(from: freshArticle)

        guard let blob = blob, !blob.isEmpty else {
            AppLogger.database.warning("⚠️ Verification failed: No blob found for \(String(describing: field))")
            return false
        }

        // Additionally check if we can unarchive it to a valid attributed string
        do {
            if let attributedString = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: blob
            ), attributedString.length > 0 {
                // Blob exists and is valid
                AppLogger.database.debug("✅ Verification passed: Valid blob found for \(String(describing: field)) (\(blob.count) bytes)")
                return true
            } else {
                AppLogger.database.error("❌ Verification failed: Blob unarchived to nil or empty string")
                return false
            }
        } catch {
            AppLogger.database.error("❌ Verification failed: Corrupt blob - \(error)")
            return false
        }
    }

    /// Loads content for a specific section using the centralized loader
    /// - Parameter section: The section to load content for
    @MainActor
    func loadContentForSection(_ section: String) {
        guard let article = currentArticleModel ?? currentArticle else { return }

        // Log beginning of section load
        AppLogger.database.debug("🔄 VIEW MODEL: Loading section \(section) for article \(article.id)")

        // CRITICAL FIX: Check for existing summary content in the article model FIRST
        // This prevents re-generating summaries that already exist
        if section == "Summary", let article = currentArticleModel ?? currentArticle {
            // Set loading state
            isSummaryLoading = true
            
            // Check if we have the summary content directly in the article model
            if let existingSummary = article.summary, !existingSummary.isEmpty {
                // Check if we already have a blob for this content
                if let summaryBlob = article.summaryBlob, !summaryBlob.isEmpty {
                    // Try to extract the existing blob first
                    if let existingAttributedString = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: summaryBlob
                    ) {
                        AppLogger.database.debug("✅ SUMMARY ALREADY EXISTS: Using pre-generated summary blob")
                        cachedContentBySection["Summary"] = existingAttributedString
                        isSummaryLoading = false
                        objectWillChange.send()
                        return
                    }
                }
                
                // If no blob exists, create attributed string from existing summary text
                if let attributedSummary = markdownToAttributedString(existingSummary, textStyle: "UIFontTextStyleBody") {
                    AppLogger.database.debug("✅ SUMMARY CONTENT EXISTS: Using existing summary text")
                    cachedContentBySection["Summary"] = attributedSummary
                    isSummaryLoading = false
                    objectWillChange.send()
                    
                    // Save as blob for future use
                    Task {
                        do {
                            let blobData = try NSKeyedArchiver.archivedData(
                                withRootObject: attributedSummary,
                                requiringSecureCoding: false
                            )
                            await MainActor.run {
                                article.summaryBlob = blobData
                                if let context = article.modelContext {
                                    try? context.save()
                                }
                            }
                        } catch {
                            AppLogger.database.error("❌ Failed to save summary blob: \(error)")
                        }
                    }
                    return
                } else {
                    // Summary exists but couldn't be converted
                    isSummaryLoading = false
                    AppLogger.database.debug("⚠️ Summary exists but couldn't be converted to attributed string")
                    return
                }
            } else {
                // No summary exists
                isSummaryLoading = false
                AppLogger.database.debug("ℹ️ No summary content available for this article")
                return
            }
        }

        // Check if we already have this content cached in the view model
        let cachedContent = getAttributedStringForSection(section)
        if cachedContent != nil {
            AppLogger.database.debug("✅ SECTION ALREADY LOADED: \(section) - using cached content")
            // Force a UI refresh to ensure the cached content is used
            objectWillChange.send()
            return
        }

        // Cancel existing task if any
        sectionLoadingTasks[section]?.cancel()

        // Create temporary loading indicator content
        provideTempContent(section, SectionNaming.fieldForSection(section), "Converting markdown to rich text...")
        
        // Set loading state for Summary section
        if section == "Summary" {
            isSummaryLoading = true
            
            // Add timeout protection for Summary loading
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds timeout
                await MainActor.run {
                    if self.isSummaryLoading {
                        AppLogger.database.warning("⚠️ Summary loading timed out after 10 seconds")
                        self.isSummaryLoading = false
                        self.cachedContentBySection["Summary"] = NSAttributedString(
                            string: "Summary loading timed out",
                            attributes: [.foregroundColor: UIColor.secondaryLabel]
                        )
                        self.objectWillChange.send()
                    }
                }
            }
        }

        // Create a task to load the content
        let task = Task(priority: .userInitiated) {
            let startTime = Date()

            // PHASE 3 FIX: Use cached context fetch to eliminate redundant database calls
            let contextArticle = await getCachedModelWithContext(for: article.id)

            // Use the centralized loader in ArticleOperations
            if let content = await articleOperations.loadContentForSection(section: section, articleId: article.id) {
                if !Task.isCancelled {
                    await MainActor.run {
                        // Update the content in the view model
                        updateSectionContent(section, SectionNaming.fieldForSection(section), content)
                        
                        // Clear loading state for Summary
                        if section == "Summary" {
                            self.isSummaryLoading = false
                        }

                        // Also update the currentArticleModel if needed
                        if self.currentArticleModel == nil || self.currentArticleModel?.modelContext == nil {
                            self.currentArticleModel = contextArticle
                        }
                    }

                    let totalTime = Date().timeIntervalSince(startTime)
                    AppLogger.database.debug("✅ VIEW MODEL: Section \(section) loaded in \(String(format: "%.4f", totalTime))s")

                    // Directly save the content to the article model for persistence
                    let field = SectionNaming.fieldForSection(section)
                    if let contextArticle = contextArticle {
                        do {
                            let blobData = try NSKeyedArchiver.archivedData(
                                withRootObject: content,
                                requiringSecureCoding: false
                            )

                            await MainActor.run {
                                field.setBlob(blobData, on: contextArticle)

                                // Save the context manually to ensure persistence
                                if let context = contextArticle.modelContext {
                                    try? context.save()
                                    AppLogger.database.debug("✅ Explicitly saved \(section) blob to database")
                                }
                            }
                        } catch {
                            AppLogger.database.error("❌ Failed to archive \(section) content: \(error)")
                        }
                    }

                    // Verify the blob was actually saved to the database
                    Task {
                        await articleOperations.verifyBlobStorage(
                            field: field,
                            articleId: article.id
                        )
                    }
                }
            } else {
                // Content loading failed, provide fallback
                if !Task.isCancelled {
                    await MainActor.run {
                        provideFallbackContent(section, SectionNaming.fieldForSection(section))
                        
                        // Clear loading state for Summary
                        if section == "Summary" {
                            self.isSummaryLoading = false
                        }
                    }
                }

                AppLogger.database.error("❌ VIEW MODEL: Failed to load content for section \(section)")
            }
        }

        // Store the task for potential cancellation
        sectionLoadingTasks[section] = task
    }

    /// Updates the content for a section
    /// - Parameters:
    ///   - section: The section to update
    ///   - field: The rich text field for the section
    ///   - content: The content to set
    @MainActor
    private func updateSectionContent(_ section: String, _ field: RichTextField, _ content: NSAttributedString) {
        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // Store all content in cachedContentBySection for sections that need it
        switch field {
        case .summary:
            cachedContentBySection["Summary"] = content
        case .criticalAnalysis:
            cachedContentBySection["Critical Analysis"] = content
        case .logicalFallacies:
            cachedContentBySection["Logical Fallacies"] = content
        case .sourceAnalysis:
            cachedContentBySection["Source Analysis"] = content
        case .relationToTopic:
            cachedContentBySection["Relevance"] = content
        case .additionalInsights:
            cachedContentBySection["Context & Perspective"] = content
        case .actionRecommendations:
            cachedContentBySection["What You Can Do"] = content
        case .talkingPoints:
            cachedContentBySection["Talking Points"] = content
        case .eli5:
            cachedContentBySection["Simple Breakdown"] = content
        case .clusterSummary:
            cachedContentBySection["Cluster Summary"] = content
        default:
            cachedContentBySection[section] = content
        }

        // Force UI refresh
        objectWillChange.send()

        // Clear loading state
        sectionLoadingTasks[section] = nil
    }

    /// Provides fallback content when loading fails
    /// - Parameters:
    ///   - section: The section that failed to load
    ///   - field: The rich text field for the section
    @MainActor
    private func provideFallbackContent(_ section: String, _ field: RichTextField) {
        let fallbackString = NSAttributedString(
            string: "Unable to load content. Tap to retry.",
            attributes: [.foregroundColor: UIColor.systemRed]
        )

        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // Store all fallback content in cachedContentBySection for sections that need it
        switch field {
        case .summary:
            cachedContentBySection["Summary"] = fallbackString
        case .criticalAnalysis:
            cachedContentBySection["Critical Analysis"] = fallbackString
        case .logicalFallacies:
            cachedContentBySection["Logical Fallacies"] = fallbackString
        case .sourceAnalysis:
            cachedContentBySection["Source Analysis"] = fallbackString
        case .relationToTopic:
            cachedContentBySection["Relevance"] = fallbackString
        case .additionalInsights:
            cachedContentBySection["Context & Perspective"] = fallbackString
        case .actionRecommendations:
            cachedContentBySection["What You Can Do"] = fallbackString
        case .talkingPoints:
            cachedContentBySection["Talking Points"] = fallbackString
        case .eli5:
            cachedContentBySection["Simple Breakdown"] = fallbackString
        case .clusterSummary:
            cachedContentBySection["Cluster Summary"] = fallbackString
        default:
            cachedContentBySection[section] = fallbackString
        }

        // Force UI refresh
        objectWillChange.send()

        // Clear loading state
        sectionLoadingTasks[section] = nil
    }

    /// Helper function to add timeout to async operations
    private func withTimeout<T>(duration: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                try await operation()
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                throw TimeoutError()
            }

            // Return the first completed result or throw
            guard let result = try await group.next() else {
                throw TimeoutError()
            }

            // Cancel any remaining tasks
            group.cancelAll()

            return result
        }
    }

    /// Error type for timeout operations
    private struct TimeoutError: Error {
        var localizedDescription: String {
            return "Operation timed out"
        }
    }

    // Add this helper method for debugging generation issues
    private func logGenerationDetails(_ field: RichTextField, _ article: ArticleModel) {
        // Log more details about content to help diagnose issues
        let textContent = field.getMarkdownText(from: article)

        AppLogger.database.debug("📊 Generation Diagnostic:")
        AppLogger.database.debug("- Field: \(String(describing: field))")
        AppLogger.database.debug("- Has content: \(textContent != nil)")
        AppLogger.database.debug("- Content length: \(textContent?.count ?? 0)")
        AppLogger.database.debug("- Article ID: \(article.id)")
        AppLogger.database.debug("- JSON URL: \(article.jsonURL)")

        // Log first 150 chars of content as a sample
        if let content = textContent, !content.isEmpty {
            let sampleLength = min(150, content.count)
            let sample = String(content.prefix(sampleLength))
            AppLogger.database.debug("📝 Content sample: \"\(sample)\"...")
        }
    }

    // Add this helper method to show temporary conversion state
    @MainActor
    private func provideTempContent(_ section: String, _ field: RichTextField, _ message: String) {
        // Create a temporary attributed string to show status
        let tempString = NSAttributedString(
            string: message,
            attributes: [
                .font: UIFont.italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                .foregroundColor: UIColor.secondaryLabel,
            ]
        )

        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // Store all temp content in cachedContentBySection for sections that need it
        switch field {
        case .summary:
            cachedContentBySection["Summary"] = tempString
        case .criticalAnalysis:
            cachedContentBySection["Critical Analysis"] = tempString
        case .logicalFallacies:
            cachedContentBySection["Logical Fallacies"] = tempString
        case .sourceAnalysis:
            cachedContentBySection["Source Analysis"] = tempString
        case .relationToTopic:
            cachedContentBySection["Relevance"] = tempString
        case .additionalInsights:
            cachedContentBySection["Context & Perspective"] = tempString
        case .actionRecommendations:
            cachedContentBySection["What You Can Do"] = tempString
        case .talkingPoints:
            cachedContentBySection["Talking Points"] = tempString
        case .eli5:
            cachedContentBySection["Simple Breakdown"] = tempString
        case .clusterSummary:
            cachedContentBySection["Cluster Summary"] = tempString
        default:
            cachedContentBySection[section] = tempString
        }

        // Notify UI of change
        objectWillChange.send()
    }

    /// Generates all rich text content for an article
    func generateAllRichTextContent() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        isLoading = true

        let richTextContent = articleOperations.generateAllRichTextContent(for: article)

        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // Store all content in cachedContentBySection for sections that need it
        if let content = richTextContent[.summary] {
            cachedContentBySection["Summary"] = content
        }

        if let content = richTextContent[.criticalAnalysis] {
            cachedContentBySection["Critical Analysis"] = content
        }

        if let content = richTextContent[.logicalFallacies] {
            cachedContentBySection["Logical Fallacies"] = content
        }

        if let content = richTextContent[.sourceAnalysis] {
            cachedContentBySection["Source Analysis"] = content
        }

        if let content = richTextContent[.relationToTopic] {
            cachedContentBySection["Relevance"] = content
        }

        if let content = richTextContent[.additionalInsights] {
            cachedContentBySection["Context & Perspective"] = content
        }

        if let content = richTextContent[.actionRecommendations] {
            cachedContentBySection["What You Can Do"] = content
        }

        if let content = richTextContent[.talkingPoints] {
            cachedContentBySection["Talking Points"] = content
        }

        if let content = richTextContent[.eli5] {
            cachedContentBySection["Simple Breakdown"] = content
        }

        isLoading = false
    }

    // MARK: - Public Methods - Article Operations

    /// Toggles the read status of the current article
    func toggleReadStatus() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        do {
            try await articleOperations.toggleReadStatus(for: article)
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling read status: \(error)")
        }
    }

    /// Toggles the bookmarked status of the current article
    func toggleBookmark() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        do {
            try await articleOperations.toggleBookmark(for: article)
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling bookmark status: \(error)")
        }
    }

    /// Deletes the current article
    func deleteArticle() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        do {
            try await articleOperations.deleteArticle(article)

            // Add to deleted IDs
            deletedIDs.insert(article.id)

            // Navigate to next valid article
            if currentIndex < articles.count - 1 {
                navigateToArticle(direction: .next)
            } else {
                // Exit detail view if this was the last article
                // This would need to be handled by the detail view controller
            }
        } catch {
            self.error = error
            AppLogger.database.error("Error deleting article: \(error)")
        }
    }

    /// Marks the current article as viewed
    func markAsViewed() async throws {
        guard let article = currentArticleModel ?? currentArticle else { return }

        // Always mark as read when viewing an article, even if already viewed
        // This ensures that the database state is consistent
        if !article.isViewed {
            try await articleOperations.toggleReadStatus(for: article)
        } else {
            // Even though it's already viewed, make sure UI is updated
            // This helps ensure consistent UI state between opened articles and navigated articles
            objectWillChange.send()
        }
    }

    // MARK: - Section Management

    /// Toggles a section's expanded state
    /// - Parameter section: The section to toggle
    func toggleSection(_ section: String) {
        let wasExpanded = expandedSections[section] ?? false
        expandedSections[section] = !wasExpanded

        if !wasExpanded, needsConversion(section) {
            // Only load rich text content when newly expanding sections that need conversion
            loadContentForSection(section)
        }
    }

    /// Scrolls to a specific section
    /// - Parameter section: The section to scroll to
    func scrollToSection(_ section: String) {
        // Ensure the section is expanded
        expandedSections[section] = true

        // Set the scroll section
        scrollToSection = section

        // Load content if needed
        if needsConversion(section) {
            loadContentForSection(section)
        }
    }

    // MARK: - Private Methods

    /// Gets the attributed string for a section if it exists
    /// - Parameter section: The section to get content for
    /// - Returns: The attributed string if it exists, nil otherwise
    func getAttributedStringForSection(_ section: String) -> NSAttributedString? {
        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // All content is now stored in cachedContentBySection
        return cachedContentBySection[section]
    }

    /// Checks if a section is currently loading
    /// - Parameter section: The section to check
    /// - Returns: Whether the section is loading
    func isSectionLoading(_ section: String) -> Bool {
        return sectionLoadingTasks[section] != nil
    }

    /// Checks if a section needs rich text conversion
    /// - Parameter section: The section to check
    /// - Returns: Whether the section needs conversion
    func needsConversion(_ section: String) -> Bool {
        switch section {
        case "Summary", "Critical Analysis", "Logical Fallacies",
             "Source Analysis", "Relevance", "Context & Perspective",
             "What You Can Do", "Talking Points", "Simple Breakdown":
            return true
        case "Argus Engine Stats", "Preview", "Related Articles":
            return false
        default:
            return false
        }
    }

    /// Gets the next valid index for navigation
    /// - Parameter direction: The direction to navigate
    /// - Returns: The next valid index, or nil if none exists
    private func getNextValidIndex(direction: NavigationDirection) -> Int? {
        var newIndex = direction == .next ? currentIndex + 1 : currentIndex - 1

        // Check if the index is valid and not deleted
        while newIndex >= 0, newIndex < articles.count {
            let candidate = articles[newIndex]
            if !deletedIDs.contains(candidate.id) {
                return newIndex
            }
            newIndex += (direction == .next ? 1 : -1)
        }

        return nil
    }

    /// Checks if the current index is valid
    private var isCurrentIndexValid: Bool {
        return currentIndex >= 0 && currentIndex < articles.count
    }

    /// Clears all cached rich text content
    private func clearRichTextContent() {
        // REMOVED: No longer caching attributed strings - using direct data binding instead
        // Only clear the section cache
        cachedContentBySection = [:]
    }
    
    // MARK: - Navigation Dataset Locking (N-1 Bug Fix)
    
    /// Flag to prevent background filtering from affecting the navigation dataset
    private var navigationDatasetLocked = false
    
    /// Locks the navigation dataset to prevent background filtering operations from affecting it
    /// This is critical for preventing the n-1 bug where articles disappear during navigation
    func lockNavigationDataset() {
        navigationDatasetLocked = true
        AppLogger.database.debug("🔒 NAVIGATION DATASET LOCKED: Preventing background filtering from affecting navigation")
    }
    
    /// Unlocks the navigation dataset (called when detail view is dismissed)
    func unlockNavigationDataset() {
        navigationDatasetLocked = false
        AppLogger.database.debug("🔓 NAVIGATION DATASET UNLOCKED: Normal filtering behavior restored")
    }
    
    // MARK: - Enhanced Cache Management (Phase 1.2) - CRITICAL FIX
    
    private func getCachedModel(for articleId: UUID) -> ArticleModel? {
        return modelCache[articleId]
    }
    
    private func getCachedRichText(for articleId: UUID) -> RichTextContent? {
        return richTextCache.get(articleId)
    }
    
    private func cacheModel(_ model: ArticleModel) {
        // Remove oldest entries if cache is full
        if modelCache.count >= maxCacheSize {
            let keysToRemove = Array(modelCache.keys.prefix(modelCache.count - maxCacheSize + 1))
            for key in keysToRemove {
                modelCache.removeValue(forKey: key)
                richTextCache.removeValue(forKey: key) // Also remove rich text cache
            }
        }
        
        modelCache[model.id] = model
        AppLogger.database.debug("📦 CACHED MODEL: \(model.id.uuidString.prefix(8)) - Cache size: \(self.modelCache.count)")
    }
    
    private func cacheRichText(for articleId: UUID, title: NSAttributedString?, body: NSAttributedString?, summary: NSAttributedString?) {
        // Only cache if we have at least one piece of content
        if title != nil || body != nil || summary != nil {
            let content = RichTextContent(title: title, body: body, summary: summary)
            richTextCache.set(articleId, content)
            AppLogger.database.debug("📝 CACHED RICH TEXT: \(articleId.uuidString.prefix(8)) - Title: \(title != nil), Body: \(body != nil), Summary: \(summary != nil)")
        }
    }
    
    private func addToNavigationHistory(_ articleId: UUID) {
        // Remove if already exists to avoid duplicates
        navigationHistory.removeAll { $0 == articleId }
        
        // Add to front of history
        navigationHistory.insert(articleId, at: 0)
        
        // Trim to max size
        if navigationHistory.count > maxHistorySize {
            navigationHistory = Array(navigationHistory.prefix(maxHistorySize))
        }
        
        AppLogger.database.debug("📚 NAVIGATION HISTORY: Added \(articleId.uuidString.prefix(8)) - History size: \(self.navigationHistory.count)")
    }
    
    private func isInNavigationHistory(_ articleId: UUID) -> Bool {
        return navigationHistory.contains(articleId)
    }

    /// Cancels all active section loading tasks
    private func cancelAllTasks() {
        for (_, task) in sectionLoadingTasks {
            task.cancel()
        }
        sectionLoadingTasks = [:]
    }

    /// Default expanded sections
    static func getDefaultExpandedSections() -> [String: Bool] {
        return [
            "Summary": true,
            "Relevance": false,
            "Simple Breakdown": false,
            "Context & Perspective": false,
            "Talking Points": false,
            "What You Can Do": false,
            "Critical Analysis": false,
            "Logical Fallacies": false,
            "Source Analysis": false,
            "Argus Engine Stats": false,
            "Preview": false,
            "Related Articles": false,
        ]
    }
    
    // MARK: - Position Display Methods
    
    /// Gets the current position for display purposes
    /// COMPREHENSIVE N-1 BUG FIX: Always use stable counting that won't change
    var displayPosition: Int {
        if let currentId = currentArticle?.id {
            // FIXED: Use the complete navigation dataset when available
            if !useOriginalPosition, !articles.isEmpty {
                if let position = articles.firstIndex(where: { $0.id == currentId }) {
                    return position + 1
                }
            }
            
            // Fallback to navigation reference array for initial display
            if let position = navigationReferenceArray.firstIndex(where: { $0.id == currentId }) {
                return position + 1
            }
        }
        
        // Final fallback: use original index + 1
        return max(originalFilteredIndex + 1, 1)
    }
    
    /// Gets the total count for display purposes  
    /// COMPREHENSIVE N-1 BUG FIX: Use the most accurate count available
    var displayTotal: Int {
        // Priority 1: Use complete navigation dataset when available (most accurate)
        if !useOriginalPosition, !articles.isEmpty {
            return articles.count
        }
        
        // Priority 2: Use updated count from background query if available
        if let updatedCount = updatedNavigationCount {
            return max(updatedCount, 1)
        }
        
        // Priority 3: Use navigation reference array as fallback
        return max(navigationReferenceArray.count, 1)
    }
    
    /// Updated navigation count from background query (simple approach)
    @Published private var updatedNavigationCount: Int?
    
    /// Updates the navigation count with the accurate total from background query
    /// This implements the simple approach: placeholder first, then accurate count
    func updateNavigationCount(_ count: Int) {
        updatedNavigationCount = count
        AppLogger.database.debug("📊 Navigation count updated: \(count)")
    }
}

// Extension to make ArticleModel uniquable for collections
extension ArticleModel {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Array Extensions

extension Array where Element: Identifiable {
    /// Returns a new array with duplicate IDs removed, keeping the first occurrence
    func uniqued() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
