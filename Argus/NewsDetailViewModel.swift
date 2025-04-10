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
    init(
        articles: [ArticleModel],
        allArticles: [ArticleModel],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil,
        preloadedArticle: ArticleModel? = nil,
        preloadedTitle: NSAttributedString? = nil,
        preloadedBody: NSAttributedString? = nil,
        preloadedSummary: NSAttributedString? = nil,
        articleOperations: ArticleOperations = ArticleOperations()
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

        // Set initial preloaded content if available
        if let preloadedArticle = preloadedArticle {
            currentArticle = preloadedArticle
            currentArticleModel = preloadedArticle
        } else if currentIndex >= 0 && currentIndex < uniqueArticles.count {
            currentArticle = uniqueArticles[currentIndex]
            currentArticleModel = uniqueArticles[currentIndex]
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

        // Record container diagnostics for debugging
        containerDiagnostics = "Container info: \(String(describing: SwiftDataContainer.shared.container))"

        // Ensure we have a valid ArticleModel with context
        Task {
            if let articleId = currentArticle?.id, currentArticleModel?.modelContext == nil {
                AppLogger.database.debug("🔍 ViewModel Init: Ensuring ArticleModel has valid context for ID: \(articleId)")
                let model = await articleOperations.getArticleModelWithContext(byId: articleId)

                if let model = model {
                    AppLogger.database.debug("✅ ViewModel Init: Retrieved ArticleModel with valid context")
                    await MainActor.run {
                        self.currentArticleModel = model
                    }
                }
            }
        }

        // Setup observers for settings changes
        setupUserDefaultsObservers()
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
              nextIndex >= 0 && nextIndex < articles.count
        else {
            return
        }

        // Get the article - important to keep this until we load the new one
        let targetArticle = articles[nextIndex]
        let nextArticleId = targetArticle.id

        // Save current index to log the change
        let oldIndex = currentIndex

        // Create a timer to show loading indicator only if operation takes too long
        let loadingTimerTask = Task {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    isLoadingNextArticle = true
                }
            }
        }

        // Update the index but DON'T clear the current article yet
        // This ensures the view always has an article to display
        currentIndex = nextIndex

        // CRITICAL: Update currentArticle immediately with basic version
        // This ensures the view always has content even while loading better content
        currentArticle = targetArticle

        // Reset expanded sections
        expandedSections = Self.getDefaultExpandedSections()

        // Force refresh UI to show the transition
        contentTransitionID = UUID() // Generate a new transition ID to ensure UI updates properly
        scrollToTopTrigger = UUID()

        // Reset attributed strings but don't regenerate yet
        clearRichTextContent()

        // Fetch and display the article - use a high priority task
        Task(priority: .userInitiated) {
            do {
                // Start timing for diagnostics
                let startTime = Date()

                // Log for debugging with more context
                AppLogger.database.debug("🔄 Navigating from index \(oldIndex) to \(nextIndex) (article ID: \(nextArticleId))")
                AppLogger.database.debug("🔍 Container: \(String(describing: SwiftDataContainer.shared.container))")

                // Get a fresh ArticleModel with valid context for blob persistence
                let model = await articleOperations.getArticleModelWithContext(byId: nextArticleId)

                // Store the ArticleModel for future blob saving operations
                if let model = model {
                    await MainActor.run {
                        self.currentArticleModel = model
                    }

                    // Log model details for diagnostics
                    AppLogger.database.debug("""
                    ✅ Retrieved ArticleModel with ID: \(model.id)
                    - Has context: \(model.modelContext != nil)
                    - Has title blob: \(model.titleBlob != nil)
                    - Has body blob: \(model.bodyBlob != nil)
                    - Has summary blob: \(model.summaryBlob != nil)
                    """)

                    // Extract blobs immediately - this is critical for formatting
                    var extractedTitle: NSAttributedString? = nil
                    var extractedBody: NSAttributedString? = nil
                    var extractedSummary: NSAttributedString? = nil

                    // Try to get content from blobs
                    if let titleBlob = model.titleBlob {
                        extractedTitle = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: titleBlob
                        )
                    }

                    if let bodyBlob = model.bodyBlob {
                        extractedBody = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: bodyBlob
                        )
                    }

                    if let summaryBlob = model.summaryBlob {
                        extractedSummary = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: summaryBlob
                        )
                    }

                    // Update the UI with all data at once
                    await MainActor.run {
                        // Apply extracted blob data - critical for formatted display
                        titleAttributedString = extractedTitle
                        bodyAttributedString = extractedBody
                        summaryAttributedString = extractedSummary

                        // Force refresh
                        contentTransitionID = UUID()
                    }

                    // Mark as viewed after we have the article
                    try? await markAsViewed()

                    // Generate any missing content
                    if titleAttributedString == nil || bodyAttributedString == nil {
                        await loadMinimalContent()
                        AppLogger.database.debug("⚙️ Generated missing title/body content for article \(nextArticleId)")
                    }

                    // Generate summary if needed - Summary is expanded by default
                    if expandedSections["Summary"] == true && summaryAttributedString == nil {
                        loadContentForSection("Summary")
                        AppLogger.database.debug("⚙️ Generated missing summary content for article \(nextArticleId)")
                    }

                    // Log timing for diagnostics
                    let loadTime = Date().timeIntervalSince(startTime)
                    AppLogger.database.debug("✅ Article \(nextArticleId) loaded in \(String(format: "%.3f", loadTime)) seconds")
                } else {
                    // Failed to get article model with context
                    AppLogger.database.error("❌ Could not retrieve ArticleModel with context for ID: \(nextArticleId)")

                    // Even if we fail to get the complete article, we still have the basic one
                    await MainActor.run {
                        // Force refresh with available article
                        contentTransitionID = UUID()
                    }

                    // Always generate content for what we have
                    await loadMinimalContent()
                }
            }

            // Final safety check outside any error handling
            // Ensure we always have an article to display
            if currentArticle == nil {
                await MainActor.run {
                    currentArticle = targetArticle
                    AppLogger.database.error("❌ No article after navigation, restored fallback article")
                }

                // Generate content for what we have as a fallback
                await loadMinimalContent()
            }

            // Cancel the loading timer task if it's still running
            loadingTimerTask.cancel()

            // Always clear loading state at the end
            await MainActor.run {
                isLoadingNextArticle = false
            }
        }
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

    // MARK: - Public Methods - Content Loading

    /// Loads minimal content needed for the article header
    func loadMinimalContent() async {
        guard let article = currentArticleModel ?? currentArticle else { return }

        // Log what's available for debugging
        let hasTitleBlob = article.titleBlob != nil
        let hasBodyBlob = article.bodyBlob != nil
        AppLogger.database.debug("⚙️ loadMinimalContent: Title blob exists: \(hasTitleBlob), Body blob exists: \(hasBodyBlob)")

        // Title and body are required for header display
        if titleAttributedString == nil {
            titleAttributedString = articleOperations.getAttributedContent(
                for: .title,
                from: article,
                createIfMissing: true
            )
        }

        if bodyAttributedString == nil {
            bodyAttributedString = articleOperations.getAttributedContent(
                for: .body,
                from: article,
                createIfMissing: true
            )
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
        guard let article = currentArticle else { return }

        // Log beginning of section load
        AppLogger.database.debug("🔄 VIEW MODEL: Loading section \(section) for article \(article.id)")

        // Already loaded check - if we already have content, use it
        if getAttributedStringForSection(section) != nil {
            AppLogger.database.debug("✅ SECTION ALREADY LOADED: \(section) - using cached content")
            return
        }

        // Cancel existing task if any
        sectionLoadingTasks[section]?.cancel()

        // Create temporary loading indicator content
        provideTempContent(section, SectionNaming.fieldForSection(section), "Converting markdown to rich text...")

        // Create a task to load the content
        let task = Task(priority: .userInitiated) {
            let startTime = Date()

            // Use the centralized loader in ArticleOperations
            if let content = await articleOperations.loadContentForSection(section: section, articleId: article.id) {
                if !Task.isCancelled {
                    await MainActor.run {
                        // Update the content in the view model
                        updateSectionContent(section, SectionNaming.fieldForSection(section), content)
                    }

                    let totalTime = Date().timeIntervalSince(startTime)
                    AppLogger.database.debug("✅ VIEW MODEL: Section \(section) loaded in \(String(format: "%.4f", totalTime))s")

                    // Verify the blob was actually saved to the database
                    Task {
                        await articleOperations.verifyBlobStorage(
                            field: SectionNaming.fieldForSection(section),
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
        // Store in appropriate property
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

        // Store the fallback in the appropriate property
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

        // Store in the appropriate property
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

        // Update cached content
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

        if !wasExpanded && needsConversion(section) {
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
             "Source Analysis", "Relevance", "Context & Perspective":
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
        while newIndex >= 0 && newIndex < articles.count {
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
            "Critical Analysis": false,
            "Logical Fallacies": false,
            "Source Analysis": false,
            "Context & Perspective": false,
            "Argus Engine Stats": false,
            "Related Articles": false,
        ]
    }
}

// Extension to make ArticleModel uniquable for collections
extension ArticleModel {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ArticleModel, rhs: ArticleModel) -> Bool {
        return lhs.id == rhs.id
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
