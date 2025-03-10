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
    @State private var notifications: [NotificationData]
    @State private var allNotifications: [NotificationData]
    @State private var currentIndex: Int
    @State private var deletedIDs: Set<UUID> = []
    @State private var batchSize: Int = 50
    @State private var scrollViewProxy: ScrollViewProxy? = nil
    @State private var scrollToTopTrigger = UUID()
    @State private var isNavigating = false
    @State private var loadingStage = 0 // 0: not loading, 1: loading, 2: formatting

    @State private var titleAttributedString: NSAttributedString?
    @State private var bodyAttributedString: NSAttributedString?
    @State private var summaryAttributedString: NSAttributedString?
    @State private var criticalAnalysisAttributedString: NSAttributedString?
    @State private var logicalFallaciesAttributedString: NSAttributedString?
    @State private var sourceAnalysisAttributedString: NSAttributedString?

    @State private var tabTransitionState: TabTransitionState = .idle
    @State private var tabChangeTask: Task<Void, Never>? = nil
    @State private var cachedContentBySection: [String: NSAttributedString] = [:]
    @State private var visibleTabIndex: Int? = nil

    private var isCurrentIndexValid: Bool {
        currentIndex >= 0 && currentIndex < notifications.count
    }

    private var currentNotification: NotificationData? {
        guard isCurrentIndexValid else { return nil }
        return notifications[currentIndex]
    }

    @State private var scrollToSection: String? = nil
    let initiallyExpandedSection: String?
    @State private var showDeleteConfirmation = false
    @State private var additionalContent: [String: Any]? = nil
    @State private var isLoadingAdditionalContent = false
    @State private var expandedSections: [String: Bool] = [
        "Article": false,
        "Summary": true,
        "Relevance": false,
        "Critical Analysis": false,
        "Logical Fallacies": false,
        "Source Analysis": false,
        "Context & Perspective": false,
        "Argus Engine Stats": false,
        "Vector WIP": false,
    ]
    @State private var isSharePresented = false
    @State private var selectedSections: Set<String> = []
    @State private var articleContent: String? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(
        notifications: [NotificationData],
        allNotifications: [NotificationData],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil
    ) {
        _notifications = State(initialValue: notifications)
        _allNotifications = State(initialValue: allNotifications)
        _currentIndex = State(initialValue: currentIndex)
        self.initiallyExpandedSection = initiallyExpandedSection
    }

    var body: some View {
        NavigationStack {
            Group {
                if currentNotification != nil {
                    VStack(spacing: 0) {
                        topBar
                        ScrollView {
                            ScrollViewReader { proxy in
                                VStack {
                                    // Add an invisible view at the top to scroll to
                                    Color.clear
                                        .frame(height: 1)
                                        .id("top")

                                    if isNavigating {
                                        // Show a loading indicator when navigating
                                        VStack(spacing: 16) {
                                            ProgressView()
                                                .padding(.top, 40)

                                            Text(loadingStage == 1 ? "Loading article..." : "Formatting content...")
                                                .foregroundColor(.secondary)

                                            Spacer()
                                        }
                                        .frame(minHeight: 300)
                                    } else {
                                        articleHeaderStyle
                                        additionalSectionsView
                                    }
                                }
                                .onChange(of: scrollToTopTrigger) { _, _ in
                                    // Scroll to top when the trigger changes
                                    withAnimation {
                                        proxy.scrollTo("top", anchor: .top)
                                    }
                                }
                                .onAppear {
                                    self.scrollViewProxy = proxy
                                }
                            }
                        }
                        bottomToolbar
                    }
                } else {
                    Text("Article no longer available")
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                dismiss()
                            }
                        }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                setupDeletionHandling()
                markAsViewed()
                loadContent(contentType: .summary)
                if let section = initiallyExpandedSection {
                    expandedSections[section] = true
                }
            }
            .onChange(of: notifications) { _, _ in
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
                    notification: currentNotification ?? notifications[0],
                    selectedSections: $selectedSections,
                    isPresented: $isSharePresented
                )
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.width > 100 {
                            dismiss()
                        }
                    }
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
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
                .disabled(!isCurrentIndexValid || currentIndex == 0)

                Button {
                    navigateToArticle(direction: .next)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }
                .disabled(!isCurrentIndexValid || currentIndex == notifications.count - 1)
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

            toolbarButton(icon: currentNotification?.isArchived ?? false ? "tray.and.arrow.up.fill" : "archivebox", label: "Archive") {
                toggleArchive()
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
        case "Archive":
            return notification.isArchived ? .orange : .primary
        default:
            return .primary
        }
    }

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections = [ContentSection]()

        // Use local data if available, otherwise use the JSON
        if let notification = currentNotification {
            // Summary section
            let summaryContent = notification.summary ?? (json["summary"] as? String ?? "")
            sections.append(ContentSection(header: "Summary", content: summaryContent))

            // Relevance section
            let relevanceContent = notification.relation_to_topic ?? (json["relation_to_topic"] as? String ?? "")
            sections.append(ContentSection(header: "Relevance", content: relevanceContent))

            // Critical Analysis section
            let analysisContent = notification.critical_analysis ?? (json["critical_analysis"] as? String ?? "")
            sections.append(ContentSection(header: "Critical Analysis", content: analysisContent))

            // Logical Fallacies section
            let fallaciesContent = notification.logical_fallacies ?? (json["logical_fallacies"] as? String ?? "")
            sections.append(ContentSection(header: "Logical Fallacies", content: fallaciesContent))

            // Source Analysis section - UPDATED TO USE THE source_analysis FIELD DIRECTLY
            // Get source_analysis from JSON, ensuring it's not empty
            let sourceAnalysis = (json["source_analysis"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? notification.source_analysis // Fall back to stored source_analysis
                ?? "" // Default to empty string if neither is available

            // Create a custom object to pass the sourceAnalysis text and source type only
            let sourceAnalysisData: [String: Any] = [
                "text": sourceAnalysis,
                "sourceType": notification.source_type ?? (json["source_type"] as? String ?? ""),
            ]

            sections.append(ContentSection(header: "Source Analysis", content: sourceAnalysisData))

            // Additional Insights section (optional)
            if let insights = notification.additional_insights, !insights.isEmpty {
                sections.append(ContentSection(header: "Context & Perspective", content: insights))
            } else if let insights = json["additional_insights"] as? String, !insights.isEmpty {
                sections.append(ContentSection(header: "Context & Perspective", content: insights))
            }

            // Argus Engine Stats section
            if let engineStatsJson = notification.engine_stats,
               let engineStats = getEngineStatsData(from: engineStatsJson)
            {
                sections.append(ContentSection(
                    header: "Argus Engine Stats",
                    content: (
                        engineStats.model,
                        engineStats.elapsedTime,
                        engineStats.date,
                        engineStats.stats,
                        engineStats.systemInfo
                    )
                ))
            } else if let model = json["model"] as? String,
                      let elapsedTime = json["elapsed_time"] as? Double,
                      let stats = json["stats"] as? String
            {
                sections.append(ContentSection(
                    header: "Argus Engine Stats",
                    content: (
                        model,
                        elapsedTime,
                        notification.date,
                        stats,
                        json["system_info"] as? [String: Any]
                    )
                ))
            }

            // Preview section
            sections.append(ContentSection(header: "Preview", content: getArticleUrl(notification) ?? (json["url"] as? String ?? "")))

            // Similar Articles section (Vector WIP)
            if let similarArticlesJson = notification.similar_articles,
               let similarArticles = getSimilarArticles(from: similarArticlesJson),
               !similarArticles.isEmpty
            {
                sections.append(ContentSection(header: "Vector WIP", content: similarArticles))
            } else if let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty {
                sections.append(ContentSection(header: "Vector WIP", content: similarArticles))
            }
        }

        return sections
    }

    // MARK: - Navigation and Safety Methods

    // SAFETY: Added validation and safe navigation
    private func validateAndAdjustIndex() {
        if !isCurrentIndexValid {
            if let targetID = currentNotification?.id,
               let newIndex = notifications.firstIndex(where: { $0.id == targetID })
            {
                currentIndex = newIndex
            } else {
                currentIndex = max(0, notifications.count - 1)
            }
        }
    }

    private func tryNavigateToValidArticle() {
        if let currentNotification {
            let currentID = currentNotification.id
            if let newIndex = notifications.firstIndex(where: {
                $0.id != currentID && !deletedIDs.contains($0.id)
            }) {
                currentIndex = newIndex
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

    private func navigateToArticle(direction: NavigationDirection) {
        guard isCurrentIndexValid else { return }

        // Cancel any pending tasks from previous navigations
        tabChangeTask?.cancel()

        // Set initial loading state (brief "Loading article..." message)
        loadingStage = 1
        isNavigating = true

        // Start asynchronous work
        tabChangeTask = Task {
            // Find the next valid article first
            let targetIndex = (direction == .next) ? currentIndex + 1 : currentIndex - 1
            let validArticleFound = await findValidArticle(from: targetIndex, direction: direction)

            if !validArticleFound {
                // If we couldn't navigate, reset the state
                await MainActor.run {
                    loadingStage = 0
                    isNavigating = false
                }
                return
            }

            // We found a valid article, now prepare for transition
            await MainActor.run {
                // Clear content and scroll to top
                clearCurrentContent()
                scrollToTopTrigger = UUID()
            }

            // Handle pagination in the background
            await handlePagination(direction: direction, targetIndex: currentIndex)

            // CRITICAL CHANGE: Load only essential content with minimal formatting
            guard let notification = currentNotification else {
                await MainActor.run {
                    isNavigating = false
                    loadingStage = 0
                }
                return
            }

            // Mark as viewed - quick operation
            await MainActor.run {
                markAsViewed()
            }

            // Build content dictionary (fast operation, no formatting)
            let basicContent = buildContentDictionary(from: notification)

            // Load just the title and body attributes (typically already cached)
            let titleString = await loadAttributedStringAsync(for: .title, from: notification)
            let bodyString = await loadAttributedStringAsync(for: .body, from: notification)

            // Update UI with what we have so far
            await MainActor.run {
                additionalContent = basicContent
                titleAttributedString = titleString
                bodyAttributedString = bodyString

                // We now have enough to display the article header
                // Show the article header while we load the summary
                isNavigating = false
                loadingStage = 0
            }

            // After showing the article, then load summary in background
            let summaryString = await loadAttributedStringAsync(for: .summary, from: notification)

            await MainActor.run {
                summaryAttributedString = summaryString
            }
        }
    }

    private func loadAttributedStringAsync(for field: RichTextField, from notification: NotificationData) async -> NSAttributedString? {
        // Extract the markdown text OUTSIDE the closure to avoid capturing NotificationData
        let markdownText: String?
        switch field {
        case .title: markdownText = notification.title
        case .body: markdownText = notification.body
        case .summary: markdownText = notification.summary
        case .criticalAnalysis: markdownText = notification.critical_analysis
        case .logicalFallacies: markdownText = notification.logical_fallacies
        case .sourceAnalysis: markdownText = notification.source_analysis
        case .relationToTopic: markdownText = notification.relation_to_topic
        case .additionalInsights: markdownText = notification.additional_insights
        }

        // Also extract the text style outside the closure
        let textStyle = field.textStyle

        // Now use the extracted text in the continuation
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Since we extracted the text outside, we no longer capture notification
                if let text = markdownText {
                    let result = markdownToAttributedString(text, textStyle: textStyle)
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func preloadArticleContent() async {
        guard let notification = currentNotification else { return }

        // First quickly build the basic content dictionary (fast operation)
        let basicContent = buildContentDictionary(from: notification)

        // Preload critical rich text content needed for initial display
        let titleString = getAttributedString(for: .title, from: notification, createIfMissing: true)
        let bodyString = getAttributedString(for: .body, from: notification, createIfMissing: true)
        let summaryString = getAttributedString(for: .summary, from: notification, createIfMissing: true)

        // Update UI on main thread with preloaded content
        await MainActor.run {
            additionalContent = basicContent
            titleAttributedString = titleString
            bodyAttributedString = bodyString
            summaryAttributedString = summaryString
        }
    }

    private func clearCurrentContent() {
        titleAttributedString = nil
        bodyAttributedString = nil
        summaryAttributedString = nil
        criticalAnalysisAttributedString = nil
        logicalFallaciesAttributedString = nil
        sourceAnalysisAttributedString = nil
        additionalContent = nil

        // Reset expanded sections
        var newExpandedSections: [String: Bool] = [:]
        for (key, _) in expandedSections {
            newExpandedSections[key] = (key == "Summary")
        }
        expandedSections = newExpandedSections
    }

    private func handlePagination(direction: NavigationDirection, targetIndex: Int) async {
        if direction == .next && targetIndex >= notifications.count - 5 {
            // If we're near the end of our loaded notifications, load more
            let nextBatchSize = notifications.count + 50
            if nextBatchSize <= allNotifications.count {
                await MainActor.run {
                    notifications = Array(allNotifications.prefix(nextBatchSize))
                }
            }
        } else if direction == .previous && targetIndex <= 5 && notifications.count < allNotifications.count {
            // If we're near the start and there are more notifications to load
            let additionalItems = 50
            let startIndex = max(0, notifications.count - additionalItems)
            let newItems = Array(allNotifications[startIndex ..< min(startIndex + additionalItems, allNotifications.count)])

            await MainActor.run {
                notifications = newItems + notifications
                // Adjust currentIndex to account for the newly prepended items
                currentIndex += newItems.count
            }
        }
    }

    private func preloadMinimalContent() async {
        guard let notification = currentNotification else { return }

        // Build minimal content dictionary first (quick operation)
        let basicContent = buildContentDictionary(from: notification)

        // Get rich text content for immediately visible parts
        let titleString = getAttributedString(for: .title, from: notification, createIfMissing: true)
        let bodyString = getAttributedString(for: .body, from: notification, createIfMissing: true)
        let summaryString = getAttributedString(for: .summary, from: notification, createIfMissing: true)

        // Update UI on main thread with all preloaded content
        await MainActor.run {
            additionalContent = basicContent
            titleAttributedString = titleString
            bodyAttributedString = bodyString
            summaryAttributedString = summaryString // Also set summary since it's open by default
        }
    }

    enum NavigationDirection {
        case next
        case previous
    }

    private func findValidArticle(from startIndex: Int, direction: NavigationDirection) async -> Bool {
        var index = startIndex
        let increment = (direction == .next) ? 1 : -1

        // Check if the starting index is within valid range
        while (direction == .next && index < notifications.count) ||
            (direction == .previous && index >= 0)
        {
            // Check off main thread if possible
            let isValidArticle = !deletedIDs.contains(notifications[index].id)
            if isValidArticle {
                // Update the index on main thread
                await MainActor.run {
                    currentIndex = index
                }
                return true
            }

            // Move to the next index based on direction
            index += increment
        }

        return false
    }

    private func hasMinimalCachedContent(_ notification: NotificationData) -> Bool {
        // Check for cached rich text content
        let titleExists = checkAttributedStringExists(for: .title, in: notification)
        let bodyExists = checkAttributedStringExists(for: .body, in: notification)
        let summaryExists = checkAttributedStringExists(for: .summary, in: notification)

        // Also check if we already have basic content fields filled
        let hasBasicFields = notification.title.count > 0 &&
            notification.body.count > 0 &&
            notification.summary != nil

        return (titleExists && bodyExists && summaryExists) || hasBasicFields
    }

    // Helper function to check if an attributed string exists without loading it
    private func checkAttributedStringExists(for field: RichTextField, in notification: NotificationData) -> Bool {
        let notificationId = notification.id.uuidString.lowercased()

        // Convert RichTextField to a string identifier for the filename
        let fieldIdentifier: String
        switch field {
        case .title:
            fieldIdentifier = "title"
        case .body:
            fieldIdentifier = "body"
        case .summary:
            fieldIdentifier = "summary"
        case .criticalAnalysis:
            fieldIdentifier = "criticalAnalysis"
        case .logicalFallacies:
            fieldIdentifier = "logicalFallacies"
        case .sourceAnalysis:
            fieldIdentifier = "sourceAnalysis"
        case .relationToTopic:
            fieldIdentifier = "relationToTopic"
        case .additionalInsights:
            fieldIdentifier = "additionalInsights"
        }

        let filename = "\(notificationId)-\(fieldIdentifier).dat"

        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        return fileManager.fileExists(atPath: fileURL.path)
    }

    // MARK: - Article Header

    private var articleHeaderStyle: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Topic pill + "Archived" pill
            HStack(spacing: 8) {
                if let notification = currentNotification {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }

                    if notification.isArchived {
                        ArchivedPill()
                    }
                }
                Spacer()
            }

            // Title - using NonSelectableRichTextView for better performance during transitions
            if let notification = currentNotification {
                if let content = additionalContent,
                   let articleURLString = content["url"] as? String,
                   let articleURL = URL(string: articleURLString)
                {
                    Link(destination: articleURL) {
                        if let titleAttrString = titleAttributedString {
                            NonSelectableRichTextView(attributedString: titleAttrString)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(notification.title)
                                .font(.headline)
                                .fontWeight(notification.isViewed ? .regular : .bold)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    if let titleAttrString = titleAttributedString {
                        NonSelectableRichTextView(attributedString: titleAttrString)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(notification.title)
                            .font(.title2)
                            .fontWeight(notification.isViewed ? .regular : .bold)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Publication Date
                if let pubDate = notification.pub_date {
                    Text("Published: \(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let bodyAttrString = bodyAttributedString {
                    NonSelectableRichTextView(attributedString: bodyAttrString)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                } else {
                    Text(notification.body)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Affected (optional)
                if !notification.affected.isEmpty {
                    Text(notification.affected)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Domain
                if let domain = notification.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(domain)
                            .font(.headline)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // No need to check for content here since we're directly using notification
                        LazyLoadingQualityBadges(
                            notification: notification,
                            onBadgeTap: { section in
                                scrollToSection = section
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(currentNotification?.isViewed ?? true ? Color.clear : Color.blue.opacity(0.15))
    }

    // MARK: - Additional Sections

    var additionalSectionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingAdditionalContent {
                ProgressView("Loading additional content...")
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let content = additionalContent {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading) {
                        ForEach(getSections(from: content), id: \.header) { section in
                            VStack(alignment: .leading) {
                                Divider()

                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { expandedSections[section.header] ?? false },
                                        set: {
                                            let wasExpanded = expandedSections[section.header] ?? false
                                            expandedSections[section.header] = $0

                                            // If newly expanded, trigger content loading
                                            if !wasExpanded, $0 {
                                                loadContentForSection(section.header)
                                            }
                                        }
                                    )
                                ) {
                                    // Only render content if section is expanded
                                    if expandedSections[section.header] == true {
                                        if section.header == "Summary" && summaryAttributedString == nil {
                                            // Special case for Summary section which is open by default
                                            ProgressView("Loading summary...")
                                                .padding(.vertical, 10)
                                        } else {
                                            sectionContent(for: section)
                                        }
                                    } else {
                                        Color.clear.frame(height: 1)
                                    }
                                } label: {
                                    HStack {
                                        Text(section.header)
                                            .font(.headline)

                                        // Show loading indicator next to section title if currently loading
                                        if section.header == "Summary" &&
                                            expandedSections[section.header] == true &&
                                            summaryAttributedString == nil
                                        {
                                            Spacer()
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(section.header)
                                .padding([.leading, .trailing, .top])
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .onChange(of: scrollToSection) { _, newSection in
                        if let section = newSection {
                            expandedSections[section] = true
                            loadContentForSection(section)
                            withAnimation {
                                proxy.scrollTo(section, anchor: .top)
                            }
                            scrollToSection = nil
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func toggleReadStatus() {
        guard let notification = currentNotification else { return }
        notification.isViewed.toggle()
        saveModel()
        NotificationUtils.updateAppBadgeCount()
    }

    private func toggleBookmark() {
        guard let notification = currentNotification else { return }
        notification.isBookmarked.toggle()
        saveModel()
        NotificationUtils.updateAppBadgeCount()
    }

    private func toggleArchive() {
        guard let notification = currentNotification else { return }
        let wasArchived = notification.isArchived
        notification.isArchived.toggle()
        saveModel()
        NotificationUtils.updateAppBadgeCount()

        if !wasArchived {
            if currentIndex < notifications.count - 1 {
                currentIndex += 1
                markAsViewed()
            } else {
                dismiss()
            }
        }
    }

    private func deleteNotification() {
        guard let notification = currentNotification else { return }
        modelContext.delete(notification)
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()

            if currentIndex < notifications.count - 1 {
                currentIndex += 1
                markAsViewed()
            } else {
                dismiss()
            }
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }

    // MARK: - Helper Methods

    private func getEngineStatsData(from jsonString: String?) -> ArgusDetailsData? {
        guard let jsonString = jsonString,
              let jsonData = jsonString.data(using: .utf8),
              let statsDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            return nil
        }

        if let model = statsDict["model"] as? String,
           let elapsedTime = statsDict["elapsed_time"] as? Double,
           let stats = statsDict["stats"] as? String
        {
            return ArgusDetailsData(
                model: model,
                elapsedTime: elapsedTime,
                date: currentNotification?.date ?? Date(),
                stats: stats,
                systemInfo: statsDict["system_info"] as? [String: Any]
            )
        }
        return nil
    }

    private func getSimilarArticles(from jsonString: String?) -> [[String: Any]]? {
        guard let jsonString = jsonString,
              let jsonData = jsonString.data(using: .utf8),
              let similarArticles = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        else {
            return nil
        }
        return similarArticles
    }

    private func getArticleUrl(_ notification: NotificationData) -> String? {
        // If we have the URL cached in additionalContent, use that
        if let content = additionalContent, let url = content["url"] as? String {
            return url
        }

        // Otherwise try to construct a URL from the domain
        if let domain = notification.domain {
            return "https://\(domain)"
        }

        return nil
    }

    // Helper to build source analysis content
    private func buildSourceAnalysis(_ notification: NotificationData) -> String {
        var content = ""

        if let sourceType = notification.source_type {
            content += "Source Type: \(sourceType)\n\n"
        }

        if let sourcesQuality = notification.sources_quality {
            let qualityLabel: String
            switch sourcesQuality {
            case 1: qualityLabel = "Poor"
            case 2: qualityLabel = "Fair"
            case 3: qualityLabel = "Good"
            case 4: qualityLabel = "Strong"
            default: qualityLabel = "Unknown"
            }
            content += "Source Quality: \(qualityLabel)\n\n"
        }

        // Add more details if available in the notification
        if let domain = notification.domain {
            content += "Domain: \(domain)\n\n"
        }

        // If we have no content at all, add a placeholder
        if content.isEmpty {
            content = "No source analysis data available."
        }

        return content
    }

    @MainActor
    private func updateLocalDatabaseWithFetchedContent(_ notification: NotificationData, _ content: [String: Any]) {
        // Don't update if we already have all the content
        if notification.sources_quality != nil &&
            notification.argument_quality != nil &&
            notification.source_type != nil &&
            notification.summary != nil &&
            notification.critical_analysis != nil &&
            notification.logical_fallacies != nil &&
            notification.relation_to_topic != nil &&
            notification.additional_insights != nil &&
            notification.source_analysis != nil
        {
            return
        }

        // Use consistent helper
        func convertMarkdown(_ text: String?) -> String? {
            guard let text = text, !text.isEmpty else { return nil }
            // Create an attributed string using our helper and extract the plain string
            if let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody") {
                return attributedString.string
            }
            return text
        }

        // Update fields that weren't stored locally
        if notification.sources_quality == nil {
            notification.sources_quality = content["sources_quality"] as? Int
        }

        if notification.argument_quality == nil {
            notification.argument_quality = content["argument_quality"] as? Int
        }

        if notification.source_type == nil {
            notification.source_type = content["source_type"] as? String
        }

        // Store the full source_analysis field
        if notification.source_analysis == nil {
            let sourceAnalysis = (content["source_analysis"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            notification.source_analysis = convertMarkdown(sourceAnalysis)

            // Also save the rich text version if we have the text
            if let sourceText = sourceAnalysis,
               let attributedString = markdownToAttributedString(sourceText, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .sourceAnalysis, in: notification)
            }
        }

        if notification.quality == nil {
            notification.quality = content["quality"] as? Int
        }

        if notification.summary == nil {
            let summaryText = content["summary"] as? String
            notification.summary = convertMarkdown(summaryText)

            // Also save the rich text version if we have the text
            if let text = summaryText,
               let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .summary, in: notification)
            }
        }

        if notification.critical_analysis == nil {
            let criticalText = content["critical_analysis"] as? String
            notification.critical_analysis = convertMarkdown(criticalText)

            // Also save the rich text version if we have the text
            if let text = criticalText,
               let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .criticalAnalysis, in: notification)
            }
        }

        if notification.logical_fallacies == nil {
            let fallaciesText = content["logical_fallacies"] as? String
            notification.logical_fallacies = convertMarkdown(fallaciesText)

            // Also save the rich text version if we have the text
            if let text = fallaciesText,
               let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .logicalFallacies, in: notification)
            }
        }

        if notification.relation_to_topic == nil {
            let relationText = content["relation_to_topic"] as? String
            notification.relation_to_topic = convertMarkdown(relationText)

            // Also save the rich text version if we have the text
            if let text = relationText,
               let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .relationToTopic, in: notification)
            }
        }

        if notification.additional_insights == nil {
            let insightsText = content["additional_insights"] as? String
            notification.additional_insights = convertMarkdown(insightsText)

            // Also save the rich text version if we have the text
            if let text = insightsText,
               let attributedString = markdownToAttributedString(text, textStyle: "UIFontTextStyleBody")
            {
                _ = saveAttributedString(attributedString, for: .additionalInsights, in: notification)
            }
        }

        // Store engine stats
        if notification.engine_stats == nil {
            var engineStatsDict: [String: Any] = [:]

            if let model = content["model"] as? String {
                engineStatsDict["model"] = model
            }

            if let elapsedTime = content["elapsed_time"] as? Double {
                engineStatsDict["elapsed_time"] = elapsedTime
            }

            if let stats = content["stats"] as? String {
                engineStatsDict["stats"] = stats
            }

            if let systemInfo = content["system_info"] as? [String: Any] {
                engineStatsDict["system_info"] = systemInfo
            }

            if !engineStatsDict.isEmpty {
                if let jsonData = try? JSONSerialization.data(withJSONObject: engineStatsDict),
                   let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    notification.engine_stats = jsonString
                }
            }
        }

        // Store similar articles
        if notification.similar_articles == nil {
            if let similarArticles = content["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty {
                if let jsonData = try? JSONSerialization.data(withJSONObject: similarArticles),
                   let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    notification.similar_articles = jsonString
                }
            }
        }

        // Save the changes
        do {
            try modelContext.save()
        } catch {
            print("Failed to save updated notification data: \(error)")
        }
    }

    private func markAsViewed() {
        guard let notification = currentNotification else { return }
        if !notification.isViewed {
            notification.isViewed = true
            saveModel()
            NotificationUtils.updateAppBadgeCount()
            AppDelegate().removeNotificationIfExists(jsonURL: notification.json_url)
        }
    }

    private func hasRequiredContent(_ notification: NotificationData) -> Bool {
        return notification.summary != nil &&
            notification.critical_analysis != nil &&
            notification.logical_fallacies != nil
    }

    // Helper function to build content dictionary from notification
    private func buildContentDictionary(from notification: NotificationData) -> [String: Any] {
        var content: [String: Any] = [:]

        // Add URL if available
        if let domain = notification.domain {
            content["url"] = "https://\(domain)"
        }

        // Transfer metadata fields directly without processing
        content["sources_quality"] = notification.sources_quality
        content["argument_quality"] = notification.argument_quality
        content["source_type"] = notification.source_type

        // Just check if these fields exist without converting to attributed strings
        content["summary"] = notification.summary
        content["critical_analysis"] = notification.critical_analysis
        content["logical_fallacies"] = notification.logical_fallacies
        content["relation_to_topic"] = notification.relation_to_topic
        content["additional_insights"] = notification.additional_insights

        // For source analysis, just create a basic dictionary without processing the text
        if let sourceAnalysis = notification.source_analysis {
            content["source_analysis"] = [
                "text": sourceAnalysis,
                "sourceType": notification.source_type ?? "",
            ]
        } else {
            content["source_analysis"] = [
                "text": "",
                "sourceType": notification.source_type ?? "",
            ]
        }

        // Transfer engine stats and similar articles as is
        if let engineStatsJson = notification.engine_stats,
           let engineStatsData = engineStatsJson.data(using: .utf8),
           let engineStats = try? JSONSerialization.jsonObject(with: engineStatsData) as? [String: Any]
        {
            // Transfer relevant engine stats fields
            if let model = engineStats["model"] as? String {
                content["model"] = model
            }
            if let elapsedTime = engineStats["elapsed_time"] as? Double {
                content["elapsed_time"] = elapsedTime
            }
            if let stats = engineStats["stats"] as? String {
                content["stats"] = stats
            }
            if let systemInfo = engineStats["system_info"] as? [String: Any] {
                content["system_info"] = systemInfo
            }
        }

        // Transfer similar articles as is
        if let similarArticlesJson = notification.similar_articles,
           let similarArticlesData = similarArticlesJson.data(using: .utf8),
           let similarArticles = try? JSONSerialization.jsonObject(with: similarArticlesData) as? [[String: Any]]
        {
            content["similar_articles"] = similarArticles
        }

        return content
    }

    enum ContentLoadType {
        case minimal // Just title and body (minimum needed for header)
        case header // Only content needed for article header rendering
        case summary // Minimal + summary content (for default expanded section)
        case sectionHeaders // Just section headers without content (for quick display)
        case full // All content including rich text for all sections
        case specific([RichTextField]) // Load only specific fields
    }

    // MARK: - Consolidated Content Loading Function

    /**
     Loads content for the current article with various levels of detail and timing options.

     - Parameters:
       - contentType: Determines which content to load (minimal, header, full, etc.)
       - synchronously: If true, blocks until content is loaded; if false, loads asynchronously
       - completion: Optional callback to execute when content loading completes
     */
    private func loadContent(
        contentType: ContentLoadType = .minimal,
        synchronously: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let notification = currentNotification else { return }

        // Function to execute the loading based on content type
        let performLoading = {
            // Always build the basic content dictionary which powers the section list
            // regardless of the content type - this ensures sections appear even if content is loading
            if self.additionalContent == nil {
                self.additionalContent = self.buildContentDictionary(from: notification)
            }

            // Determine which fields to load based on content type
            var fieldsToLoad: [RichTextField] = []

            switch contentType {
            case .minimal:
                fieldsToLoad = [.title, .body]

            case .header:
                fieldsToLoad = [.title, .body]

            case .summary:
                fieldsToLoad = [.title, .body, .summary]

            case .sectionHeaders:
                // Just return since we already built the content dictionary
                return

            case .full:
                // The specific sections will be loaded when expanded
                fieldsToLoad = [.title, .body]

            case let .specific(fields):
                fieldsToLoad = fields
            }

            // Load the fields
            for field in fieldsToLoad {
                // FIX: Only load if the field hasn't already been loaded
                let attributedString: NSAttributedString?
                switch field {
                case .title where self.titleAttributedString != nil:
                    continue
                case .body where self.bodyAttributedString != nil:
                    continue
                case .summary where self.summaryAttributedString != nil:
                    continue
                case .criticalAnalysis where self.criticalAnalysisAttributedString != nil:
                    continue
                case .logicalFallacies where self.logicalFallaciesAttributedString != nil:
                    continue
                case .sourceAnalysis where self.sourceAnalysisAttributedString != nil:
                    continue
                default:
                    attributedString = getAttributedString(
                        for: field,
                        from: notification,
                        createIfMissing: true
                    )
                }

                // Store the attributed string in the appropriate property
                if let attributedString = attributedString {
                    switch field {
                    case .title:
                        self.titleAttributedString = attributedString
                    case .body:
                        self.bodyAttributedString = attributedString
                    case .summary:
                        self.summaryAttributedString = attributedString
                    case .criticalAnalysis:
                        self.criticalAnalysisAttributedString = attributedString
                    case .logicalFallacies:
                        self.logicalFallaciesAttributedString = attributedString
                    case .sourceAnalysis:
                        self.sourceAnalysisAttributedString = attributedString
                    case .relationToTopic, .additionalInsights:
                        // These don't have dedicated properties but are loaded for on-demand use
                        break
                    }
                }
            }
        }

        // Execute the loading based on synchronicity parameter
        if synchronously {
            performLoading()
            completion?()
        } else {
            // Run asynchronously to prevent UI blocking
            DispatchQueue.global(qos: .userInteractive).async {
                performLoading()

                // Call completion on main thread
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }

    /**
     Loads content for a specific section when it's expanded or scrolled to.
     This is a helper that uses the main loadContent function with specific fields.

     - Parameter section: The name of the section to load content for
     */
    private func loadContentForSection(_ section: String) {
        // Map section name to field type
        let field: RichTextField?
        switch section {
        case "Summary":
            field = .summary
            if summaryAttributedString != nil { return } // Already loaded
        case "Critical Analysis":
            field = .criticalAnalysis
            if criticalAnalysisAttributedString != nil { return } // Already loaded
        case "Logical Fallacies":
            field = .logicalFallacies
            if logicalFallaciesAttributedString != nil { return } // Already loaded
        case "Source Analysis":
            field = .sourceAnalysis
            if sourceAnalysisAttributedString != nil { return } // Already loaded
        case "Relevance":
            field = .relationToTopic
        case "Context & Perspective":
            field = .additionalInsights
        default:
            field = nil // Unknown section
        }

        // Only proceed if we have a field to load and notification is available
        guard let fieldToLoad = field, let notification = currentNotification else { return }

        // Create a copy of the ID to avoid capturing the whole notification
        let notificationId = notification.id

        Task {
            // Fetch notification on the task to avoid capturing it
            let attributedString = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Re-fetch notification using ID to avoid Sendable issues
                    if let currentNotification = self.currentNotification, currentNotification.id == notificationId {
                        let result = getAttributedString(
                            for: fieldToLoad,
                            from: currentNotification,
                            createIfMissing: true
                        )
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }

            if !Task.isCancelled, let attributedString = attributedString {
                await MainActor.run {
                    // Store the attributed string in the appropriate property
                    switch fieldToLoad {
                    case .summary:
                        summaryAttributedString = attributedString
                    case .criticalAnalysis:
                        criticalAnalysisAttributedString = attributedString
                    case .logicalFallacies:
                        logicalFallaciesAttributedString = attributedString
                    case .sourceAnalysis:
                        sourceAnalysisAttributedString = attributedString
                    default:
                        break
                    }
                }
            }
        }
    }

    private func loadArticleContent(url: String) {
        guard let url = URL(string: url) else { return }
        articleContent = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let htmlString = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.articleContent = htmlString
                    }
                }
            } catch {
                print("Failed to load article content: \(error)")
                DispatchQueue.main.async {
                    self.articleContent = "Failed to load article content. Please try again."
                }
            }
        }
    }

    private func saveModel() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save context: \(error)")
        }
    }

    struct ContentSection {
        let header: String
        let content: Any
        var similarArticlesLoaded: Bool = false // New property to track loading state

        var argusDetails: ArgusDetailsData? {
            if case let (model, elapsedTime, date, stats, systemInfo) as (String, Double, Date, String, [String: Any]?) = content {
                return ArgusDetailsData(
                    model: model,
                    elapsedTime: elapsedTime,
                    date: date,
                    stats: stats,
                    systemInfo: systemInfo
                )
            }
            return nil
        }
    }

    @ViewBuilder
    private func sectionContent(for section: ContentSection) -> some View {
        switch section.header {
        case "Summary":
            if let attributedString = summaryAttributedString {
                // Use the preloaded summary attributed string (no need for notification here)
                NonSelectableRichTextView(attributedString: attributedString)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .textSelection(.enabled)
            } else {
                // Fallback - use the plain text summary if available
                Text(section.content as? String ?? "")
                    .font(.callout)
                    .padding(.top, 6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case "Source Analysis":
            VStack(alignment: .leading, spacing: 10) {
                // Domain info at the top
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Article Domain:")
                            .font(.subheadline)
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
                    }
                    Spacer()
                }

                if let sourceData = section.content as? [String: Any] {
                    let sourceText = sourceData["text"] as? String ?? ""
                    let sourceType = sourceData["sourceType"] as? String ?? ""

                    if !sourceText.isEmpty, let notification = currentNotification {
                        LazyLoadingContentView(
                            notification: notification,
                            field: .sourceAnalysis,
                            placeholder: "source analysis",
                            fontSize: 16,
                            onLoad: { self.sourceAnalysisAttributedString = $0 }
                        ) { attributedString in
                            NonSelectableRichTextView(attributedString: attributedString)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    } else {
                        Text("No detailed source analysis available.")
                            .font(.callout)
                            .italic()
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Source type display
                    if !sourceType.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: sourceTypeIcon(for: sourceType))
                                .font(.footnote)
                                .foregroundColor(.blue)
                            Text(sourceType.capitalized)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .textSelection(.enabled)

        case "Critical Analysis", "Logical Fallacies", "Relevance", "Context & Perspective":
            if let notification = currentNotification {
                LazyLoadingContentView(
                    notification: notification,
                    field: getRichTextFieldForSection(section.header),
                    placeholder: section.header.lowercased(),
                    fontSize: 16,
                    onLoad: { self.cacheAttributedString($0, for: section.header) }
                ) { attributedString in
                    NonSelectableRichTextView(attributedString: attributedString)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .textSelection(.enabled)
                }
            } else {
                Text(section.content as? String ?? "")
                    .font(.callout)
                    .padding(.top, 6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case "Vector WIP":
            // Vector WIP section
            VStack(alignment: .leading, spacing: 8) {
                if let similarArticles = section.content as? [[String: Any]], !similarArticles.isEmpty {
                    // Existing similar articles handling
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Similar Articles")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.bottom, 2)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(similarArticles.enumerated()), id: \.offset) { index, article in
                                    SimilarArticleRow(
                                        articleDict: article,
                                        notifications: $notifications,
                                        currentIndex: $currentIndex,
                                        isLastItem: index == similarArticles.count - 1
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 400)
                    }
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                            .padding()
                        Text("Loading similar articles...")
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                Text("This work-in-progress will impact the entire Argus experience when it's reliably working.")
                    .font(.footnote)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 6)

        case "Argus Engine Stats":
            if let details = section.argusDetails {
                ArgusDetailsView(data: details)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case "Preview":
            VStack(spacing: 8) {
                if let urlString = section.content as? String, let articleURL = URL(string: urlString) {
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

    // Helper function to cache attributed strings by section
    private func cacheAttributedString(_ attributedString: NSAttributedString, for section: String) {
        switch section {
        case "Summary":
            summaryAttributedString = attributedString
        case "Critical Analysis":
            criticalAnalysisAttributedString = attributedString
        case "Logical Fallacies":
            logicalFallaciesAttributedString = attributedString
        case "Source Analysis":
            sourceAnalysisAttributedString = attributedString
        default:
            break // Other sections don't have cached properties
        }
    }

    struct LazyLoadingContentView<Content: View>: View {
        let notification: NotificationData
        let field: RichTextField
        let placeholder: String
        var fontSize: CGFloat = 16
        var onLoad: ((NSAttributedString) -> Void)? = nil
        @ViewBuilder var content: (NSAttributedString) -> Content

        @State private var loadedAttributedString: NSAttributedString?
        @State private var isLoading = true
        @State private var loadTask: Task<Void, Never>? = nil

        var body: some View {
            Group {
                if let attributedString = loadedAttributedString {
                    // Show the content using the provided view builder
                    content(attributedString)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isLoading {
                    // Loading placeholder
                    VStack {
                        ProgressView()
                        Text("Loading \(placeholder)...")
                            .font(.callout)
                            .italic()
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                    .onAppear {
                        loadContent()
                    }
                    .onDisappear {
                        loadTask?.cancel()
                    }
                } else {
                    // Fallback if loading fails
                    Text("Unable to format \(placeholder)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func loadContent() {
            // Cancel any previous task
            loadTask?.cancel()

            // Only load if we don't already have the content
            if loadedAttributedString != nil {
                isLoading = false
                return
            }

            loadTask = Task {
                // Load the attributed string in the background
                let attributedString = await withCheckedContinuation { continuation in
                    // Using DispatchQueue for NSAttributedString which isn't Sendable
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = getAttributedString(
                            for: field,
                            from: notification,
                            createIfMissing: true,
                            customFontSize: fontSize
                        )
                        continuation.resume(returning: result)
                    }
                }

                // Update UI on main thread
                await MainActor.run {
                    // Check if the task was cancelled
                    if Task.isCancelled { return }

                    self.loadedAttributedString = attributedString
                    self.isLoading = false
                    if let attributedString = attributedString {
                        onLoad?(attributedString)
                    }
                }
            }
        }
    }

    private func getRichTextFieldForSection(_ header: String) -> RichTextField {
        switch header {
        case "Summary": return .summary
        case "Critical Analysis": return .criticalAnalysis
        case "Logical Fallacies": return .logicalFallacies
        case "Source Analysis": return .sourceAnalysis
        case "Relevance": return .relationToTopic
        case "Context & Perspective": return .additionalInsights
        default: return .body // Default fallback
        }
    }

    private func loadVectorWIPArticles() {
        // Only load if we haven't already loaded the content
        if expandedSections["Vector WIP"] == true {
            return // Already loaded
        }

        guard let content = additionalContent,
              let _ = content["similar_articles"] as? [[String: Any]]
        else {
            return
        }

        // Process the similar articles in a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            // Here we'd do any expensive processing like markdown conversion, date parsing, etc.

            // Update the UI on the main thread
            DispatchQueue.main.async {
                // Mark the Vector WIP section as loaded
                self.expandedSections["Vector WIP"] = true
            }
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

    private func qualityLabel(for quality: Int) -> String {
        switch quality {
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Strong"
        default: return "Unknown"
        }
    }

    private func updateArticleHeaderStyle() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Existing topic pill + "Archived" pill code
            HStack(spacing: 8) {
                if let notification = currentNotification {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }

                    if notification.isArchived {
                        ArchivedPill()
                    }
                }
            }

            // Title using attributed string
            if let notification = currentNotification {
                if let content = additionalContent,
                   let articleURLString = content["url"] as? String,
                   let articleURL = URL(string: articleURLString)
                {
                    Link(destination: articleURL) {
                        if let titleString = titleAttributedString {
                            Text(AttributedString(titleString))
                                .fontWeight(notification.isViewed ? .regular : .bold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                .foregroundColor(.blue)
                        } else {
                            Text(notification.title)
                                .font(.headline)
                                .fontWeight(notification.isViewed ? .regular : .bold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                .foregroundColor(.blue)
                        }
                    }
                } else {
                    if let titleString = titleAttributedString {
                        Text(AttributedString(titleString))
                            .fontWeight(notification.isViewed ? .regular : .bold)
                            .foregroundColor(.primary)
                    } else {
                        Text(notification.title)
                            .font(.headline)
                            .fontWeight(notification.isViewed ? .regular : .bold)
                            .foregroundColor(.primary)
                    }
                }
            }

            // Publication Date
            if let notification = currentNotification,
               let pubDate = notification.pub_date
            {
                Text("Published: \(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Quality indicator
            if let notification = currentNotification,
               let quality = notification.quality ?? notification.argument_quality,
               quality > 0
            {
                HStack(spacing: 2) {
                    ForEach(0 ..< min(quality, 4), id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                    ForEach(0 ..< (4 - min(quality, 4)), id: \.self) { _ in
                        Image(systemName: "star")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }

                    Text("Article Quality: \(qualityLabel(for: quality))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }

            // Body using attributed string
            if let notification = currentNotification {
                if let bodyString = bodyAttributedString {
                    Text(AttributedString(bodyString))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(notification.body)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // Affected (optional)
                if !notification.affected.isEmpty {
                    Text(notification.affected)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // Domain
                if let domain = notification.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(domain)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(1)

                        if let content = additionalContent {
                            QualityBadges(
                                sourcesQuality: content["sources_quality"] as? Int,
                                argumentQuality: content["argument_quality"] as? Int,
                                sourceType: content["source_type"] as? String,
                                scrollToSection: $scrollToSection
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(currentNotification?.isViewed ?? true ? Color.clear : Color.blue.opacity(0.15))
    }

    private func processSourceAnalysisContent(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return content }

        var pubDateIndex = -1
        for (index, line) in lines.enumerated() {
            let lowercaseLine = line.lowercased()
            if lowercaseLine.starts(with: "publication date") || lowercaseLine.starts(with: "published") {
                pubDateIndex = index
                break
            }
        }

        if pubDateIndex > 0 && pubDateIndex <= 5 {
            return lines[pubDateIndex...].joined(separator: "\n")
        }

        let firstLine = lines[0].lowercased()
        if firstLine.contains("domain") && firstLine.contains("name") {
            return lines.dropFirst(3).joined(separator: "\n")
        }

        return content
    }
}

// MARK: - Supporting Structures

struct SimilarArticleRow: View {
    let articleDict: [String: Any]
    @Binding var notifications: [NotificationData]
    @Binding var currentIndex: Int
    var isLastItem: Bool = false // Add this parameter

    @Environment(\.modelContext) private var modelContext
    @State private var showError = false
    @State private var showDetailView = false
    @State private var selectedNotification: NotificationData?

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
            selectedNotification = nil
        }) {
            if let notification = selectedNotification {
                NewsDetailView(
                    notifications: [notification],
                    allNotifications: [notification],
                    currentIndex: 0
                )
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
            do {
                // Perform the fetch on the main actor since ModelContext is main actor-isolated
                let results = try await MainActor.run {
                    try modelContext.fetch(FetchDescriptor<NotificationData>(
                        predicate: #Predicate { $0.json_url == urlToFetch }
                    ))
                }

                // Update UI on main thread
                await MainActor.run {
                    if let foundArticle = results.first {
                        selectedNotification = foundArticle
                        showDetailView = true
                    } else {
                        showError = true
                    }
                }
            } catch {
                print("Failed to fetch similar article: \(error)")
                await MainActor.run {
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

struct ArgusDetailsData {
    let model: String
    let elapsedTime: Double
    let date: Date
    let stats: String
    let systemInfo: [String: Any]?
}

struct ContentSection {
    let header: String
    let content: Any
    var similarArticlesLoaded: Bool = false // New property to track loading state

    var argusDetails: ArgusDetailsData? {
        if case let (model, elapsedTime, date, stats, systemInfo) as (String, Double, Date, String, [String: Any]?) = content {
            return ArgusDetailsData(
                model: model,
                elapsedTime: elapsedTime,
                date: date,
                stats: stats,
                systemInfo: systemInfo
            )
        }
        return nil
    }
}

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

struct ShareSelectionView: View {
    let content: [String: Any]?
    let notification: NotificationData
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

        for section in getSections(from: content ?? [:]) {
            if selectedSections.contains(section.header) {
                var sectionContent: String? = nil

                switch section.header {
                case "Title":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .title,
                        from: notification
                    )?.string ?? notification.title

                case "Brief Summary":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .body,
                        from: notification
                    )?.string ?? notification.body

                case "Article URL":
                    sectionContent = content?["url"] as? String

                case "Summary":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .summary,
                        from: notification
                    )?.string ?? notification.summary

                case "Critical Analysis":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .criticalAnalysis,
                        from: notification
                    )?.string ?? notification.critical_analysis

                case "Logical Fallacies":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .logicalFallacies,
                        from: notification
                    )?.string ?? notification.logical_fallacies

                case "Source Analysis":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .sourceAnalysis,
                        from: notification
                    )?.string ?? notification.source_analysis

                case "Relevance":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .relationToTopic,
                        from: notification
                    )?.string ?? notification.relation_to_topic

                case "Context & Perspective":
                    // Use our new helper for consistent handling
                    sectionContent = getAttributedString(
                        for: .additionalInsights,
                        from: notification
                    )?.string ?? notification.additional_insights

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
                    }

                default:
                    // For any other sections, use the content as is
                    sectionContent = section.content as? String
                }

                if let contentToShare = sectionContent, !contentToShare.isEmpty {
                    if section.header == "Title" || section.header == "Brief Summary" || section.header == "Article URL" {
                        // Share these fields as raw content, without headers
                        shareText += "\(contentToShare)\n\n"
                    } else {
                        // Keep headers for everything else
                        shareText += "**\(section.header):**\n\(contentToShare)\n\n"
                    }
                }
            }
        }

        // If no sections were selected, avoid sharing empty content
        if shareText.isEmpty {
            shareText = "No content selected for sharing."
        }

        // Apply markdown formatting if enabled
        if formatText {
            // Use the new consistent helper to convert markdown to attributed string
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
            ContentSection(header: "Title", content: json["tiny_title"] as? String ?? ""),
            ContentSection(header: "Brief Summary", content: json["tiny_summary"] as? String ?? ""),
            ContentSection(header: "Article URL", content: json["url"] as? String ?? ""),
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
        ]

        if let insights = json["additional_insights"] as? String, !insights.isEmpty {
            sections.append(ContentSection(header: "Context & Perspective", content: insights))
        }

        sections.append(ContentSection(
            header: "Argus Engine Stats",
            content: (
                json["model"] as? String ?? "Unknown",
                (json["elapsed_time"] as? Double) ?? 0.0,
                notification.date,
                json["stats"] as? String ?? "N/A",
                json["system_info"] as? [String: Any]
            )
        ))

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
