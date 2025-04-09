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

    /// The database model corresponding to the current article (for persistence operations)
    private var currentArticleModel: ArticleModel?

    // MARK: - Published Properties

    /// The initially expanded section, if any
    let initiallyExpandedSection: String?

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
        preloadedSummary: NSAttributedString? = nil,
        preloadedArticleModel: ArticleModel? = nil,
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
        } else if currentIndex >= 0 && currentIndex < uniqueArticles.count {
            currentArticle = uniqueArticles[currentIndex]
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

        // Store the preloaded ArticleModel if provided
        currentArticleModel = preloadedArticleModel

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

        // Reset the ArticleModel reference - we'll fetch a fresh one
        currentArticleModel = nil

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

                // CRITICAL CHANGE: Get the ArticleModel directly for database operations
                let dbModel = await articleOperations.getArticleModelWithContext(byId: nextArticleId)

                // Store the ArticleModel for future blob saving operations
                await MainActor.run {
                    self.currentArticleModel = dbModel
                }

                // If we have the model, log its state
                if let model = dbModel {
                    AppLogger.database.debug("""
                    Retrieved ArticleModel with ID: \(model.id)
                    - Has context: \(model.modelContext != nil)
                    - Has title blob: \(model.titleBlob != nil)
                    - Has body blob: \(model.bodyBlob != nil)
                    - Has summary blob: \(model.summaryBlob != nil)
                    """)
                } else {
                    AppLogger.database.warning("⚠️ Could not retrieve ArticleModel for ID: \(nextArticleId)")
                }

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
    @MainActor
    func loadContentForSection(_ section: String, retryCount: Int = 0) {
        guard let article = currentArticle else { return }

        // Log start of loading process with article ID for traceability
        AppLogger.database.debug("🔍 SECTION LOAD START: \(section) for article \(article.id) (retry: \(retryCount))")

        // Already loaded check (return immediately if content exists)
        if getAttributedStringForSection(section) != nil {
            AppLogger.database.debug("✅ SECTION ALREADY LOADED: \(section) - using cached content")
            return
        }

        // Cancel existing task if any
        sectionLoadingTasks[section]?.cancel()

        let field = getRichTextFieldForSection(section)
        objectWillChange.send() // Notify UI of pending update

        // Create task with strict sequential loading logic
        let task = Task(priority: .userInitiated) {
            let startTime = Date()

            // PHASE 1: BLOB LOADING - Try to get from database
            AppLogger.database.debug("⚙️ PHASE 1: Checking for blob in database for \(section)")
            let blobStart = Date()

            // Verify the article is actually stored in the database with ID
            if article.modelContext == nil {
                AppLogger.database.warning("⚠️ Article \(article.id) has no model context - not saved to database")
            }

            // Check if blob exists in database with detailed logging
            let blobs = article.getBlobsForField(field)
            let blobCheckTime = Date().timeIntervalSince(blobStart)
            let hasBlob = blobs?.first != nil
            let blobSize = blobs?.first?.count ?? 0

            AppLogger.database.debug("⏱️ Blob check took \(String(format: "%.4f", blobCheckTime))s, hasBlob: \(hasBlob), size: \(blobSize) bytes")

            // If blob exists, try to load it
            if hasBlob, let blob = blobs?.first {
                AppLogger.database.debug("📦 Blob found (\(blob.count) bytes), attempting to unarchive")

                do {
                    let unarchiveStart = Date()
                    let attributedString = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: blob
                    )

                    let unarchiveTime = Date().timeIntervalSince(unarchiveStart)
                    AppLogger.database.debug("⏱️ Blob unarchive took \(String(format: "%.4f", unarchiveTime))s")

                    if let content = attributedString, !Task.isCancelled {
                        // BLOB LOADING SUCCESS - Update UI immediately
                        await MainActor.run {
                            updateSectionContent(section, field, content)
                        }

                        let totalTime = Date().timeIntervalSince(startTime)
                        AppLogger.database.debug("✅ SECTION LOAD SUCCESS: \(section) via BLOB in \(String(format: "%.4f", totalTime))s")
                        return // Exit if blob loaded successfully
                    } else {
                        AppLogger.database.warning("⚠️ Blob existed but unarchived to nil for \(section), will force regenerate")

                        // Delete invalid blob and regenerate
                        await MainActor.run {
                            field.setBlob(nil, on: article)
                            try? article.modelContext?.save()
                        }
                    }
                } catch {
                    AppLogger.database.error("❌ ERROR unarchiving blob: \(error.localizedDescription), will force regenerate")

                    // Delete corrupt blob and regenerate
                    await MainActor.run {
                        field.setBlob(nil, on: article)
                        try? article.modelContext?.save()
                    }
                }
            }

            // PHASE 2: RICH TEXT GENERATION - If blob loading failed
            if !Task.isCancelled {
                AppLogger.database.debug("⚙️ PHASE 2: Blob loading failed, attempting rich text generation for \(section)")

                // Update UI to show generation state
                await MainActor.run {
                    provideTempContent(section, field, "Converting markdown to rich text...")
                }

                let generationStart = Date()
                let textContent = getTextContentForField(field, from: article)
                AppLogger.database.debug("📝 Raw text content length: \(textContent?.count ?? 0)")

                do {
                    // Try to generate rich text from markdown with a 5 second timeout (increased from 3s)
                    let attributedString = try await withTimeout(duration: .seconds(5)) {
                        // Get text content again inside the timeout to ensure we have it
                        guard let textContent = self.getTextContentForField(field, from: article),
                              !textContent.isEmpty
                        else {
                            AppLogger.database.error("❌ No text content for \(section)")
                            return nil as NSAttributedString?
                        }

                        // Generate attributed string directly here - we're already on the MainActor
                        // so we don't need to use MainActor.run
                        let attrString = markdownToAttributedString(
                            textContent,
                            textStyle: "UIFontTextStyleBody"
                        )

                        // We're inside a timeout function - just return the string and handle saving outside
                        return attrString
                    }

                    // Now that we're outside the timeout function, save the blob if we have a valid string
                    if let attrString = attributedString {
                        do {
                            // Archive the string to data
                            let blobData = try NSKeyedArchiver.archivedData(
                                withRootObject: attrString,
                                requiringSecureCoding: false
                            )

                            // Set the blob directly on the original article for immediate display
                            field.setBlob(blobData, on: article)

                            // CRITICAL CHANGE: Save blob to the database through ArticleModel
                            var savedToDb = false
                            if let articleModel = self.currentArticleModel {
                                savedToDb = articleOperations.saveBlobToDatabase(
                                    field: field,
                                    blobData: blobData,
                                    articleModel: articleModel
                                )

                                if savedToDb {
                                    AppLogger.database.debug("✅ Successfully saved blob to database model")
                                } else {
                                    AppLogger.database.warning("⚠️ Failed to save blob to database model")
                                }
                            } else {
                                // If we don't have the ArticleModel, try to get it now
                                AppLogger.database.debug("⚠️ No ArticleModel available, attempting to fetch it")
                                if let freshModel = await articleOperations.getArticleModelWithContext(byId: article.id) {
                                    // Store for future use
                                    await MainActor.run {
                                        self.currentArticleModel = freshModel
                                    }

                                    // Try to save to this fresh model
                                    savedToDb = articleOperations.saveBlobToDatabase(
                                        field: field,
                                        blobData: blobData,
                                        articleModel: freshModel
                                    )

                                    if savedToDb {
                                        AppLogger.database.debug("✅ Successfully saved blob to freshly fetched database model")
                                    } else {
                                        AppLogger.database.warning("⚠️ Failed to save blob to freshly fetched database model")
                                    }
                                } else {
                                    AppLogger.database.error("❌ Could not find ArticleModel for blob saving")
                                }
                            }

                            // Still log status in all cases
                            if savedToDb {
                                AppLogger.database.debug("✅ Blob saved to database (\(blobData.count) bytes)")
                            } else {
                                AppLogger.database.warning("⚠️ Blob available only in memory: \(blobData.count) bytes")
                            }
                        } catch {
                            AppLogger.database.error("❌ Failed to save blob: \(error)")
                        }
                    }

                    let generationTime = Date().timeIntervalSince(generationStart)
                    AppLogger.database.debug("⏱️ Rich text generation took \(String(format: "%.4f", generationTime))s")

                    if !Task.isCancelled, let content = attributedString {
                        // RICH TEXT GENERATION SUCCESS - Update UI
                        await MainActor.run {
                            updateSectionContent(section, field, content)
                        }

                        let totalTime = Date().timeIntervalSince(startTime)
                        AppLogger.database.debug("✅ SECTION LOAD SUCCESS: \(section) via GENERATION in \(String(format: "%.4f", totalTime))s")
                        return // Exit if generation succeeded
                    } else {
                        AppLogger.database.error("❌ Generated attributedString was nil for \(section)")
                    }
                } catch _ as TimeoutError {
                    AppLogger.database.error("⏰ TIMEOUT during rich text generation for \(section) after 5s")
                    logGenerationDetails(field, article) // Log details about the content

                    // If we've tried multiple times, fall back to plain text
                    if retryCount >= 1 {
                        AppLogger.database.error("❌ Giving up after \(retryCount) retries")
                    } else {
                        // Try once more after a short delay
                        AppLogger.database.debug("🔄 Will retry rich text generation after delay")
                        if !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(0.5))

                            await MainActor.run {
                                // Only retry if task wasn't cancelled during delay
                                if !Task.isCancelled {
                                    loadContentForSection(section, retryCount: retryCount + 1)
                                }
                            }
                            return
                        }
                    }
                } catch {
                    AppLogger.database.error("❌ ERROR during rich text generation: \(error.localizedDescription)")
                }
            }

            // If we got here, both blob loading and rich text generation failed

            // PHASE 3: PLAIN TEXT FALLBACK - Only if both previous methods failed
            if !Task.isCancelled {
                AppLogger.database.debug("⚙️ PHASE 3: Both blob and rich text failed, falling back to plain text for \(section)")

                // Create a simple attributed string with plain text
                if let rawText = getTextContentForField(field, from: article), !rawText.isEmpty {
                    let plainStart = Date()

                    // Create basic attributed string with system font (very simple, should be fast)
                    let plainAttrString = NSAttributedString(
                        string: rawText,
                        attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .body),
                            .foregroundColor: UIColor.label,
                        ]
                    )

                    let plainTime = Date().timeIntervalSince(plainStart)
                    AppLogger.database.debug("⏱️ Plain text formatting took \(String(format: "%.4f", plainTime))s")

                    // Update UI with plain text
                    await MainActor.run {
                        updateSectionContent(section, field, plainAttrString)
                    }

                    let totalTime = Date().timeIntervalSince(startTime)
                    AppLogger.database.debug("⚠️ SECTION LOAD FALLBACK: \(section) via PLAIN TEXT in \(String(format: "%.4f", totalTime))s")
                } else {
                    // If even the raw text is missing, show error message
                    await MainActor.run {
                        provideFallbackContent(section, field)
                    }

                    AppLogger.database.error("❌ SECTION LOAD FAILED: No content available for \(section)")
                }
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
    private func logGenerationDetails(_ field: RichTextField, _ article: NotificationData) {
        // Log more details about content to help diagnose issues
        let textContent = getTextContentForField(field, from: article)

        AppLogger.database.debug("📊 Generation Diagnostic:")
        AppLogger.database.debug("- Field: \(String(describing: field))")
        AppLogger.database.debug("- Has content: \(textContent != nil)")
        AppLogger.database.debug("- Content length: \(textContent?.count ?? 0)")
        AppLogger.database.debug("- Article ID: \(article.id)")
        AppLogger.database.debug("- JSON URL: \(article.json_url)")

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

    // Helper to get text content for a specific field from an article
    private func getTextContentForField(_ field: RichTextField, from article: NotificationData) -> String? {
        switch field {
        case .title:
            return article.title
        case .body:
            return article.body
        case .summary:
            return article.summary
        case .criticalAnalysis:
            return article.critical_analysis
        case .logicalFallacies:
            return article.logical_fallacies
        case .sourceAnalysis:
            return article.source_analysis
        case .relationToTopic:
            return article.relation_to_topic
        case .additionalInsights:
            return article.additional_insights
        }
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

            // Ensure the ArticleModel is also updated
            if let model = currentArticleModel, !model.isViewed {
                model.isViewed = true
                try model.modelContext?.save()
            }
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

    /// Verifies if an article blob was actually saved to the database
    /// - Parameters:
    ///   - field: The field to check
    ///   - articleId: The ID of the article
    /// - Returns: Boolean indicating if the blob exists in the database
    private func verifyBlobInDatabase(field: RichTextField, articleId: UUID) async -> Bool {
        // Try to fetch the article fresh from the database
        if let freshArticle = await articleOperations.getCompleteArticle(byId: articleId) {
            // Check if the blob exists
            if let blob = field.getBlob(from: freshArticle), !blob.isEmpty {
                return true
            }
        }
        return false
    }

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

// MARK: - NotificationData Blob Access

// NOTE: This implementation uses the NotificationData.getBlobsForField method from MarkdownUtilities.swift
// The implementation there includes additional logging and validation that we rely on
