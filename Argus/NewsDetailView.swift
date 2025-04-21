import SafariServices
import SwiftData
import SwiftUI
import WebKit

enum TabTransitionState {
    case idle
    case preparing
    case transitioning
}

struct NewsDetailView: View {
    // MARK: - View Model

    /// The view model that manages article data and operations
    @ObservedObject private var viewModel: NewsDetailViewModel

    // MARK: - UI State Properties

    /// Computed property to check if current index is valid
    private var isCurrentIndexValid: Bool {
        viewModel.currentIndex >= 0 && viewModel.currentIndex < viewModel.articles.count
    }

    /// Access to the model context for database operations
    @Environment(\.modelContext) private var modelContext
    // Removed legacy preloaded notification state

    /// Convert article content to attributed string
    private func getAttributedString(
        for field: RichTextField,
        from article: ArticleModel,
        createIfMissing: Bool = false,
        customFontSize: CGFloat? = nil
    ) -> NSAttributedString? {
        // Call directly to MarkdownUtilities since the customFontSize parameter is needed
        // but not available in the ArticleOperations API
        if let textContent = getTextContentForField(field, from: article) {
            return markdownToAttributedString(
                textContent,
                textStyle: "UIFontTextStyleBody",
                customFontSize: customFontSize
            )
        } else if createIfMissing {
            // If we should create missing content, use placeholder text
            let fieldName = SectionNaming.nameForField(field).lowercased()
            let placeholder = "No \(fieldName) content available."
            return markdownToAttributedString(
                placeholder,
                textStyle: "UIFontTextStyleBody",
                customFontSize: customFontSize
            )
        }
        return nil
    }

    /// Gets the text content for a specific rich text field from an ArticleModel
    private func getTextContentForField(_ field: RichTextField, from article: ArticleModel) -> String? {
        switch field {
        case .title:
            return article.title
        case .body:
            return article.body
        case .summary:
            return article.summary
        case .criticalAnalysis:
            return article.criticalAnalysis
        case .logicalFallacies:
            return article.logicalFallacies
        case .sourceAnalysis:
            return article.sourceAnalysis
        case .relationToTopic:
            return article.relationToTopic
        case .additionalInsights:
            return article.additionalInsights
        case .actionRecommendations:
            return article.actionRecommendations
        case .talkingPoints:
            return article.talkingPoints
        }
    }

    /// Gets the text content for a specific rich text field
    // Removed legacy NotificationData getTextContentForField method - using ArticleModel version instead

    @State private var titleAttributedString: NSAttributedString? = nil
    @State private var bodyAttributedString: NSAttributedString? = nil
    @State private var summaryAttributedString: NSAttributedString? = nil
    @State private var criticalAnalysisAttributedString: NSAttributedString? = nil
    @State private var logicalFallaciesAttributedString: NSAttributedString? = nil
    @State private var sourceAnalysisAttributedString: NSAttributedString? = nil
    @State private var cachedContentBySection: [String: NSAttributedString] = [:]
    @State private var expandedSections: [String: Bool] = Self.getDefaultExpandedSections()
    @State private var contentTransitionID = UUID()
    @State private var isLoadingNextArticle = false
    @State private var sectionLoadingTasks: [String: Task<Void, Never>] = [:]
    @State private var tabChangeTask: Task<Void, Never>? = nil
    @State private var deletedIDs: Set<UUID> = []
    @State private var scrollToSection: String? = nil

    /// Proxy for scrolling to specific sections
    @State private var scrollViewProxy: ScrollViewProxy? = nil

    /// Used to trigger scroll to top
    @State private var scrollToTopTrigger = UUID()

    /// Whether to show the delete confirmation dialog
    @State private var showDeleteConfirmation = false

    /// Additional content dictionary for sections
    @State private var additionalContent: [String: Any]? = nil

    /// Whether to show the share sheet
    @State private var isSharePresented = false

    /// Sections selected for sharing
    @State private var selectedSections: Set<String> = []

    /// The initially expanded section, if any
    let initiallyExpandedSection: String?

    /// Current article being displayed
    private var currentNotification: ArticleModel? {
        viewModel.currentArticle
    }

    @Environment(\.dismiss) private var dismiss

    /// Returns default section expansion states
    private static func getDefaultExpandedSections() -> [String: Bool] {
        return [
            "Summary": true,
            "Critical Analysis": false,
            "Logical Fallacies": false,
            "Source Analysis": false,
            "Relevance": false,
            "Context & Perspective": false,
            "Action Recommendations": false,
            "Talking Points": false,
            "Argus Engine Stats": false,
            "Preview": false,
            "Related Articles": false,
        ]
    }

    // MARK: - Initialization

    /// Initializes the view with a pre-configured view model
    /// This approach ensures that we maintain the SwiftData context throughout
    init(viewModel: NewsDetailViewModel) {
        // Initialize with the provided view model
        _viewModel = ObservedObject(initialValue: viewModel)

        // Get the initially expanded section from the view model's state
        initiallyExpandedSection = viewModel.initiallyExpandedSection
    }

    var body: some View {
        mainView
    }

    // Breaking the body into smaller components to help the compiler
    private var mainView: some View {
        NavigationStack {
            articleContentView
                .navigationBarHidden(true)
                .onAppear(perform: handleOnAppear)
                .onChange(of: viewModel.articles) { _, _ in
                    validateAndAdjustIndex()
                }
                .alert("Are you sure you want to delete this article?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        deleteNotification()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $isSharePresented) {
                    ShareSelectionView(
                        content: additionalContent,
                        notification: currentNotification ?? viewModel.articles[0],
                        selectedSections: $selectedSections,
                        isPresented: $isSharePresented
                    )
                }
                .gesture(createDismissGesture())
        }
    }

    private var articleContentView: some View {
        Group {
            if let _ = currentNotification {
                articleDetailContent
            } else {
                Text("Article no longer available")
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            dismiss()
                        }
                    }
            }
        }
    }

    private var articleDetailContent: some View {
        VStack(spacing: 0) {
            topBar
            articleScrollView
            bottomToolbar
        }
    }

    private var articleScrollView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack {
                    // Invisible anchor to scroll to top
                    Color.clear
                        .frame(height: 1)
                        .id("top")

                    // Immediately show header with minimal data
                    articleHeaderStyle

                    // All sections below, default collapsed
                    additionalSectionsView
                        .opacity(isLoadingNextArticle ? 0.3 : 1.0) // Fade sections during transitions
                        .animation(.easeInOut(duration: 0.2), value: isLoadingNextArticle)
                }
                .onAppear {
                    scrollViewProxy = proxy
                }
            }
        }
        .onChange(of: scrollToTopTrigger) { _, _ in
            withAnimation {
                scrollViewProxy?.scrollTo("top", anchor: .top)
            }
        }
    }

    private func createDismissGesture() -> some Gesture {
        DragGesture()
            .onEnded { value in
                if value.translation.width > 100 {
                    dismiss()
                }
            }
    }

    private func handleOnAppear() {
        setupDeletionHandling()
        markAsViewed()
        loadInitialMinimalContent()
        if let section = initiallyExpandedSection {
            expandedSections[section] = true
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: {
                // Only post a notification so the list will refresh, but don't change the read status
                NotificationCenter.default.post(name: Notification.Name("DetailViewClosed"), object: nil)
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, 8)

            Spacer()

            HStack(spacing: 32) {
                Button {
                    navigateToArticle(direction: .previous)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }
                .disabled(viewModel.currentIndex == 0)
                .foregroundColor(viewModel.currentIndex > 0 ? .blue : .gray)

                Button {
                    navigateToArticle(direction: .next)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }
                .disabled(viewModel.currentIndex >= viewModel.articles.count - 1)
                .foregroundColor(viewModel.currentIndex < viewModel.articles.count - 1 ? .blue : .gray)
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            toolbarButton(icon: "envelope.badge", label: "Read") {
                toggleReadStatus()
            }

            Spacer()

            toolbarButton(icon: currentNotification?.isBookmarked ?? false ? "bookmark.fill" : "bookmark", label: "Bookmark") {
                toggleBookmark()
            }

            Spacer()

            toolbarButton(icon: "square.and.arrow.up", label: "Share") {
                isSharePresented = true
            }

            Spacer()

            toolbarButton(icon: "trash", label: "Delete", isDestructive: true) {
                showDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
    }

    private func toolbarButton(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(buttonColor(label: label, isDestructive: isDestructive))
            .frame(minWidth: 60)
        }
    }

    private func buttonColor(label: String, isDestructive: Bool) -> Color {
        if isDestructive {
            return .red
        }

        guard let notification = currentNotification else {
            return .primary
        }

        switch label {
        case "Read":
            return notification.isViewed ? .primary : Color.blue.opacity(0.6)
        case "Bookmark":
            return notification.isBookmarked ? .blue : .primary
        default:
            return .primary
        }
    }

    /// Returns all sections (Article, Summary, etc.) for the "accordion" in NewsDetailView.
    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections: [ContentSection] = []

        // Bail out if we have no "currentNotification" (or no data):
        guard let n = currentNotification else {
            return sections
        }

        // 1) "Summary" section
        let summaryContent = n.summary ?? (json["summary"] as? String ?? "")
        sections.append(ContentSection(header: "Summary", content: summaryContent))

        // 2) "Relevance" section
        let relevanceContent = n.relationToTopic ?? (json["relationToTopic"] as? String ?? "")
        sections.append(ContentSection(header: "Relevance", content: relevanceContent))

        // 3) "Critical Analysis" section
        let criticalContent = n.criticalAnalysis ?? (json["criticalAnalysis"] as? String ?? "")
        sections.append(ContentSection(header: "Critical Analysis", content: criticalContent))

        // 4) "Logical Fallacies" section
        let fallaciesContent = n.logicalFallacies ?? (json["logicalFallacies"] as? String ?? "")
        sections.append(ContentSection(header: "Logical Fallacies", content: fallaciesContent))

        // 5) "Source Analysis" section
        let sourceAnalysisText = n.sourceAnalysis ?? (json["sourceAnalysis"] as? String ?? "")
        let sourceType = n.sourceType ?? (json["sourceType"] as? String ?? "")
        let sourceAnalysisData: [String: Any] = [
            "text": sourceAnalysisText,
            "sourceType": sourceType,
        ]
        sections.append(ContentSection(header: "Source Analysis", content: sourceAnalysisData))

        // 6) "Context & Perspective" (aka "additional_insights")
        let insights = n.additionalInsights ?? (json["additionalInsights"] as? String ?? "")
        if !insights.isEmpty {
            sections.append(ContentSection(header: "Context & Perspective", content: insights))
        }
        
        // 7) "Action Recommendations"
        let recommendations = n.actionRecommendations ?? (json["actionRecommendations"] as? String ?? "")
        if !recommendations.isEmpty {
            sections.append(ContentSection(header: "Action Recommendations", content: recommendations))
        }
        
        // 8) "Talking Points"
        let talkingPoints = n.talkingPoints ?? (json["talkingPoints"] as? String ?? "")
        if !talkingPoints.isEmpty {
            sections.append(ContentSection(header: "Talking Points", content: talkingPoints))
        }

        // 9) "Argus Engine Stats" (argus_details)
        if let engineString = n.engine_stats {
            // parseEngineStatsJSON returns an ArgusDetailsData if valid
            if let parsed = parseEngineStatsJSON(engineString, fallbackDate: n.date) {
                sections.append(ContentSection(header: "Argus Engine Stats", content: parsed))
            } else {}
        } else if
            let model = json["model"] as? String,
            let elapsed = json["elapsedTime"] as? Double,
            let stats = json["stats"] as? String
        {
            // Create ArgusDetailsData for fallback
            let dataObject = ArgusDetailsData(
                model: model,
                elapsedTime: elapsed,
                date: n.date,
                stats: stats,
                systemInfo: json["systemInfo"] as? [String: Any]
            )
            sections.append(ContentSection(header: "Argus Engine Stats", content: dataObject))
        }

        // 10) "Preview" section
        if let fullURL = n.getArticleUrl(additionalContent: additionalContent), !fullURL.isEmpty {
            sections.append(ContentSection(header: "Preview", content: fullURL))
        }

        // 11) "Related Articles" - Direct approach using only the model data
        if let relatedArticles = n.relatedArticles, !relatedArticles.isEmpty {
            AppLogger.database.debug("Found \(relatedArticles.count) related articles in article: \(n.id)")
            sections.append(ContentSection(header: "Related Articles", content: relatedArticles))
        } else {
            AppLogger.database.debug("No related articles found for article: \(n.id)")
            // Don't add a section for related articles if there are none
        }

        return sections
    }

    // MARK: - Navigation and Safety Methods

    // SAFETY: Added validation and safe navigation
    private func validateAndAdjustIndex() {
        if !isCurrentIndexValid {
            if let targetID = currentNotification?.id,
               let newIndex = viewModel.articles.firstIndex(where: { $0.id == targetID })
            {
                viewModel.currentIndex = newIndex
            } else {
                viewModel.currentIndex = max(0, viewModel.articles.count - 1)
            }
        }
    }

    private func tryNavigateToValidArticle() {
        if let currentNotification {
            let currentID = currentNotification.id
            if let newIndex = viewModel.articles.firstIndex(where: {
                $0.id != currentID && !deletedIDs.contains($0.id)
            }) {
                viewModel.currentIndex = newIndex
                return
            }
        }
        dismiss()
    }

    private func setupDeletionHandling() {
        NotificationCenter.default.addObserver(
            forName: .willDeleteArticle,
            object: nil,
            queue: .main
        ) { notification in
            guard let articleID = notification.userInfo?["articleID"] as? UUID else { return }
            deletedIDs.insert(articleID)

            if currentNotification?.id == articleID {
                tryNavigateToValidArticle()
            }
        }
    }

    // Make sure we clean up properly when navigating between articles
    private func navigateToArticle(direction: NavigationDirection) {
        // Cancel any local ongoing tasks
        tabChangeTask?.cancel()
        for (_, task) in sectionLoadingTasks {
            task.cancel()
        }
        sectionLoadingTasks = [:]

        // Log navigation action for debugging
        if let currentArticle = currentNotification {
            AppLogger.database.debug("NewsDetailView - Navigating from article ID: \(currentArticle.id), direction: \(direction == .next ? "next" : "previous")")
        }

        // Delegate to view model for navigation using shared NavigationDirection
        viewModel.navigateToArticle(direction: direction)

        // No need to synchronize anymore since we're using viewModel values directly

        // Reset expanded sections - Summary stays expanded by default
        expandedSections = Self.getDefaultExpandedSections()

        // Force refresh UI
        contentTransitionID = viewModel.contentTransitionID
        scrollToTopTrigger = UUID()

        // Now update with the new article if available
        if let newArticle = viewModel.currentArticle {
            // No need to set the article - currentNotification is computed from viewModel.currentArticle
            // But we do make sure our UI state is updated

            // Explicitly mark as viewed
            markAsViewed()

            // Log the new article state
            let hasEngineStats = newArticle.engine_stats != nil
            let hasSimilarArticles = newArticle.relatedArticles != nil
            let hasTitleBlob = newArticle.titleBlob != nil
            let hasBodyBlob = newArticle.bodyBlob != nil

            AppLogger.database.debug("""
            NewsDetailView - After navigation to article ID: \(newArticle.id)
            - Has title blob: \(hasTitleBlob)
            - Has body blob: \(hasBodyBlob)
            - Has engine stats: \(hasEngineStats)
            - Has similar articles: \(hasSimilarArticles)
            """)

            // Load the Summary if it's expanded - with slight delay to allow UI to refresh
            if expandedSections["Summary"] == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.loadContentForSection("Summary")
                }
            }
        } else {
            // If we somehow don't have an article after navigation, log error
            // This is just a safety check that should never happen in normal operation
            AppLogger.database.error("NewsDetailView - No article after navigation")
        }
    }

    // Removed legacy processRichText method - we now use the ArticleOperations and ViewModel

    // Fix the loadContentForSection function to properly handle section loading
    // Function removed - using SectionNaming.normalizedKey directly at call sites

    private func loadContentForSection(_ section: String) {
        // Simply delegate section loading to the ViewModel
        // The ViewModel now has improved logging and sequential loading

        // Get normalized key for better diagnostics
        let normalizedKey = SectionNaming.normalizedKey(section)

        // Log that we're requesting content for this section
        AppLogger.database.debug("NewsDetailView requesting content for section: \(section) (key: \(normalizedKey))")

        // Cancel any existing task
        sectionLoadingTasks[section]?.cancel()

        // Create a task that will handle loading and state management
        let loadingTask = Task {
            // First mark this section as loading in our local state
            await MainActor.run {
                sectionLoadingTasks[section] = Task {}  // Just a placeholder task to indicate loading
            }
            
            // Delegate to ViewModel which handles the actual loading and persistence
            viewModel.loadContentForSection(section)
            
            // Check if content is available after a short delay (give time for loading)
            try? await Task.sleep(for: .seconds(0.5))
            
            // Monitor loading until either content is available or timeout occurs
            let startTime = Date()
            let timeout = 10.0 // seconds
            
            while !Task.isCancelled {
                if Date().timeIntervalSince(startTime) > timeout {
                    // Timeout occurred, stop monitoring
                    break
                }
                
                // Check if content is now available
                let hasContent = await MainActor.run {
                    return viewModel.getAttributedStringForSection(section) != nil
                }
                
                if hasContent {
                    // Content loaded successfully
                    break
                }
                
                // Wait before checking again
                try? await Task.sleep(for: .seconds(0.5))
            }
            
            // Update loading state only if this task wasn't cancelled
            if !Task.isCancelled {
                await MainActor.run {
                    // Clear loading state
                    sectionLoadingTasks[section] = nil
                }
            }
        }

        // Store the loading task
        sectionLoadingTasks[section] = loadingTask
    }

    private func clearSectionContent() {
        // Clear all cached attributed strings except title and body
        // which we'll immediately replace
        summaryAttributedString = nil
        criticalAnalysisAttributedString = nil
        logicalFallaciesAttributedString = nil
        sourceAnalysisAttributedString = nil

        // Clear any other cached section content
        cachedContentBySection = [:]
    }

    // This function is now handled by the ViewModel and no longer needed

    // This function is now handled by the ViewModel and no longer needed

    private func clearCurrentContent() {
        titleAttributedString = nil
        bodyAttributedString = nil
        summaryAttributedString = nil
        criticalAnalysisAttributedString = nil
        logicalFallaciesAttributedString = nil
        sourceAnalysisAttributedString = nil

        // Reset sections to false except summary = true
        for key in expandedSections.keys {
            expandedSections[key] = (key == "Summary")
        }
    }

    // Using shared NavigationDirection enum

    // MARK: - Article Header

    // In articleHeaderStyle computed property
    private var articleHeaderStyle: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Topic pill
            HStack(spacing: 8) {
                if let n = currentNotification {
                    if let topic = n.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                }
                Spacer()
            }

            if let n = currentNotification {
                // Title - use rich text if available, otherwise fall back to plain text
                Group {
                    if let titleAttrString = viewModel.titleAttributedString {
                        NonSelectableRichTextView(attributedString: titleAttrString)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(n.title)
                            .font(.headline)
                            .fontWeight(n.isViewed ? .regular : .bold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Publication Date
                // n.pub_date from ArticleModel's compatibility API returns Date not optional
                Text("Published: \(n.pub_date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Body - use rich text if available, otherwise fall back to plain text
                Group {
                    if let bodyAttrString = viewModel.bodyAttributedString {
                        NonSelectableRichTextView(attributedString: bodyAttrString)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(n.body)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Affected
                if !n.affected.isEmpty {
                    Text(n.affected)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                // Domain with Source Type (source type first)
                if let domain = n.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        DomainSourceView(
                            domain: domain,
                            sourceType: n.sourceType,
                            onTap: {
                                // Default tap behavior for domain
                                if let url = URL(string: "https://\(domain)") {
                                    UIApplication.shared.open(url)
                                }
                            },
                            onSourceTap: {
                                // Expand the Source Analysis section when source type tapped
                                expandedSections["Source Analysis"] = true

                                // Scroll to the section
                                DispatchQueue.main.async {
                                    withAnimation {
                                        scrollViewProxy?.scrollTo("Source Analysis", anchor: .top)
                                    }
                                }

                                // Load content if needed
                                if needsConversion("Source Analysis") {
                                    loadContentForSection("Source Analysis")
                                }
                            }
                        )

                        // Remaining quality badges (Proof, Logic, Context)
                        QualityBadges(
                            sourcesQuality: n.sources_quality,
                            argumentQuality: n.argument_quality,
                            sourceType: n.sourceType,
                            scrollToSection: $scrollToSection,
                            onBadgeTap: { section in
                                // First ensure the section is expanded
                                expandedSections[section] = true

                                // Immediately scroll to the section without waiting for content
                                DispatchQueue.main.async {
                                    withAnimation {
                                        scrollViewProxy?.scrollTo(section, anchor: .top)
                                    }
                                }

                                // Then start loading the content if needed
                                if needsConversion(section) {
                                    loadContentForSection(section)
                                }
                            },
                            isDetailView: true
                        )
                    }
                }
            }
        }
        .id(contentTransitionID) // Force layout recalculation when this changes
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(currentNotification?.isViewed ?? true ? Color.clear : Color.blue.opacity(0.15))
    }

    // MARK: - Additional Sections

    var additionalSectionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Build the content dictionary once
            if let n = currentNotification {
                let contentDict = buildContentDictionary(from: n)
                let sections = getSections(from: contentDict)

                ForEach(sections, id: \.header) { section in
                    Divider()

                    VStack(spacing: 0) {
                        Button(action: {
                            // Toggle section state immediately without animation delay
                            let wasExpanded = expandedSections[section.header] ?? false
                            expandedSections[section.header] = !wasExpanded

                            if !wasExpanded, needsConversion(section.header) {
                                // Only load rich text content when newly expanding sections that need conversion
                                loadContentForSection(section.header)
                            }
                        }) {
                            HStack {
                                Text(section.header)
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expandedSections[section.header] ?? false ? 90 : 0))
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        if expandedSections[section.header] ?? false {
                            // Remove ANY animation wrapper
                            if needsConversion(section.header) && getAttributedStringForSection(section.header) == nil {
                                // Only show spinner for sections that need rich text conversion
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle())
                                        Text("Converting text...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding()
                            } else {
                                // Use existing content display for everything else
                                // Remove any animations that might cause fuzzy appearance
                                sectionContent(for: section)
                            }
                        }
                    }
                    .id(section.header)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .id(contentTransitionID) // Ensure layout recalculation by binding to contentTransitionID
    }

    private func needsConversion(_ sectionHeader: String) -> Bool {
        switch sectionHeader {
        case "Summary", "Critical Analysis", "Logical Fallacies",
             "Source Analysis", "Relevance", "Context & Perspective",
             "Action Recommendations", "Talking Points":
            return true
        case "Argus Engine Stats", "Preview", "Related Articles":
            return false
        default:
            return false
        }
    }

    // MARK: - Actions

    private func toggleReadStatus() {
        Task {
            await viewModel.toggleReadStatus()

            // Force an immediate UI refresh of the article header
            contentTransitionID = UUID()

            // Post notification for UI updates elsewhere in the app
            NotificationCenter.default.post(
                name: Notification.Name("ArticleReadStatusChanged"),
                object: nil,
                userInfo: [
                    "articleID": viewModel.currentArticle?.id ?? UUID(),
                    "isViewed": viewModel.currentArticle?.isViewed ?? false,
                ]
            )
        }
    }
    
    private func toggleBookmark() {
        Task {
            await viewModel.toggleBookmark()
        }
    }
    
    private func deleteNotification() {
        Task {
            await viewModel.deleteArticle()

            // Navigate to next article or dismiss
            if viewModel.currentIndex < viewModel.articles.count - 1 {
                navigateToArticle(direction: .next)
            } else {
                dismiss()
            }
        }
    }
    
    /// Helper method to get a cached attributed string for a section
    private func getAttributedStringForSection(_ section: String) -> NSAttributedString? {
        let cachedContent = viewModel.getAttributedStringForSection(section)
        
        if cachedContent == nil && !isSectionLoading(section) {
            AppLogger.database.warning("⚠️ View requested cached content for \(section) but it was nil despite being reported as loaded")
        }
        
        return cachedContent
    }
    
    /// Helper function to check if section content is being loaded
    private func isSectionLoading(_ section: String) -> Bool {
        return sectionLoadingTasks[section] != nil
    }
    
    /// Mark the current article as viewed
    private func markAsViewed() {
        Task {
            do {
                try await viewModel.markAsViewed()

                // Post notification when article is viewed
                NotificationCenter.default.post(name: Notification.Name("ArticleViewed"), object: nil)

                // Update app badge count and remove notification if exists
                NotificationUtils.updateAppBadgeCount()
                if let notification = currentNotification {
                    AppDelegate().removeNotificationIfExists(jsonURL: notification.jsonURL)
                }
            } catch {
                AppLogger.database.error("Failed to mark article as viewed: \(error)")
            }
        }
    }
    
    /// Load the minimal content needed for the initial display
    private func loadInitialMinimalContent() {
        // Only proceed if we have a notification
        guard let article = currentNotification else { return }

        // Log the loading attempt
        AppLogger.database.debug("Loading initial content for article ID: \(article.id)")

        // Ensure the Summary section is expanded
        expandedSections["Summary"] = true

        // Use synchronous loading for critical above-the-fold content
        Task {
            // First, load the title and body synchronously to prevent flashing of unformatted content
            await viewModel.loadMinimalContent()

            // Log minimal content load completion
            AppLogger.database.debug("✅ Minimal content loaded for article ID: \(article.id)")

            // After minimal content is loaded, force load the Summary section
            loadContentForSection("Summary")

            // Log that we've explicitly loaded the Summary section
            AppLogger.database.debug("✅ Summary section load triggered for initial view")
        }
    }
    
    /// Generate content for a section
    @ViewBuilder
    private func sectionContent(for section: ContentSection) -> some View {
        switch section.header {
        // MARK: - Summary
        case "Summary":
            SectionContentView(
                section: section,
                attributedString: getAttributedStringForSection(section.header),
                isLoading: isSectionLoading(section.header)
            )
            
        // MARK: - Source Analysis
        case "Source Analysis":
            VStack(alignment: .leading, spacing: 10) {
                // Source type and domain info
                HStack {
                    // Source type badge first
                    if let sourceData = section.content as? [String: Any],
                       let sourceType = sourceData["sourceType"] as? String,
                       !sourceType.isEmpty
                    {
                        HStack(spacing: 4) {
                            Image(systemName: sourceTypeIcon(for: sourceType))
                                .font(.footnote)
                                .foregroundColor(.blue)
                            Text(sourceType.capitalized)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(getSourceTypeColor(sourceType).opacity(0.2))
                        .foregroundColor(getSourceTypeColor(sourceType))
                        .cornerRadius(8)
                    }

                    // Domain after source type
                    if let domain = currentNotification?.domain?.replacingOccurrences(of: "www.", with: ""),
                       !domain.isEmpty
                    {
                        Text(domain)
                            .font(.subheadline)
                            .foregroundColor(.blue)
                            .onTapGesture {
                                if let url = URL(string: "https://\(domain)") {
                                    UIApplication.shared.open(url)
                                }
                            }
                    }

                    Spacer()
                }
                .padding(.horizontal, 4)

                // Source analysis text
                if let sourceData = section.content as? [String: Any] {
                    SectionContentView(
                        section: ContentSection(header: section.header, content: sourceData["text"] ?? ""),
                        attributedString: getAttributedStringForSection(section.header),
                        isLoading: isSectionLoading(section.header)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .textSelection(.enabled)
            
        // MARK: - Critical Analysis, Logical Fallacies, Relevance, Context & Perspective
        case "Critical Analysis", "Logical Fallacies", "Relevance", "Context & Perspective":
            SectionContentView(
                section: section,
                attributedString: getAttributedStringForSection(section.header),
                isLoading: isSectionLoading(section.header)
            )
            
// MARK: - Related Articles
case "Related Articles":
    VStack(alignment: .leading, spacing: 8) {
        if let relatedArticles = section.content as? [RelatedArticle], !relatedArticles.isEmpty {
            EnhancedRelatedArticlesView(articles: relatedArticles) { jsonURL in
                loadRelatedArticle(jsonURL: jsonURL)
            }
        } else if let relatedArticles = section.content as? [[String: Any]], !relatedArticles.isEmpty {
            // Legacy fallback for compatibility during transition
            VStack(spacing: 6) {
                ProgressView()
                    .padding()
                Text("Converting related articles data...")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 6) {
                ProgressView()
                    .padding()
                Text("Loading related articles...")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.top, 6)
            
        // MARK: - Argus Engine Stats
        case "Argus Engine Stats":
            if let details = section.content as? ArgusDetailsData {
                if let rawMarkdown = details.systemInfo?["raw_markdown"] as? [String: Any],
                   let content = rawMarkdown["content"] as? String
                {
                    // This means we have raw markdown - display it as text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Engine Stats (Raw Content)")
                            .font(.headline)
                            .padding(.bottom, 4)

                        Text(content)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                    }
                    .padding()
                } else {
                    // Normal detailed view
                    ArgusDetailsView(data: details)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No engine statistics available.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
        // MARK: - Preview
        case "Preview":
            VStack(spacing: 8) {
                if let urlString = section.content as? String,
                   let articleURL = URL(string: urlString)
                {
                    SafariView(url: articleURL)
                        .frame(height: 450)
                    Button("Open in Browser") {
                        UIApplication.shared.open(articleURL)
                    }
                    .font(.callout)
                    .padding(.top, 4)
                } else {
                    Text("Invalid URL")
                        .font(.callout)
                        .frame(height: 450)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            
        // MARK: - Default fallback
        default:
            Text(section.content as? String ?? "")
                .font(.callout)
                .padding(.top, 6)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
    
    private func sourceTypeIcon(for sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "press", "news":
            return "newspaper"
        case "blog":
            return "text.bubble"
        case "academic":
            return "book"
        case "government":
            return "building.columns"
        case "social media":
            return "person.2"
        default:
            return "doc.text"
        }
    }

    private func getSourceTypeColor(_ sourceType: String) -> Color {
        switch sourceType.lowercased() {
        case "press", "news":
            return .blue
        case "blog":
            return .orange
        case "academic", "research":
            return .purple
        case "gov", "government":
            return .green
        case "opinion":
            return .red
        default:
            return .gray
        }
    }
    
    /// Parse engine stats JSON into a structured type
    private func parseEngineStatsJSON(_ jsonString: String, fallbackDate: Date) -> ArgusDetailsData? {
        // Try to parse as JSON first
        if let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            // Using only snake_case for JSON field names
            let model = dict["model"] as? String ?? ""
            let elapsedTime = dict["elapsed_time"] as? Double ?? 0.0
            let stats = dict["stats"] as? String ?? "0:0:0:0:0:0"
            let systemInfo = dict["system_info"] as? [String: Any]
            
            AppLogger.database.debug("Engine stats parsed: model=\(model), time=\(elapsedTime), stats=\(stats)")
            
            return ArgusDetailsData(
                model: model,
                elapsedTime: elapsedTime,
                date: fallbackDate,
                stats: stats,
                systemInfo: systemInfo
            )
        }

        // If that fails, just create a hardcoded object with the raw text
        AppLogger.database.debug("Failed to parse engine stats JSON, using fallback")
        return ArgusDetailsData(
            model: "Unknown",
            elapsedTime: 0.0,
            date: fallbackDate,
            stats: "0:0:0:0:0:0",
            systemInfo: ["raw_content": jsonString as Any]
        )
    }
    
    // This function has been replaced by direct JSON decoding with RelatedArticle

// This struct needs to be deleted from here as we're moving it outside the NewsDetailView struct
    
    /// Load a related article using its JSON URL
    private func loadRelatedArticle(jsonURL: String) {
        AppLogger.database.debug("Loading related article with jsonURL: \(jsonURL)")
        
        Task {
            // Perform the fetch directly on the MainActor
            await MainActor.run {
                do {
                    // Use modelContext to find the article
                    let foundArticles = try modelContext.fetch(FetchDescriptor<ArticleModel>(
                        predicate: #Predicate<ArticleModel> { article in
                            article.jsonURL == jsonURL
                        }
                    ))
                    
                    // Process results
                    if let foundArticle = foundArticles.first {
                        // Create a dedicated view model for this article
                        let articleViewModel = NewsDetailViewModel(
                            articles: [foundArticle],
                            allArticles: [foundArticle],
                            currentIndex: 0,
                            initiallyExpandedSection: "Summary"
                        )
                        
                        // Present the detail view
                        let detailView = NewsDetailView(viewModel: articleViewModel)
                        let hostingController = UIHostingController(rootView: detailView)
                        
                        // Get the top view controller to present from
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let window = windowScene.windows.first,
                           let rootVC = window.rootViewController {
                            var topVC = rootVC
                            while let presentedVC = topVC.presentedViewController {
                                topVC = presentedVC
                            }
                            
                            // Present the view controller
                            topVC.present(hostingController, animated: true)
                        }
                    } else {
                        AppLogger.database.error("Related article not found with jsonURL: \(jsonURL)")
                    }
                } catch {
                    AppLogger.database.error("Failed to fetch related article: \(error)")
                }
            }
        }
    }
    
    /// Helper function to build content dictionary from an article
    private func buildContentDictionary(from article: ArticleModel) -> [String: Any] {
        var content: [String: Any] = [:]

        // Add URL if available
        if let domain = article.domain {
            content["url"] = "https://\(domain)"
        }

        // Transfer metadata fields directly without processing
        content["sources_quality"] = article.sourcesQuality
        content["argument_quality"] = article.argument_quality
        content["sourceType"] = article.sourceType

        // Just check if these fields exist without converting to attributed strings
        content["summary"] = article.summary
        content["criticalAnalysis"] = article.criticalAnalysis
        content["logicalFallacies"] = article.logicalFallacies
        content["relationToTopic"] = article.relationToTopic
        content["additionalInsights"] = article.additionalInsights

        // For source analysis, create a dictionary with the text and source type
        if let sourceAnalysis = article.sourceAnalysis {
            content["sourceAnalysis"] = [
                "text": sourceAnalysis,
                "sourceType": article.sourceType ?? "",
            ]
        }

        // Transfer engine stats and similar articles as is
        if let engineStats = article.engine_stats,
           let engineStatsData = engineStats.data(using: .utf8),
           let engineStatsDict = try? JSONSerialization.jsonObject(with: engineStatsData) as? [String: Any]
        {
            // Transfer relevant engine stats fields
            if let model = engineStatsDict["model"] as? String {
                content["model"] = model
            }
            if let elapsedTime = engineStatsDict["elapsed_time"] as? Double {
                content["elapsedTime"] = elapsedTime
            }
            if let stats = engineStatsDict["stats"] as? String {
                content["stats"] = stats
            }
            if let systemInfo = engineStatsDict["system_info"] as? [String: Any] {
                content["systemInfo"] = systemInfo
            }
        }
        // Alternative approach using engineDetails if available
        else if let details = article.engineDetails {
            content["model"] = details.model
            content["elapsedTime"] = details.elapsedTime
            content["stats"] = details.stats
            content["systemInfo"] = details.systemInfo
        }

        // Transfer related articles as structured data - with logging
        if let relatedArticles = article.relatedArticles {
            // Convert to JSON array for content dictionary
            if let data = try? JSONEncoder().encode(relatedArticles),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                content["similarArticles"] = json
                AppLogger.database.debug("Added \(json.count) related articles to content dictionary")
            } else {
                AppLogger.database.error("Failed to encode related articles for content dictionary")
            }
        } else {
            AppLogger.database.debug("No related articles found in article \(article.id)")
        }

        return content
    }
    
    /// Helper view for displaying section content
    struct SectionContentView: View {
        let section: ContentSection
        let attributedString: NSAttributedString?
        let isLoading: Bool

        var body: some View {
            Group {
                if let attributedString = attributedString {
                    // Show formatted rich text when available - NO ANIMATIONS
                    NonSelectableRichTextView(attributedString: attributedString)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .textSelection(.enabled)
                } else if isLoading {
                    // Show loading indicator when content is being generated - NO ANIMATIONS
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Formatting text...")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    // IMPROVEMENT: Never regenerate blobs on-the-fly, show fallback UI instead
                    // The previous code was causing blob regeneration even though a blob exists
                    VStack(spacing: 8) {
                        Text("Unable to display formatted content")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                        // Last resort display of raw content without conversion
                        let rawContent = section.content as? String ?? "No content available"
                        Text(rawContent)
                            .font(.callout)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
    }
}

// MARK: - Supporting types and structures

/// ContentSection struct used to represent sections in the detail view
struct ContentSection {
    let header: String
    let content: Any

    /// If `content` is actually an `ArgusDetailsData`, return it; else nil.
    var argusDetails: ArgusDetailsData? {
        content as? ArgusDetailsData
    }
}

/// ArgusDetailsView for displaying engine stats
struct ArgusDetailsView: View {
    let data: ArgusDetailsData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated with \(data.model) in \(String(format: "%.2f", data.elapsedTime)) seconds.")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Metrics:")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(formattedStats(data.stats))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(.leading, 16)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let sysInfo = data.systemInfo {
                Text("System Information:")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let buildInfo = sysInfo["build_info"] as? [String: Any] {
                    VStack(alignment: .leading) {
                        Text("Build Details:")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        FormatBuildInfo(buildInfo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let runtimeMetrics = sysInfo["runtime_metrics"] as? [String: Any] {
                    VStack(alignment: .leading) {
                        Text("Runtime Metrics:")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        FormatRuntimeMetrics(runtimeMetrics)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Received from Argus on \(data.date, format: .dateTime.month(.wide).day().year().hour().minute().second()).")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedStats(_ stats: String) -> String {
        let parts = stats.split(separator: ":").map { String($0) }
        guard parts.count == 6 else {
            return "Invalid stats format"
        }

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        func formattedNumber(_ value: String) -> String {
            if let number = Int(value), let formatted = numberFormatter.string(from: NSNumber(value: number)) {
                return formatted
            }
            return value
        }

        let descriptions = [
            "Articles reviewed: \(formattedNumber(parts[0]))",
            "Matched: \(formattedNumber(parts[1]))",
            "Queued to review: \(formattedNumber(parts[2]))",
            "Life safety queue: \(formattedNumber(parts[3]))",
            "Matched topics queue: \(formattedNumber(parts[4]))",
            "Clients: \(formattedNumber(parts[5]))",
        ]

        return descriptions.joined(separator: "\n")
    }

    struct FormatBuildInfo: View {
        let buildInfo: [String: Any]

        init(_ buildInfo: [String: Any]) {
            self.buildInfo = buildInfo
        }

        var body: some View {
            VStack(alignment: .leading) {
                if let version = buildInfo["version"] as? String {
                    Text("Version: \(version)")
                }
                if let rustVersion = buildInfo["rust_version"] as? String {
                    Text("Rust: \(rustVersion)")
                }
                if let targetOs = buildInfo["target_os"] as? String {
                    Text("OS: \(targetOs)")
                }
                if let targetArch = buildInfo["target_arch"] as? String {
                    Text("Arch: \(targetArch)")
                }
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    struct FormatRuntimeMetrics: View {
        let metrics: [String: Any]

        init(_ metrics: [String: Any]) {
            self.metrics = metrics
        }

        var body: some View {
            VStack(alignment: .leading) {
                if let cpuUsage = metrics["cpu_usage_percent"] as? Double {
                    Text("CPU: \(String(format: "%.2f%%", cpuUsage))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let memoryTotal = metrics["memory_total_kb"] as? Int {
                    Text("Total Memory: \(formatMemory(memoryTotal))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let memoryUsage = metrics["memory_usage_kb"] as? Int {
                    Text("Used Memory: \(formatMemory(memoryUsage))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let threadCount = metrics["thread_count"] as? Int {
                    Text("Threads: \(threadCount)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let uptime = metrics["uptime_seconds"] as? Int {
                    Text("Uptime: \(formatUptime(uptime))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func formatMemory(_ kb: Int) -> String {
            let units = ["KB", "MB", "GB", "TB"]
            var value = Double(kb)
            var unitIndex = 0

            while value >= 1024 && unitIndex < units.count - 1 {
                value /= 1024
                unitIndex += 1
            }

            return String(format: "%.2f %@", value, units[unitIndex])
        }

        private func formatUptime(_ seconds: Int) -> String {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
    }
}

/// SimilarArticleRow for displaying related articles
struct SimilarArticleRow: View {
    let articleDict: [String: Any]
    // Using the view model directly to get articles and set current index
    // rather than binding to local variables that don't exist anymore
    @State private var viewModelForRow: NewsDetailViewModel? = nil
    var isLastItem: Bool = false

    @Environment(\.modelContext) private var modelContext
    @State private var showError = false
    @State private var showDetailView = false
    @State private var selectedArticle: ArticleModel?

    // Cache for processed content
    @State private var processedTitle: String = ""
    @State private var processedSummary: String = ""
    @State private var formattedDate: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Make the title clickable to show the overlay
            Button(action: {
                if let jsonURL = articleDict["json_url"] as? String {
                    loadSimilarArticle(jsonURL: jsonURL)
                } else {
                    showError = true
                }
            }) {
                Text(processedTitle)
                    .font(.headline)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            // Published Date
            if !formattedDate.isEmpty {
                Text("Published: \(formattedDate)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Topic styled as a pill
            if let category = articleDict["category"] as? String, !category.isEmpty {
                Text(category.uppercased())
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }

            // Summary with Markdown formatting
            if !processedSummary.isEmpty {
                Text(processedSummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Quality Score
            if let qualityScore = articleDict["quality_score"] as? Int, qualityScore > 0 {
                Text("Quality: \(qualityDescription(for: qualityScore))")
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            // Similarity Score
            if let similarityScore = articleDict["similarity_score"] as? Double {
                Text("Similarity: \(String(format: "%.3f", similarityScore * 100))%")
                    .font(.caption)
                    .foregroundColor(similarityScore >= 0.95 ? .red : .secondary)
                    .fontWeight(similarityScore >= 0.98 ? .bold : .regular)
            }
        }
        .padding(8)
        .background(Color(uiColor: .systemGray6))
        .cornerRadius(8)
        .alert("Sorry, this article doesn't exist.", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showDetailView, onDismiss: {
            selectedArticle = nil
        }) {
            if let article = selectedArticle {
                // Create a view model with the article
                let articleViewModel = NewsDetailViewModel(
                    articles: [article],
                    allArticles: [article],
                    currentIndex: 0,
                    initiallyExpandedSection: "Summary"
                )
                // Use the new initializer with the view model
                NewsDetailView(viewModel: articleViewModel)
            }
        }
        .onAppear {
            // Process content once when the view appears
            processContent()
        }
    }

    // Process content in a separate function to avoid doing it in the view body
    private func processContent() {
        // Extract and process title
        let rawTitle = articleDict["title"] as? String ?? "Untitled"
        processedTitle = markdownFormatted(rawTitle) ?? rawTitle

        // Extract and process summary
        let rawSummary = articleDict["tiny_summary"] as? String ?? ""
        processedSummary = markdownFormatted(rawSummary) ?? rawSummary

        // Process date
        let rawDate = articleDict["published_date"] as? String ?? ""
        if let date = parseDate(from: rawDate) {
            formattedDate = date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        } else {
            formattedDate = rawDate
        }
    }

    // Helper function to apply Markdown formatting with a fallback
    private func markdownFormatted(_ text: String) -> String? {
        if let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody") {
            return attributedString.string
        }
        return text.isEmpty ? nil : text
    }

    // Helper function to convert quality score to a descriptive label
    private func qualityDescription(for score: Int) -> String {
        switch score {
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Excellent"
        default: return "Unknown"
        }
    }

    // Loads a similar article with optimized fetch
    private func loadSimilarArticle(jsonURL: String) {
        // Store the jsonURL to use in the task
        let urlToFetch = jsonURL

        Task {
            // Perform the fetch directly on the MainActor (MainActor.run doesn't throw errors)
            await MainActor.run {
                do {
                    // Use modelContext directly on the MainActor
                    let foundArticles = try modelContext.fetch(FetchDescriptor<ArticleModel>(
                        predicate: #Predicate<ArticleModel> { article in
                            article.jsonURL == urlToFetch
                        }
                    ))

                    // Process results immediately within the MainActor context
                    if let foundArticle = foundArticles.first {
                        selectedArticle = foundArticle
                        showDetailView = true
                    } else {
                        showError = true
                    }
                } catch {
                    AppLogger.sync.error("Failed to fetch similar article: \(error)")
                    showError = true
                }
            }
        }
    }

    // Helper function to parse a date string into a Date object
    private func parseDate(from dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            return date
        }

        let altFormatter = DateFormatter()
        altFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return altFormatter.date(from: dateString)
    }
}

/// ShareSelectionView for sharing article content
struct ShareSelectionView: View {
    let content: [String: Any]?
    let notification: ArticleModel
    @Binding var selectedSections: Set<String>
    @Binding var isPresented: Bool
    @State private var formatText = true
    @State private var shareItems: [Any] = []

    private var isShareSheetPresented: Binding<Bool> {
        Binding<Bool>(
            get: { !self.shareItems.isEmpty },
            set: { newValue in
                if !newValue {
                    self.shareItems = []
                    self.isPresented = false
                } else {
                    self.prepareShareContent()
                }
            }
        )
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Select the sections to share:").padding(.top)) {
                    ForEach(getSections(from: content ?? [:]), id: \.header) { section in
                        if section.header != "Article Preview" {
                            Button(action: {
                                if selectedSections.contains(section.header) {
                                    selectedSections.remove(section.header)
                                } else {
                                    selectedSections.insert(section.header)
                                }
                            }) {
                                HStack {
                                    Text(section.header)
                                    Spacer()
                                    if selectedSections.contains(section.header) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $formatText) {
                        VStack(alignment: .leading) {
                            Text("Format text")
                            Text("Some apps are unable to handle formatted text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Share Content")
            .navigationBarItems(
                leading: Button("Cancel") { isPresented = false },
                trailing: Button("Share") {
                    isShareSheetPresented.wrappedValue = true
                }
                .disabled(selectedSections.isEmpty)
            )
        }
        .sheet(isPresented: isShareSheetPresented) {
            ActivityViewController(activityItems: shareItems) { _, _, _, _ in
                isShareSheetPresented.wrappedValue = false
            }
        }
        .onAppear {
            if selectedSections.isEmpty {
                selectedSections = ["Title", "Brief Summary", "Summary", "Article URL"]
            }
        }
    }

    private func prepareShareContent() {
        var shareText = ""
        var articleURL: String? = nil

        for section in getSections(from: content ?? [:]) {
            if selectedSections.contains(section.header) {
                var sectionContent: String? = nil

                switch section.header {
                case "Title":
                    // Use title directly from notification
                    sectionContent = notification.title

                case "Brief Summary":
                    // Use body directly from notification
                    sectionContent = notification.body

                case "Article URL":
                    articleURL = notification.getArticleUrl(additionalContent: content)
                    continue // SKip adding this to shareText

                case "Summary":
                    // Get from notification
                    sectionContent = notification.summary

                case "Critical Analysis":
                    sectionContent = notification.criticalAnalysis

                case "Logical Fallacies":
                    sectionContent = notification.logicalFallacies

                case "Source Analysis":
                    sectionContent = notification.sourceAnalysis

                case "Relevance":
                    sectionContent = notification.relationToTopic

                case "Context & Perspective":
                    sectionContent = notification.additionalInsights

                case "Argus Engine Stats":
                    if let details = section.argusDetails {
                        sectionContent = """
                        **Model:** \(details.model)
                        **Elapsed Time:** \(String(format: "%.2f", details.elapsedTime)) seconds
                        **Metrics:**
                        \(formattedStats(details.stats))
                        **Received:** \(details.date.formatted(.dateTime.month().day().year().hour().minute().second()))
                        """
                        if let systemInfo = details.systemInfo {
                            sectionContent! += formatSystemInfo(systemInfo)
                        }
                    } else if let engineStats = notification.engine_stats {
                        sectionContent = "Engine Stats: \(engineStats)"
                    }

                default:
                    sectionContent = section.content as? String
                }

                if let contentToShare = sectionContent, !contentToShare.isEmpty {
                    if section.header == "Title" || section.header == "Brief Summary" {
                        // Share these fields as raw content, without headers
                        shareText += "\(contentToShare)\n\n"
                    } else {
                        // Keep headers for everything else with bold formatting
                        shareText += "**\(section.header):**\n\(contentToShare)\n\n"
                    }
                }
            }
        }

        // If we have a URL, add it at the very end of the text
        if let url = articleURL, selectedSections.contains("Article URL") {
            shareText = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
            shareText += "\n\n\(url)"
        }

        // If no sections were selected, avoid sharing empty content
        if shareText.isEmpty {
            shareText = "No content selected for sharing."
        }

        // Apply markdown formatting if enabled
        if formatText {
            if let attributedString = markdownToAttributedString(
                shareText,
                textStyle: "UIFontTextStyleBody"
            ) {
                shareItems = [attributedString]
            } else {
                shareItems = [shareText]
            }
        } else {
            shareItems = [shareText]
        }
    }

    private func formattedStats(_ stats: String) -> String {
        let parts = stats.split(separator: ":").map { String($0) }
        guard parts.count == 6 else {
            return "Invalid stats format"
        }

        let descriptions = [
            "• Articles reviewed: \(parts[0])",
            "• Matched: \(parts[1])",
            "• Queued to review: \(parts[2])",
            "• Life safety queue: \(parts[3])",
            "• Matched topics queue: \(parts[4])",
            "• Clients: \(parts[5])",
        ]

        return descriptions.joined(separator: "\n")
    }

    private func formatSystemInfo(_ systemInfo: [String: Any]) -> String {
        var formattedInfo = "\n**System Info:**\n"
        if let buildInfo = systemInfo["build_info"] as? [String: Any] {
            if let version = buildInfo["version"] as? String {
                formattedInfo += "• Version: \(version)\n"
            }
            if let rustVersion = buildInfo["rust_version"] as? String {
                formattedInfo += "• Rust: \(rustVersion)\n"
            }
            if let targetOs = buildInfo["target_os"] as? String {
                formattedInfo += "• OS: \(targetOs)\n"
            }
            if let targetArch = buildInfo["target_arch"] as? String {
                formattedInfo += "• Arch: \(targetArch)\n"
            }
        }

        return formattedInfo
    }

    private var sectionHeaders: [String] {
        getSections(from: content ?? [:]).map { $0.header }
    }

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections = [
            ContentSection(header: "Title", content: json["tinyTitle"] as? String ?? ""),
            ContentSection(header: "Brief Summary", content: json["tinySummary"] as? String ?? ""),
            ContentSection(header: "Article URL", content: json["url"] as? String ?? ""),
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relationToTopic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["criticalAnalysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logicalFallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["sourceAnalysis"] as? String ?? ""),
        ]

        let insights = json["additionalInsights"] as? String ?? notification.additionalInsights ?? ""
        sections.append(ContentSection(header: "Context & Perspective", content: insights))
        
        // Add Action Recommendations if available
        let recommendations = json["actionRecommendations"] as? String ?? notification.actionRecommendations ?? ""
        if !recommendations.isEmpty {
            sections.append(ContentSection(header: "Action Recommendations", content: recommendations))
        }
        
        // Add Talking Points if available
        let talkingPoints = json["talkingPoints"] as? String ?? notification.talkingPoints ?? ""
        if !talkingPoints.isEmpty {
            sections.append(ContentSection(header: "Talking Points", content: talkingPoints))
        }

        if let model = json["model"] as? String,
           let elapsedTime = json["elapsedTime"] as? Double,
           let stats = json["stats"] as? String
        {
            sections.append(ContentSection(
                header: "Argus Engine Stats",
                content: ArgusDetailsData(
                    model: model,
                    elapsedTime: elapsedTime,
                    date: notification.date,
                    stats: stats,
                    systemInfo: json["systemInfo"] as? [String: Any]
                )
            ))
        }

        return sections
    }

    private func formatMemory(_ kb: Int) -> String {
        let gb = Double(kb) / 1_048_576.0
        return String(format: "%.2f GB", gb)
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

/// Activity view controller for sharing content
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: UIActivityViewController.CompletionWithItemsHandler?

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}


/// SafariView for displaying web content
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @AppStorage("useReaderMode") private var useReaderMode: Bool = true

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = useReaderMode
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
