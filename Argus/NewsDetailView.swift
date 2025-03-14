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
    @State private var preloadedNotification: NotificationData?
    @State private var isLoadingNextArticle = false
    @State private var contentTransitionID = UUID() // To force proper layout recalculation

    private var isCurrentIndexValid: Bool {
        currentIndex >= 0 && currentIndex < notifications.count
    }

    private var currentNotification: NotificationData? {
        if let preloaded = preloadedNotification {
            return preloaded
        }
        guard isCurrentIndexValid else { return nil }
        return notifications[currentIndex]
    }

    @State private var scrollToSection: String? = nil
    let initiallyExpandedSection: String?
    @State private var showDeleteConfirmation = false
    @State private var additionalContent: [String: Any]? = nil
    @State private var isLoadingAdditionalContent = false
    @State private var expandedSections: [String: Bool] = getDefaultExpandedSections()
    @State private var isSharePresented = false
    @State private var selectedSections: Set<String> = []
    @State private var articleContent: String? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Define a private static helper to provide default section states
    private static func getDefaultExpandedSections() -> [String: Bool] {
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

    init(
        notification: NotificationData? = nil,
        preloadedTitle: NSAttributedString? = nil,
        preloadedBody: NSAttributedString? = nil,
        notifications: [NotificationData],
        allNotifications: [NotificationData],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil
    ) {
        _notifications = State(initialValue: notifications)
        _allNotifications = State(initialValue: allNotifications)
        _currentIndex = State(initialValue: currentIndex)
        // If we have a direct notification, initialize our state with it
        _preloadedNotification = State(initialValue: notification)
        _titleAttributedString = State(initialValue: preloadedTitle)
        _bodyAttributedString = State(initialValue: preloadedBody)
        self.initiallyExpandedSection = initiallyExpandedSection
    }

    var body: some View {
        NavigationStack {
            Group {
                if let _ = currentNotification {
                    VStack(spacing: 0) {
                        topBar
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
                        bottomToolbar
                    }
                } else {
                    Text("Article no longer available")
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                dismiss()
                            }
                        }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                setupDeletionHandling()
                markAsViewed()
                loadInitialMinimalContent()
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

    /// Returns all sections (Article, Summary, etc.) for the “accordion” in NewsDetailView.
    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections: [ContentSection] = []

        // Bail out if we have no “currentNotification” (or no data):
        guard let n = currentNotification else {
            return sections
        }

        // 1) “Summary” section
        let summaryContent = n.summary ?? (json["summary"] as? String ?? "")
        sections.append(ContentSection(header: "Summary", content: summaryContent))

        // 2) “Relevance” section
        let relevanceContent = n.relation_to_topic ?? (json["relation_to_topic"] as? String ?? "")
        sections.append(ContentSection(header: "Relevance", content: relevanceContent))

        // 3) “Critical Analysis” section
        let criticalContent = n.critical_analysis ?? (json["critical_analysis"] as? String ?? "")
        sections.append(ContentSection(header: "Critical Analysis", content: criticalContent))

        // 4) “Logical Fallacies” section
        let fallaciesContent = n.logical_fallacies ?? (json["logical_fallacies"] as? String ?? "")
        sections.append(ContentSection(header: "Logical Fallacies", content: fallaciesContent))

        // 5) “Source Analysis” section
        let sourceAnalysisText = n.source_analysis ?? (json["source_analysis"] as? String ?? "")
        let sourceType = n.source_type ?? (json["source_type"] as? String ?? "")
        let sourceAnalysisData: [String: Any] = [
            "text": sourceAnalysisText,
            "sourceType": sourceType,
        ]
        sections.append(ContentSection(header: "Source Analysis", content: sourceAnalysisData))

        // 6) “Context & Perspective” (aka “additional_insights”)
        let insights = n.additional_insights ?? (json["additional_insights"] as? String ?? "")
        if !insights.isEmpty {
            sections.append(ContentSection(header: "Context & Perspective", content: insights))
        }

        // 7) “Argus Engine Stats” (argus_details)
        if let engineString = n.engine_stats {
            // parseEngineStatsJSON returns an ArgusDetailsData if valid
            if let parsed = parseEngineStatsJSON(engineString, fallbackDate: n.date) {
                sections.append(ContentSection(header: "Argus Engine Stats", content: parsed))
            } else {}
        } else if
            let model = json["model"] as? String,
            let elapsed = json["elapsed_time"] as? Double,
            let stats = json["stats"] as? String
        {
            // Create ArgusDetailsData for fallback
            let dataObject = ArgusDetailsData(
                model: model,
                elapsedTime: elapsed,
                date: n.date,
                stats: stats,
                systemInfo: json["system_info"] as? [String: Any]
            )
            sections.append(ContentSection(header: "Argus Engine Stats", content: dataObject))
        }

        // 8) “Preview” section
        if let fullURL = n.getArticleUrl(additionalContent: additionalContent), !fullURL.isEmpty {
            sections.append(ContentSection(header: "Preview", content: fullURL))
        }

        // 9) “Related Articles” (similar_articles)
        if let localSimilar = n.similar_articles {
            if let parsedArray = parseSimilarArticlesJSON(localSimilar) {
                sections.append(ContentSection(header: "Related Articles", content: parsedArray))
            }
        } else if let fallbackArr = json["similar_articles"] as? [[String: Any]], !fallbackArr.isEmpty {
            sections.append(ContentSection(header: "Related Articles", content: fallbackArr))
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
        // Set loading flag
        isLoadingNextArticle = true

        // Cancel any pending load from a previous rapid-tap
        tabChangeTask?.cancel()

        // Get the next valid index
        guard let nextIndex = getNextValidIndex(direction: direction),
              nextIndex >= 0 && nextIndex < notifications.count
        else {
            isLoadingNextArticle = false
            return
        }

        let nextNotification = notifications[nextIndex]

        // Pre-calculate all content before making any view updates
        let preloadedTitle = getAttributedString(for: .title, from: nextNotification)
        let preloadedBody = getAttributedString(for: .body, from: nextNotification)

        // Two-phase update: change content then layout
        tabChangeTask = Task {
            // First phase: change the content reference, but keep the old size
            await MainActor.run {
                // Update content references while still loading
                clearSectionContent()
                titleAttributedString = preloadedTitle
                bodyAttributedString = preloadedBody
                preloadedNotification = nextNotification
            }

            // Brief pause for the first update to complete
            try? await Task.sleep(for: .milliseconds(50))

            // Second phase: trigger a full layout recalculation
            await MainActor.run {
                // Force layout recalculation with new ID
                contentTransitionID = UUID()
                currentIndex = nextIndex
                preloadedNotification = nil
                scrollToTopTrigger = UUID()
                markAsViewed()

                // Reset expanded sections to defaults
                expandedSections = Self.getDefaultExpandedSections()

                // Complete transition
                isLoadingNextArticle = false
            }
        }
    }

    private func preloadContentForSection(_ sectionName: String, from notification: NotificationData) {
        let field = getRichTextFieldForSection(sectionName)
        let attributedString = getAttributedString(for: field, from: notification, createIfMissing: true)

        // Store the attributed string in the appropriate property
        switch field {
        case .summary:
            summaryAttributedString = attributedString
        case .criticalAnalysis:
            criticalAnalysisAttributedString = attributedString
        case .logicalFallacies:
            logicalFallaciesAttributedString = attributedString
        case .sourceAnalysis:
            sourceAnalysisAttributedString = attributedString
        case .relationToTopic, .additionalInsights:
            // These don't have dedicated properties but we can store in cachedContentBySection
            if let attributedString = attributedString {
                cachedContentBySection[sectionName] = attributedString
            }
        case .title, .body:
            // Already handled separately
            break
        }
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

    private func getNextValidIndex(direction: NavigationDirection) -> Int? {
        var newIndex = direction == .next ? currentIndex + 1 : currentIndex - 1
        while newIndex >= 0 && newIndex < notifications.count {
            let candidate = notifications[newIndex]
            if !deletedIDs.contains(candidate.id) {
                return newIndex
            }
            newIndex += (direction == .next ? 1 : -1)
        }
        return nil
    }

    private func moveToNextValidArticle(direction: NavigationDirection) async -> Bool {
        var newIndex = direction == .next ? currentIndex + 1 : currentIndex - 1
        while newIndex >= 0 && newIndex < notifications.count {
            let candidate = notifications[newIndex]
            if !deletedIDs.contains(candidate.id) {
                await MainActor.run {
                    currentIndex = newIndex
                }
                return true
            }
            newIndex += (direction == .next ? 1 : -1)
        }
        return false
    }

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

    enum NavigationDirection {
        case next
        case previous
    }

    // MARK: - Article Header

    private var articleHeaderStyle: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Topic pill + "Archived" pill
            HStack(spacing: 8) {
                if let n = currentNotification {
                    if let topic = n.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                    if n.isArchived {
                        ArchivedPill()
                    }
                }
                Spacer()
            }

            if let n = currentNotification {
                // Title
                if let titleAttrString = titleAttributedString {
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

                // Publication Date
                if let pubDate = n.pub_date {
                    Text("Published: \(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Body
                if let bodyAttrString = bodyAttributedString {
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

                // Affected
                if !n.affected.isEmpty {
                    Text(n.affected)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                // Domain + Lazy Quality Badges
                if let domain = n.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(domain)
                            .font(.headline)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                        LazyLoadingQualityBadges(
                            notification: n,
                            onBadgeTap: { section in
                                scrollToSection = section
                            }
                        )
                    }
                }
            }
        }
        .id(contentTransitionID) // Force layout recalculation when this changes
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(currentNotification?.isViewed ?? true ? Color.clear : Color.blue.opacity(0.15))
        .opacity(isLoadingNextArticle ? 0.5 : 1.0) // Fade during transitions
        .animation(.easeInOut(duration: 0.2), value: isLoadingNextArticle)
    }

    // MARK: - Additional Sections

    var additionalSectionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // We build the content dictionary once, or on demand:
            if let n = currentNotification {
                let contentDict = buildContentDictionary(from: n)
                let sections = getSections(from: contentDict)

                ForEach(sections, id: \.header) { section in
                    Divider()
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedSections[section.header] ?? false },
                            set: { newValue in
                                let wasExpanded = expandedSections[section.header] ?? false
                                expandedSections[section.header] = newValue
                                if newValue, !wasExpanded {
                                    // Only load that section’s content if we have not yet
                                    loadContentForSection(section.header)
                                }
                            }
                        )
                    ) {
                        if expandedSections[section.header] == true {
                            sectionContent(for: section)
                        }
                    } label: {
                        Text(section.header)
                            .font(.headline)
                    }
                    .id(section.header)
                }
            }
        }
        .padding(.horizontal, 8)
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

    private func getSimilarArticles(from jsonString: String?) -> [[String: Any]]? {
        guard let jsonString = jsonString,
              let jsonData = jsonString.data(using: .utf8),
              let similarArticles = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        else {
            return nil
        }
        return similarArticles
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

    // Loads content for a specific section when it's expanded or scrolled to.
    // This is a helper that uses the main loadContent function with specific fields.
    // - Parameter section: The name of the section to load content for
    private func loadContentForSection(_ section: String) {
        guard let n = currentNotification else { return }

        let field: RichTextField?
        switch section {
        case "Summary": field = .summary
        case "Critical Analysis": field = .criticalAnalysis
        case "Logical Fallacies": field = .logicalFallacies
        case "Source Analysis": field = .sourceAnalysis
        case "Relevance": field = .relationToTopic
        case "Context & Perspective": field = .additionalInsights
        default:
            field = nil
        }
        guard let f = field else { return }

        // Just call getAttributedString directly, synchronously:
        let loadedAttrString = getAttributedString(for: f, from: n, createIfMissing: true)

        // Assign it to whichever State property you’re using
        switch f {
        case .summary:
            summaryAttributedString = loadedAttrString
        case .criticalAnalysis:
            criticalAnalysisAttributedString = loadedAttrString
        case .logicalFallacies:
            logicalFallaciesAttributedString = loadedAttrString
        case .sourceAnalysis:
            sourceAnalysisAttributedString = loadedAttrString
        default:
            break
        }
    }

    private func saveModel() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save context: \(error)")
        }
    }

    /// Parses the `engine_stats` JSON string into a strongly-typed ArgusDetailsData
    private func parseEngineStatsJSON(_ jsonString: String, fallbackDate: Date) -> ArgusDetailsData? {
        // Try to parse as JSON first
        if let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = dict["model"] as? String,
           let elapsedTime = dict["elapsed_time"] as? Double,
           let stats = dict["stats"] as? String
        {
            return ArgusDetailsData(
                model: model,
                elapsedTime: elapsedTime,
                date: fallbackDate,
                stats: stats,
                systemInfo: dict["system_info"] as? [String: Any]
            )
        }

        // If that fails, just create a hardcoded object with the raw text
        print("DEBUG: Creating fallback ArgusDetailsData with raw content")
        return ArgusDetailsData(
            model: "Argus Engine",
            elapsedTime: 0.0,
            date: fallbackDate,
            stats: "0:0:0:0:0:0",
            systemInfo: ["raw_content": jsonString as Any]
        )
    }

    /// Parses the `similar_articles` JSON string into an array of dictionaries
    private func parseSimilarArticlesJSON(_ jsonString: String) -> [[String: Any]]? {
        // Try to parse as JSON array first
        if let data = jsonString.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !arr.isEmpty
        {
            return arr
        }

        // Create a synthetic article that contains the raw text
        let fallbackArticle: [String: Any] = [
            "title": "Raw Content",
            "tiny_summary": "Content could not be parsed as JSON",
            "published_date": Date().ISO8601Format(),
            "raw_content": jsonString,
        ]

        return [fallbackArticle]
    }

    @ViewBuilder
    private func sectionContent(for section: ContentSection) -> some View {
        switch section.header {
        // MARK: - Summary

        case "Summary":
            if let attributedString = summaryAttributedString {
                NonSelectableRichTextView(attributedString: attributedString)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .textSelection(.enabled)
            } else {
                // Fallback: plain text if we haven’t loaded the rich text yet
                Text(section.content as? String ?? "")
                    .font(.callout)
                    .padding(.top, 6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        // MARK: - Source Analysis

        case "Source Analysis":
            VStack(alignment: .leading, spacing: 10) {
                // (Optional) Domain info at the top
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

                // The actual “source analysis” text and type
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

                    // Also show sourceType as a little “badge” or label
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

        // MARK: - Multi-case fields (Critical, Fallacies, Relevance, etc.)

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
                // Fallback for missing notification
                Text(section.content as? String ?? "")
                    .font(.callout)
                    .padding(.top, 6)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        // MARK: - Related Articles (similar_articles)

        case "Related Articles": // Changed from "Vector WIP"
            VStack(alignment: .leading, spacing: 8) {
                if let similarArticles = section.content as? [[String: Any]], !similarArticles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
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

        // MARK: - Argus Engine Stats (argus_details)

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

        // MARK: - Preview (Optional)

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

        // MARK: - Default fallback for anything else

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

    private func loadInitialMinimalContent() {
        // Load just the basics for the current notification (if it’s valid)
        guard let n = currentNotification else { return }
        Task {
            // Only load title/body if they weren't preloaded
            if titleAttributedString == nil {
                let newTitle = getAttributedString(for: .title, from: n)
                await MainActor.run {
                    titleAttributedString = newTitle
                }
            }

            if bodyAttributedString == nil {
                let newBody = getAttributedString(for: .body, from: n)
                await MainActor.run {
                    bodyAttributedString = newBody
                }
            }

            // If “Summary” is open by default, do that in background:
            if expandedSections["Summary"] == true {
                let newSummary = getAttributedString(for: .summary, from: n, createIfMissing: true)

                // Update the UI on the main actor:
                await MainActor.run {
                    summaryAttributedString = newSummary
                }
            }
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

    private func loadRelatedArticles() {
        // Only load if we haven't already loaded the content
        if expandedSections["Related Articles"] == true {
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
                // Mark the Related Articles section as loaded
                self.expandedSections["Related Articles"] = true
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

private struct ContentSection {
    let header: String
    let content: Any

    /// If `content` is actually an `ArgusDetailsData`, return it; else nil.
    var argusDetails: ArgusDetailsData? {
        content as? ArgusDetailsData
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
                    sectionContent = notification.critical_analysis

                case "Logical Fallacies":
                    sectionContent = notification.logical_fallacies

                case "Source Analysis":
                    sectionContent = notification.source_analysis

                case "Relevance":
                    sectionContent = notification.relation_to_topic

                case "Context & Perspective":
                    sectionContent = notification.additional_insights

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
            ContentSection(header: "Title", content: json["tiny_title"] as? String ?? ""),
            ContentSection(header: "Brief Summary", content: json["tiny_summary"] as? String ?? ""),
            ContentSection(header: "Article URL", content: json["url"] as? String ?? ""),
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
        ]

        let insights = json["additional_insights"] as? String ?? notification.additional_insights ?? ""
        sections.append(ContentSection(header: "Context & Perspective", content: insights))

        if let model = json["model"] as? String,
           let elapsedTime = json["elapsed_time"] as? Double,
           let stats = json["stats"] as? String
        {
            sections.append(ContentSection(
                header: "Argus Engine Stats",
                content: ArgusDetailsData(
                    model: model,
                    elapsedTime: elapsedTime,
                    date: notification.date,
                    stats: stats,
                    systemInfo: json["system_info"] as? [String: Any]
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

extension NotificationData {
    // Get the best available URL for this article
    func getArticleUrl(additionalContent: [String: Any]? = nil) -> String? {
        // First check for the direct article_url field we added
        if let directURL = article_url, !directURL.isEmpty {
            return directURL
        }

        // If we have the URL cached in additionalContent, use that
        if let content = additionalContent, let url = content["url"] as? String {
            return url
        }

        // Otherwise try to construct a URL from the domain
        if let domain = domain {
            return "https://\(domain)"
        }

        return nil
    }
}
