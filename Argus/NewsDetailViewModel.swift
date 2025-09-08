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

    /// All available articles for navigation
    @Published var articles: [ArticleModel]

    /// All articles in the database (may be used for related articles)
    @Published var allArticles: [ArticleModel]

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
    
    // MARK: - Model Cache (Phase 1.2)
    private var modelCache: [UUID: ArticleModel] = [:]
    private let maxCacheSize = 10

    // MARK: - Rich Text Content Cache

    /// Cached title attributed string
    @Published var titleAttributedString: NSAttributedString?

    /// Cached body attributed string
    @Published var bodyAttributedString: NSAttributedString?

    /// Cached summary attributed string
    @Published var summaryAttributedString: NSAttributedString?

    /// Cached critical analysis attributed string
    @Published var criticalAnalysisAttributedString: NSAttributedString?

    /// Cached logical fallacies attributed string
    @Published var logicalFallaciesAttributedString: NSAttributedString?

    /// Cached source analysis attributed string
    @Published var sourceAnalysisAttributedString: NSAttributedString?

    /// Additional cached content by section
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
    private weak var newsViewModel: NewsViewModel?

    // MARK: - Background Processing (Phase 2.2)

    /// Extracts blobs from ArticleModel in background using parallel processing
    /// - Parameter model: The ArticleModel containing the blobs
    /// - Returns: A tuple containing extracted title, body, and summary attributed strings
    @MainActor
    private func extractBlobsInBackground(from model: ArticleModel) async -> (title: NSAttributedString?, body: NSAttributedString?, summary: NSAttributedString?) {
        // Extract blob data first on main actor to avoid Sendable issues
        let titleBlob = model.titleBlob
        let bodyBlob = model.bodyBlob
        let summaryBlob = model.summaryBlob
        
        // Since NSAttributedString is not Sendable, we need to process synchronously on MainActor
        var title: NSAttributedString?
        var body: NSAttributedString?
        var summary: NSAttributedString?
        
        // Extract title blob if available
        if let titleBlobData = titleBlob {
            title = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: titleBlobData
            )
        }
        
        // Extract body blob if available  
        if let bodyBlobData = bodyBlob {
            body = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: bodyBlobData
            )
        }
        
        // Extract summary blob if available
        if let summaryBlobData = summaryBlob {
            summary = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: summaryBlobData
            )
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
        // Apply uniqueness to prevent duplicate IDs in collections
        let uniqueArticles = articles.uniqued()
        let uniqueAllArticles = allArticles.uniqued()

        // Store the initially expanded section
        self.initiallyExpandedSection = initiallyExpandedSection

        self.articles = uniqueArticles
        self.allArticles = uniqueAllArticles
        self.currentIndex = min(currentIndex, uniqueArticles.count - 1)
        self.articleOperations = articleOperations
        self.newsViewModel = newsViewModel

        // Set initial preloaded content if available and pre-cache for performance
        if let preloadedArticle = preloadedArticle {
            currentArticle = preloadedArticle
            currentArticleModel = preloadedArticle
            // Phase 1.2: Cache the preloaded article for faster future access
            cacheModel(preloadedArticle)
        } else if currentIndex >= 0, currentIndex < uniqueArticles.count {
            let initialArticle = uniqueArticles[currentIndex]
            currentArticle = initialArticle
            currentArticleModel = initialArticle
            // Phase 1.2: Cache the initial article for faster navigation
            cacheModel(initialArticle)
        }

        titleAttributedString = preloadedTitle
        bodyAttributedString = preloadedBody
        summaryAttributedString = preloadedSummary

        // Set initial expanded sections
        if let section = initiallyExpandedSection {
            expandedSections[section] = true
        }

        // Set default expanded sections
        if expandedSections["Summary"] == nil {
            expandedSections["Summary"] = true
        }

        // Phase 2.1: Load from rich text cache if available and no preloaded content
        if let articleId = currentArticle?.id,
           let newsViewModel = newsViewModel,
           let cachedContent = newsViewModel.getCachedRichText(for: articleId) {
            
            // Use cached content if we don't already have preloaded content
            if titleAttributedString == nil {
                titleAttributedString = cachedContent.title
            }
            if bodyAttributedString == nil {
                bodyAttributedString = cachedContent.body
            }
            if summaryAttributedString == nil {
                summaryAttributedString = cachedContent.summary
            }
        }

        // Record container diagnostics for debugging
        containerDiagnostics = "Container info: \(String(describing: SwiftDataContainer.shared.container))"

        // Ensure we have a valid ArticleModel with context
        Task {
            if let articleId = currentArticle?.id, currentArticleModel?.modelContext == nil {
                    let model = await articleOperations.getArticleModelWithContext(byId: articleId)

                if let model = model {
                        await MainActor.run {
                        self.currentArticleModel = model
                    }
                }
            }
        }

        // Setup observers for settings changes
        setupUserDefaultsObservers()
        
        // Fetch full dataset if needed for comprehensive navigation
        if needsFullDataset {
            Task(priority: .userInitiated) {
                await self.fetchFullDatasetForNavigation()
            }
        }
        
        // Phase 2.3: Start initial preloading of adjacent articles after initialization
        Task.detached(priority: .background) {
            // Start preloading immediately - no need to wait
            await self.preloadAdjacentArticles()
        }
    }

    deinit {
        // Clean up subscriptions
        userDefaultsSubscriptions.forEach { $0.cancel() }
        userDefaultsSubscriptions.removeAll()
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
        // Cancel any ongoing tasks
        cancelAllTasks()

        // Get the next valid index
        guard let nextIndex = getNextValidIndex(direction: direction),
              nextIndex >= 0, nextIndex < articles.count
        else {
            return
        }

        // Get the article - important to keep this until we load the new one
        let targetArticle = articles[nextIndex]
        let nextArticleId = targetArticle.id

        // PERFORMANCE OPTIMIZATION: Immediate UI update with cached content
        Task(priority: .userInitiated) {
            let startTime = Date()

            // 1. IMMEDIATE UI UPDATE: Update UI state first for instant responsiveness
            await MainActor.run {
                // Update index immediately
                currentIndex = nextIndex
                
                // Clear previous content
                clearRichTextContent()
                
                // Set article immediately (even if we don't have formatted content yet)
                currentArticle = targetArticle
                
                // Reset expanded sections
                expandedSections = Self.getDefaultExpandedSections()
                
                // Force UI refresh immediately for instant navigation feel
                contentTransitionID = UUID()
                scrollToTopTrigger = UUID()
                
                // Show loading state only if we need to fetch content
                isLoadingNextArticle = true
            }

            // 2. FAST CONTENT LOADING: Try cache first, then extract blobs
            var model: ArticleModel? = getCachedModel(for: nextArticleId)
            
            if model == nil {
                model = await articleOperations.getArticleModelWithContext(byId: nextArticleId)
                if let fetchedModel = model {
                    cacheModel(fetchedModel)
                }
            }

            // 3. OPTIMIZED BLOB EXTRACTION: Only extract if blobs exist
            var extractedTitle: NSAttributedString? = nil
            var extractedBody: NSAttributedString? = nil
            var extractedSummary: NSAttributedString? = nil

            if let model = model {
                // Quick check if blobs exist before extraction
                let hasBlobs = model.titleBlob != nil || model.bodyBlob != nil || model.summaryBlob != nil
                
                if hasBlobs {
                    let (title, body, summary) = await extractBlobsInBackground(from: model)
                    extractedTitle = title
                    extractedBody = body
                    extractedSummary = summary
                }
            }

            // 4. BATCH CONTENT UPDATE: Update all content at once
            await MainActor.run {
                // Update model reference
                if let model = model {
                    currentArticleModel = model
                    currentArticle = model
                }

                // Set formatted content if available
                if let title = extractedTitle {
                    titleAttributedString = title
                }
                if let body = extractedBody {
                    bodyAttributedString = body
                }
                if let summary = extractedSummary {
                    summaryAttributedString = summary
                }
                
                // Clear loading state immediately
                isLoadingNextArticle = false
                
                // Single UI update for all changes
                objectWillChange.send()
            }

            // 5. BACKGROUND OPERATIONS: Do heavy lifting after UI is responsive
            
            // Mark as viewed (non-blocking)
            Task.detached(priority: .background) {
                try? await self.markAsViewed()
            }

            // Generate missing content only if needed (non-blocking)
            if titleAttributedString == nil || bodyAttributedString == nil {
                Task.detached(priority: .background) {
                    await self.loadMinimalContent()
                    AppLogger.database.debug("⚙️ Generated missing title/body content for article \(nextArticleId)")
                }
            }

            // Load summary content if expanded and missing (non-blocking)
            if expandedSections["Summary"] == true, summaryAttributedString == nil {
                Task.detached(priority: .background) {
                    await MainActor.run {
                        self.loadContentForSection("Summary")
                    }
                    AppLogger.database.debug("⚙️ Generated missing summary content for article \(nextArticleId)")
                }
            }

            // Preload adjacent articles (lowest priority)
            Task.detached(priority: .utility) {
                await self.preloadAdjacentArticles()
            }

            let loadTime = Date().timeIntervalSince(startTime)
            AppLogger.database.debug("✅ Article \(nextArticleId) navigation completed in \(String(format: "%.3f", loadTime)) seconds")
        }
    }
    
    // MARK: - Smart Content Preloading (Phase 2.3)
    
    /// Preloads adjacent articles to improve navigation performance
    /// This implements Phase 2.3 of the optimization plan using enhanced PreloadManager
    /// Swift 6 compatible version using only sendable types
    private func preloadAdjacentArticles() async {
        // Extract only sendable data (UUIDs and Int) on MainActor to avoid Sendable issues
        let (currentIdx, articleIds) = await MainActor.run { 
            (currentIndex, articles.map { $0.id })
        }
        
        guard !articleIds.isEmpty else { return }
        
        AppLogger.database.debug("🚀 NewsDetailViewModel: Triggering enhanced preloading for Next-5 and Previous-5 articles around index \(currentIdx)")
        
        // Use the enhanced PreloadManager with Swift 6 compatible method using only sendable UUIDs
        PreloadManager.shared.preloadArticlesByIds(articleIds, currentIndex: currentIdx)
        
        AppLogger.database.debug("✅ NewsDetailViewModel: Enhanced preloading initiated")
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
    private func fetchFullDatasetForNavigation() async {
        guard let newsViewModel = newsViewModel else {
            AppLogger.database.debug("⚠️ No NewsViewModel reference available for full dataset fetch")
            return
        }
        
        AppLogger.database.debug("🔄 Fetching full dataset for comprehensive navigation...")
        
        do {
            // Use ArticleOperations with .detailView context to bypass memory limits
            let fullArticles = try await articleOperations.fetchArticles(
                topic: newsViewModel.selectedTopic == "All Topics" ? nil : newsViewModel.selectedTopic,
                showUnreadOnly: newsViewModel.showUnreadOnly,
                showBookmarkedOnly: newsViewModel.showBookmarkedOnly,
                qualityFilter: newsViewModel.qualityFilter,
                limit: nil, // No limit for full dataset
                context: .detailView // Use detail view context to bypass memory limits
            )
            
            await MainActor.run {
                // Update articles array with full dataset
                self.articles = fullArticles.uniqued()
                
                // Validate and adjust current index if needed
                self.validateAndAdjustIndex()
                
                AppLogger.database.debug("✅ Full dataset loaded: \(fullArticles.count) articles available for navigation")
            }
            
        } catch {
            AppLogger.database.error("❌ Failed to fetch full dataset: \(error)")
        }
    }

    // MARK: - Public Methods - Content Loading

    /// Loads minimal content needed for the article header
    /// Phase 2.2: Uses background blob processing for optimal performance
    func loadMinimalContent() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        // Log what's available for debugging
        let hasTitleBlob = article.titleBlob != nil
        let hasBodyBlob = article.bodyBlob != nil
        AppLogger.database.debug("⚙️ loadMinimalContent: Title blob exists: \(hasTitleBlob), Body blob exists: \(hasBodyBlob)")

        // Phase 2.2: Use background blob processing for critical content
        AppLogger.database.debug("⚙️ Loading initial content using background blob processing for article \(article.id)")

        let startTime = Date()
        
        // Extract what we can from blobs using background processing
        let (extractedTitle, extractedBody, extractedSummary) = await extractBlobsInBackground(from: article)
        
        // Update content atomically on main thread
        await MainActor.run {
            if titleAttributedString == nil, let title = extractedTitle {
                titleAttributedString = title
                AppLogger.database.debug("✅ Title loaded from blob via background processing")
            }
            
            if bodyAttributedString == nil, let body = extractedBody {
                bodyAttributedString = body
                AppLogger.database.debug("✅ Body loaded from blob via background processing")
            }
            
            if summaryAttributedString == nil, let summary = extractedSummary {
                summaryAttributedString = summary
                AppLogger.database.debug("✅ Summary loaded from blob via background processing")
            }
        }

        // Generate missing content if blob extraction failed
        if titleAttributedString == nil {
            let generateStartTime = Date()
            titleAttributedString = articleOperations.getAttributedContent(
                for: .title,
                from: article,
                createIfMissing: true
            )
            let generateTime = Date().timeIntervalSince(generateStartTime)
            AppLogger.database.debug("✅ Title generated in \(String(format: "%.3f", generateTime))s")
        }

        if bodyAttributedString == nil {
            let generateStartTime = Date()
            bodyAttributedString = articleOperations.getAttributedContent(
                for: .body,
                from: article,
                createIfMissing: true
            )
            let generateTime = Date().timeIntervalSince(generateStartTime)
            AppLogger.database.debug("✅ Body generated in \(String(format: "%.3f", generateTime))s")
        }

        let totalTime = Date().timeIntervalSince(startTime)
        AppLogger.database.debug("⚡ loadMinimalContent completed in \(String(format: "%.3f", totalTime)) seconds")
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

        // IMPROVEMENT: Create a reliable in-memory content cache check
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

        // Create a task to load the content
        let task = Task(priority: .userInitiated) {
            let startTime = Date()

            // Make sure we have an article with a valid context before proceeding
            let contextArticle = await articleOperations.getArticleModelWithContext(byId: article.id)

            // Use the centralized loader in ArticleOperations
            if let content = await articleOperations.loadContentForSection(section: section, articleId: article.id) {
                if !Task.isCancelled {
                    await MainActor.run {
                        // Update the content in the view model
                        updateSectionContent(section, SectionNaming.fieldForSection(section), content)

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
        // Store in appropriate property - FIXED: Use correct section names
        switch field {
        case .summary:
            summaryAttributedString = content
        case .criticalAnalysis:
            criticalAnalysisAttributedString = content
        case .logicalFallacies:
            logicalFallaciesAttributedString = content
        case .sourceAnalysis:
            sourceAnalysisAttributedString = content
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

        // Store the fallback in the appropriate property - FIXED: Use correct section names
        switch field {
        case .summary:
            summaryAttributedString = fallbackString
        case .criticalAnalysis:
            criticalAnalysisAttributedString = fallbackString
        case .logicalFallacies:
            logicalFallaciesAttributedString = fallbackString
        case .sourceAnalysis:
            sourceAnalysisAttributedString = fallbackString
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
    private func withTimeout<T>(duration: Duration, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                try await operation()
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(for: duration)
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

        // Store in the appropriate property - FIXED: Use correct section names
        switch field {
        case .summary:
            summaryAttributedString = tempString
        case .criticalAnalysis:
            criticalAnalysisAttributedString = tempString
        case .logicalFallacies:
            logicalFallaciesAttributedString = tempString
        case .sourceAnalysis:
            sourceAnalysisAttributedString = tempString
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

        // Update cached content - FIXED: Use correct section names
        if let content = richTextContent[.title] {
            titleAttributedString = content
        }

        if let content = richTextContent[.body] {
            bodyAttributedString = content
        }

        if let content = richTextContent[.summary] {
            summaryAttributedString = content
        }

        if let content = richTextContent[.criticalAnalysis] {
            criticalAnalysisAttributedString = content
        }

        if let content = richTextContent[.logicalFallacies] {
            logicalFallaciesAttributedString = content
        }

        if let content = richTextContent[.sourceAnalysis] {
            sourceAnalysisAttributedString = content
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
        switch section {
        case "Summary":
            return summaryAttributedString
        case "Critical Analysis":
            return criticalAnalysisAttributedString
        case "Logical Fallacies":
            return logicalFallaciesAttributedString
        case "Source Analysis":
            return sourceAnalysisAttributedString
        case "Relevance":
            return cachedContentBySection["Relevance"]
        case "Context & Perspective":
            return cachedContentBySection["Context & Perspective"]
        case "What You Can Do":
            return cachedContentBySection["What You Can Do"]
        case "Talking Points":
            return cachedContentBySection["Talking Points"]
        case "Simple Breakdown":
            return cachedContentBySection["Simple Breakdown"]
        default:
            return cachedContentBySection[section]
        }
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
        titleAttributedString = nil
        bodyAttributedString = nil
        summaryAttributedString = nil
        criticalAnalysisAttributedString = nil
        logicalFallaciesAttributedString = nil
        sourceAnalysisAttributedString = nil
        cachedContentBySection = [:]
    }
    
    // MARK: - Cache Management (Phase 1.2)
    
    private func getCachedModel(for articleId: UUID) -> ArticleModel? {
        return modelCache[articleId]
    }
    
    private func cacheModel(_ model: ArticleModel) {
        // Remove oldest entries if cache is full
        if modelCache.count >= maxCacheSize {
            let keysToRemove = Array(modelCache.keys.prefix(modelCache.count - maxCacheSize + 1))
            for key in keysToRemove {
                modelCache.removeValue(forKey: key)
            }
        }
        
        modelCache[model.id] = model
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
