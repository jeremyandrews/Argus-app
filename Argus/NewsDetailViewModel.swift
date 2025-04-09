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

    // MARK: - Published Properties

    /// The currently displayed article
    @Published var currentArticle: NotificationData?

    /// The index of the current article in the articles array
    @Published var currentIndex: Int

    /// All available articles for navigation
    @Published var articles: [NotificationData]

    /// All articles in the database (may be used for related articles)
    @Published var allArticles: [NotificationData]

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
        articles: [NotificationData],
        allArticles: [NotificationData],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil,
        preloadedArticle: NotificationData? = nil,
        preloadedTitle: NSAttributedString? = nil,
        preloadedBody: NSAttributedString? = nil,
        articleOperations: ArticleOperations = ArticleOperations()
    ) {
        // Apply uniqueness to prevent duplicate IDs in collections
        let uniqueArticles = articles.uniqued()
        let uniqueAllArticles = allArticles.uniqued()

        self.articles = uniqueArticles
        self.allArticles = uniqueAllArticles
        self.currentIndex = min(currentIndex, uniqueArticles.count - 1)
        self.articleOperations = articleOperations

        // Set initial preloaded content if available
        if let preloadedArticle = preloadedArticle {
            currentArticle = preloadedArticle
        } else if currentIndex >= 0 && currentIndex < uniqueArticles.count {
            currentArticle = uniqueArticles[currentIndex]
        }

        titleAttributedString = preloadedTitle
        bodyAttributedString = preloadedBody

        // Set initial expanded sections
        if let section = initiallyExpandedSection {
            expandedSections[section] = true
        }

        // Set default expanded sections
        if expandedSections["Summary"] == nil {
            expandedSections["Summary"] = true
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
                AppLogger.database.debug("Navigating from index \(oldIndex) to \(nextIndex) (article ID: \(nextArticleId))")

                // Try to get complete article from service with all blobs
                if let completeArticle = await articleOperations.getCompleteArticle(byId: nextArticleId) {
                    // Log for diagnostic purposes
                    let hasTitleBlob = completeArticle.title_blob != nil
                    let hasBodyBlob = completeArticle.body_blob != nil
                    let hasSummaryBlob = completeArticle.summary_blob != nil

                    AppLogger.database.debug("""
                    Got complete article. Has title blob: \(hasTitleBlob), 
                    has body blob: \(hasBodyBlob), has summary blob: \(hasSummaryBlob)
                    """)

                    // Immediately extract and use blobs - this is critical for formatting
                    var extractedTitle: NSAttributedString? = nil
                    var extractedBody: NSAttributedString? = nil
                    var extractedSummary: NSAttributedString? = nil

                    // Extract formatted content synchronously from blobs
                    if let titleBlobData = completeArticle.title_blob {
                        extractedTitle = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: titleBlobData
                        )
                    }

                    if let bodyBlobData = completeArticle.body_blob {
                        extractedBody = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: bodyBlobData
                        )
                    }

                    if let summaryBlobData = completeArticle.summary_blob {
                        extractedSummary = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: NSAttributedString.self,
                            from: summaryBlobData
                        )
                    }

                    // Now update the UI with all data at once
                    await MainActor.run {
                        // Update the model with complete article
                        currentArticle = completeArticle

                        // Update our local article in the array too
                        if let index = articles.firstIndex(where: { $0.id == completeArticle.id }) {
                            articles[index] = completeArticle
                        }

                        // Apply extracted blob data - critical for formatted display
                        titleAttributedString = extractedTitle
                        bodyAttributedString = extractedBody
                        summaryAttributedString = extractedSummary

                        // Force refresh with the complete article
                        contentTransitionID = UUID() // Ensure the view updates with new content
                    }

                    // Mark as viewed after we have the article
                    try? await markAsViewed()

                    // Now generate any missing content if needed
                    if titleAttributedString == nil || bodyAttributedString == nil {
                        await loadMinimalContent()
                        AppLogger.database.debug("Generated missing title/body content for article \(nextArticleId)")
                    }

                    // Generate summary if needed - Summary is expanded by default
                    if expandedSections["Summary"] == true && summaryAttributedString == nil {
                        loadContentForSection("Summary")
                        AppLogger.database.debug("Generated missing summary content for article \(nextArticleId)")
                    }

                    // Log timing for diagnostics
                    let loadTime = Date().timeIntervalSince(startTime)
                    AppLogger.database.debug("Article \(nextArticleId) loaded in \(loadTime) seconds")
                } else {
                    AppLogger.database.error("Failed to get complete article with ID: \(nextArticleId)")

                    // Even if we fail to get the complete article, we still have the basic one
                    await MainActor.run {
                        // Make sure the article is still set (from earlier)
                        if currentArticle == nil {
                            currentArticle = targetArticle
                        }
                        // Force refresh with available article
                        contentTransitionID = UUID()
                    }

                    // Always generate content for what we have
                    await loadMinimalContent()
                    AppLogger.database.debug("Generated minimal content for article \(nextArticleId) (fallback mode)")

                    if expandedSections["Summary"] == true {
                        loadContentForSection("Summary")
                    }
                }
            }

            // Final safety check outside any error handling
            // Ensure we always have an article to display
            if currentArticle == nil {
                await MainActor.run {
                    currentArticle = targetArticle
                    AppLogger.database.error("No article after navigation, restored fallback article")
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

    // Using the shared NavigationDirection enum

    // MARK: - Public Methods - Content Loading

    /// Loads minimal content needed for the article header
    func loadMinimalContent() async {
        guard let article = currentArticle else { return }

        // Log what's available for debugging
        let hasTitleBlob = article.title_blob != nil
        let hasBodyBlob = article.body_blob != nil
        AppLogger.database.debug("loadMinimalContent: Title blob exists: \(hasTitleBlob), Body blob exists: \(hasBodyBlob)")

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

    /// Loads content for a specific section
    /// - Parameter section: The section to load content for
    func loadContentForSection(_ section: String) {
        guard let article = currentArticle else { return }

        // Check if content is already loaded
        if getAttributedStringForSection(section) != nil {
            return // Already loaded, nothing to do
        }

        // Cancel any existing task for this section
        sectionLoadingTasks[section]?.cancel()

        let field = getRichTextFieldForSection(section)

        // Create a new task to load this section's content
        let task = Task {
            let attributedString = articleOperations.getAttributedContent(
                for: field,
                from: article,
                createIfMissing: true
            )

            // If task wasn't cancelled and we got content, update the appropriate property
            if !Task.isCancelled, let attributedString = attributedString {
                // Store the result in the appropriate property
                switch field {
                case .summary:
                    summaryAttributedString = attributedString
                case .criticalAnalysis:
                    criticalAnalysisAttributedString = attributedString
                case .logicalFallacies:
                    logicalFallaciesAttributedString = attributedString
                case .sourceAnalysis:
                    sourceAnalysisAttributedString = attributedString
                case .relationToTopic:
                    cachedContentBySection["Relevance"] = attributedString
                case .additionalInsights:
                    cachedContentBySection["Context & Perspective"] = attributedString
                default:
                    // For other sections, cache by section name
                    cachedContentBySection[section] = attributedString
                }

                // Clear loading state
                sectionLoadingTasks[section] = nil
            }
        }

        // Store the task so we can cancel it if needed
        sectionLoadingTasks[section] = task
    }

    /// Generates all rich text content for an article
    func generateAllRichTextContent() async {
        guard let article = currentArticle else { return }

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
        guard let article = currentArticle else { return }

        do {
            try await articleOperations.toggleReadStatus(for: article)
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling read status: \(error)")
        }
    }

    /// Toggles the bookmarked status of the current article
    func toggleBookmark() async {
        guard let article = currentArticle else { return }

        do {
            try await articleOperations.toggleBookmark(for: article)
        } catch {
            self.error = error
            AppLogger.database.error("Error toggling bookmark status: \(error)")
        }
    }

    // Archive functionality removed

    /// Deletes the current article
    func deleteArticle() async {
        guard let article = currentArticle else { return }

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
        guard let article = currentArticle else { return }

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

    /// Gets the rich text field for a section
    /// - Parameter section: The section to get the field for
    /// - Returns: The corresponding rich text field
    private func getRichTextFieldForSection(_ section: String) -> RichTextField {
        switch section {
        case "Summary": return .summary
        case "Critical Analysis": return .criticalAnalysis
        case "Logical Fallacies": return .logicalFallacies
        case "Source Analysis": return .sourceAnalysis
        case "Relevance": return .relationToTopic
        case "Context & Perspective": return .additionalInsights
        default: return .body
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
        currentIndex >= 0 && currentIndex < articles.count
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
