import SwiftData
import SwiftUI
import UIKit

extension Date {
    var dayOnly: Date {
        Calendar.current.startOfDay(for: self)
    }
}

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode

    @Query private var allNotifications: [NotificationData]

    @State private var filteredNotifications: [NotificationData] = []
    @State private var selectedNotificationIDs: Set<NotificationData.ID> = []
    @State private var sortedAndGroupedNotifications: [(key: String, notifications: [NotificationData])] = []
    @State private var isFilterViewPresented: Bool = false
    @State private var subscriptions: [String: Subscription] = [:]
    @State private var needsTopicReset: Bool = false
    @State private var filterViewHeight: CGFloat = 200
    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastSelectedTopic: String = "All"
    @State private var needsScrollReset: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var articleToDelete: NotificationData?
    @State private var totalNotifications: [NotificationData] = []
    @State private var batchSize: Int = 30
    @State private var lastUpdateTime: Date = .distantPast
    @State private var isUpdating: Bool = false
    @State private var backgroundRefreshTask: Task<Void, Never>?
    @State private var lastLoadedDate: Date? = nil
    @State private var isLoadingMorePages: Bool = false
    @State private var pageSize: Int = 30
    @State private var hasMoreContent: Bool = true
    @State private var isActivelyScrolling: Bool = false
    @State private var pendingUpdateNeeded: Bool = false
    @State private var scrollIdleTimer: Task<Void, Never>? = nil

    @AppStorage("sortOrder") private var sortOrder: String = "newest"
    @AppStorage("groupingStyle") private var groupingStyle: String = "none"
    @AppStorage("showUnreadOnly") private var showUnreadOnly: Bool = false
    @AppStorage("showBookmarkedOnly") private var showBookmarkedOnly: Bool = false
    @AppStorage("showArchivedContent") private var showArchivedContent: Bool = false
    @AppStorage("selectedTopic") private var selectedTopic: String = "All"

    @Binding var tabBarHeight: CGFloat

    var deleteConfirmationMessage: String {
        if articleToDelete != nil {
            return "This article is bookmarked. Are you sure you want to delete it?"
        } else {
            let count = selectedNotificationIDs.count
            return count == 1
                ? "Are you sure you want to delete this article?"
                : "Are you sure you want to delete \(count) articles?"
        }
    }

    private var isAnyFilterActive: Bool {
        showUnreadOnly || showBookmarkedOnly || showArchivedContent
    }

    private var visibleTopics: [String] {
        let filtered = allNotifications.filter { note in
            let archivedCondition = showArchivedContent || !note.isArchived
            let unreadCondition = !showUnreadOnly || !note.isViewed
            let bookmarkedCondition = !showBookmarkedOnly || note.isBookmarked
            return archivedCondition && unreadCondition && bookmarkedCondition
        }
        let topics = Set(filtered.compactMap { $0.topic })
        return ["All"] + topics.sorted()
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                // A single List that includes our header, topic bar, and then the notifications
                List(selection: $selectedNotificationIDs) {
                    // Place the header & filter button at the top so it scrolls away
                    Section {
                        headerView
                            // Remove the extra padding/spacing that Lists normally add:
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)

                        topicsBar
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }

                    // Main content: either empty state or the grouped notifications
                    if filteredNotifications.isEmpty {
                        Section {
                            emptyStateView
                                // Keep it flush to edges in the list
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        // Build each group as a section
                        ForEach(sortedAndGroupedNotifications, id: \.key) { group in
                            if !group.key.isEmpty {
                                Section(header: Text(group.key)) {
                                    ForEach(group.notifications, id: \.id) { notification in
                                        NotificationRow(
                                            notification: notification,
                                            editMode: editMode,
                                            selectedNotificationIDs: $selectedNotificationIDs
                                        )
                                        .onAppear {
                                            loadMoreNotificationsIfNeeded(currentItem: notification)
                                        }
                                    }
                                }
                            } else {
                                // Single group with no header
                                ForEach(group.notifications, id: \.id) { notification in
                                    NotificationRow(
                                        notification: notification,
                                        editMode: editMode,
                                        selectedNotificationIDs: $selectedNotificationIDs
                                    )
                                    .onAppear {
                                        loadMoreNotificationsIfNeeded(currentItem: notification)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, editMode)
                // Pull-to-refresh for the entire list
                .refreshable {
                    Task {
                        await SyncManager.shared.sendRecentArticlesToServer()
                    }
                }
                .onChange(of: allNotifications.map(\.isViewed)) {
                    updateFilteredNotifications()
                }
                .onChange(of: selectedTopic) { _, newTopic in
                    // If we changed topics, reset scroll if desired
                    if lastSelectedTopic != newTopic {
                        needsScrollReset = true
                        lastSelectedTopic = newTopic

                        // Force an immediate refresh with the new topic
                        updateFilteredNotifications(force: true)
                    }
                }
                .onChange(of: showArchivedContent) { _, _ in
                    needsTopicReset = true
                    updateFilteredNotifications()
                }
                .onChange(of: showUnreadOnly) { _, _ in
                    needsTopicReset = true
                    updateFilteredNotifications()
                }
                .onChange(of: showBookmarkedOnly) { _, _ in
                    needsTopicReset = true
                    updateFilteredNotifications()
                }
                .onChange(of: visibleTopics) { _, _ in
                    if needsTopicReset {
                        if !visibleTopics.contains(selectedTopic) {
                            selectedTopic = "All"
                        }
                        needsTopicReset = false
                    }
                }
                .onChange(of: editMode?.wrappedValue) { _, newValue in
                    if newValue == .inactive {
                        selectedNotificationIDs.removeAll()
                    }
                }
                .onChange(of: allNotifications) { _, _ in
                    updateFilteredNotifications()
                }
                .onAppear {
                    if subscriptions.isEmpty {
                        subscriptions = SubscriptionsView().loadSubscriptions()
                    }
                    if filteredNotifications.isEmpty {
                        updateFilteredNotifications()
                    }
                    startBackgroundRefresh()
                }
                .onDisappear {
                    backgroundRefreshTask?.cancel()
                    backgroundRefreshTask = nil
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NotificationPermissionGranted"))) { _ in
                    subscriptions = SubscriptionsView().loadSubscriptions()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleArchived"))) { _ in
                    updateFilteredNotifications()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if !isActivelyScrolling {
                                handleScrollBegin()
                            }
                        }
                )
                .confirmationDialog(
                    deleteConfirmationMessage,
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        withAnimation {
                            if let article = articleToDelete {
                                deleteNotification(article)
                                articleToDelete = nil
                            } else {
                                deleteSelectedNotifications()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        articleToDelete = nil
                    }
                }

                // The filter sheet slides up from the bottom
                if isFilterViewPresented {
                    filterSheet
                        .zIndex(1)
                }

                // The custom bottom toolbar for Edit mode
                if editMode?.wrappedValue == .active {
                    editToolbar
                        .zIndex(1)
                }
            }
            // A trailing nav bar button to toggle Edit mode
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    customEditButton()
                }
            }
        }
    }

    // MARK: - Subviews

    var headerView: some View {
        HStack {
            Image("Argus")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
            Text("Argus")
                .font(.largeTitle)
                .bold()
            Spacer()
            Button(action: {
                withAnimation {
                    isFilterViewPresented.toggle()
                }
            }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(isAnyFilterActive ? .blue : .primary)
                    .padding(.leading, 8)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }

    var topicsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(visibleTopics, id: \.self) { topic in
                    Button {
                        // Update the selected topic immediately
                        withAnimation {
                            selectedTopic = topic
                            // Force an immediate update when user taps a topic
                            updateFilteredNotifications(force: true)
                        }
                    } label: {
                        Text(topic)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTopic == topic ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(selectedTopic == topic ? .white : .primary)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGray6))
    }

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Text("RSS Fed")
                .font(.title)
                .padding(.bottom, 8)
            Image("Argus")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .padding(.bottom, 8)
            VStack(spacing: 12) {
                Text("No news is good news.")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(getEmptyStateMessage())
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding()
    }

    // MARK: - Row building

    struct AccessibleAttributedText: UIViewRepresentable {
        let attributedString: NSAttributedString

        func makeUIView(context _: Context) -> UITextView {
            let textView = UITextView()
            textView.attributedText = attributedString
            textView.isEditable = false
            textView.isSelectable = false // Disable selection
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear

            // Remove default padding
            textView.textContainerInset = UIEdgeInsets.zero
            textView.textContainer.lineFragmentPadding = 0

            // Enable Dynamic Type
            textView.adjustsFontForContentSizeCategory = true

            // Make sure it expands to fit content
            textView.setContentCompressionResistancePriority(.required, for: .vertical)

            // Disable scrolling indicators
            textView.showsHorizontalScrollIndicator = false
            textView.showsVerticalScrollIndicator = false

            return textView
        }

        func updateUIView(_ uiView: UITextView, context _: Context) {
            uiView.attributedText = attributedString

            // Ensure it updates its layout
            uiView.layoutIfNeeded()
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize {
            // Set width constraint if available
            if let width = proposal.width {
                uiView.textContainer.size.width = width
                uiView.layoutIfNeeded()
            }

            // Get the natural size after layout
            let fittingSize = uiView.sizeThatFits(CGSize(
                width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
                height: UIView.layoutFittingExpandedSize.height
            ))

            return fittingSize
        }
    }

    private struct NotificationContentView: View {
        let notification: NotificationData
        let modelContext: ModelContext
        let filteredNotifications: [NotificationData]
        let totalNotifications: [NotificationData]
        @State private var titleAttributedString: NSAttributedString?
        @State private var bodyAttributedString: NSAttributedString?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            // Remove GeometryReader which might be causing sizing issues
            VStack(alignment: .leading, spacing: 8) {
                // Topic and Archive pills
                HStack(spacing: 8) {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                    if notification.isArchived {
                        ArchivedPill()
                    }
                    Spacer()
                }

                // Title - with accessibility support
                Group {
                    if let attributedTitle = titleAttributedString {
                        // Remove fixed height constraint
                        AccessibleAttributedText(attributedString: attributedTitle)
                    } else {
                        Text(notification.title)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                    }
                }
                .fontWeight(notification.isViewed ? .regular : .bold)

                // Publication Date
                if let pubDate = notification.pub_date {
                    Text(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // Body - with accessibility support
                Group {
                    if let attributedBody = bodyAttributedString {
                        // Remove fixed height constraint
                        AccessibleAttributedText(attributedString: attributedBody)
                    } else {
                        Text(notification.body)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                .foregroundColor(.secondary)

                // Affected
                if !notification.affected.isEmpty {
                    Text(notification.affected)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // Domain
                if let domain = notification.domain, !domain.isEmpty {
                    DomainView(
                        domain: domain,
                        notification: notification,
                        modelContext: modelContext,
                        filteredNotifications: filteredNotifications,
                        totalNotifications: totalNotifications
                    )
                }
            }
            .onAppear {
                loadRichTextContent()
            }
        }

        private func loadRichTextContent() {
            // First check if rich text versions already exist
            if let titleBlob = notification.title_blob,
               let bodyBlob = notification.body_blob
            {
                // Use existing rich text BLOBs
                do {
                    if let attributedTitle = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: titleBlob
                    ) {
                        titleAttributedString = attributedTitle
                    }

                    if let attributedBody = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: bodyBlob
                    ) {
                        bodyAttributedString = attributedBody
                    }
                } catch {
                    print("Error unarchiving rich text: \(error)")
                }
            } else {
                // We need to convert and save the rich text versions - do this in background
                Task {
                    // Use the static method that handles conversion asynchronously
                    // This properly delegates to the shared instance and handles all thread coordination
                    SyncManager.convertMarkdownToRichTextIfNeeded(for: notification)

                    // Wait a brief moment for the conversion to complete
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

                    // Then retrieve the new rich text blobs on the main thread
                    await MainActor.run {
                        // Now that the blobs should be saved in the model, retrieve them
                        if let titleBlob = notification.title_blob {
                            do {
                                if let attributedTitle = try NSKeyedUnarchiver.unarchivedObject(
                                    ofClass: NSAttributedString.self,
                                    from: titleBlob
                                ) {
                                    self.titleAttributedString = attributedTitle
                                }
                            } catch {
                                print("Error unarchiving title after conversion: \(error)")
                            }
                        }

                        if let bodyBlob = notification.body_blob {
                            do {
                                if let attributedBody = try NSKeyedUnarchiver.unarchivedObject(
                                    ofClass: NSAttributedString.self,
                                    from: bodyBlob
                                ) {
                                    self.bodyAttributedString = attributedBody
                                }
                            } catch {
                                print("Error unarchiving body after conversion: \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    private struct DomainView: View {
        let domain: String
        let notification: NotificationData
        let modelContext: ModelContext
        let filteredNotifications: [NotificationData]
        let totalNotifications: [NotificationData]
        @State private var isLoading = false
        @State private var loadError: Error? = nil
        @State private var hasFetchedMetadata = false

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .onTapGesture {
                        // Only load full content when user taps on the domain
                        if notification.sources_quality == nil &&
                            notification.argument_quality == nil &&
                            notification.source_type == nil
                        {
                            loadFullContent()
                        } else {
                            navigateToDetailView(section: "Source Analysis")
                        }
                    }

                if notification.sources_quality != nil ||
                    notification.argument_quality != nil ||
                    notification.source_type != nil
                {
                    // Use local data since it's already available
                    QualityBadges(
                        sourcesQuality: notification.sources_quality,
                        argumentQuality: notification.argument_quality,
                        sourceType: notification.source_type,
                        scrollToSection: .constant(nil),
                        onBadgeTap: { section in
                            navigateToDetailView(section: section)
                        }
                    )
                } else if isLoading {
                    // Show loading indicator
                    ProgressView()
                        .frame(height: 20)
                } else if loadError != nil {
                    // Show error state
                    Text("Failed to load content")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    // No data available yet - just show an empty space
                    // Don't trigger automatic loading
                    Color.clear.frame(height: 20)
                }
            }
            .onAppear {
                // Check if we've already tried to fetch metadata for this notification
                if !hasFetchedMetadata &&
                    notification.sources_quality == nil &&
                    notification.argument_quality == nil &&
                    notification.source_type == nil
                {
                    // Query database for metadata instead of making a network request
                    fetchLocalMetadataOnly()
                }
            }
        }

        private func fetchLocalMetadataOnly() {
            // Mark that we've tried to fetch metadata to avoid repeated attempts
            hasFetchedMetadata = true

            // Only query the local database to see if we have any metadata already stored
            Task {
                // Check if there's any metadata in the database for this notification ID
                // without making a network request
                do {
                    // Query the database for this notification by ID to ensure we have the latest data
                    // Using string-based predicate to avoid macro expansion issues
                    let descriptor = FetchDescriptor<NotificationData>()

                    // Perform a simple fetch and filter manually
                    let allNotifications = try modelContext.fetch(descriptor)
                    if let updatedNotification = allNotifications.first(where: { $0.id == notification.id }) {
                        // If database has metadata that our current reference doesn't, update our view
                        await MainActor.run {
                            if updatedNotification.sources_quality != nil ||
                                updatedNotification.argument_quality != nil ||
                                updatedNotification.source_type != nil
                            {
                                // No need to trigger loadFullContent as the database already has the metadata
                                // Just force a view refresh with the latest data
                            }
                        }
                    }
                } catch {
                    print("Error fetching metadata from database: \(error)")
                }
            }
        }

        private func loadFullContent() {
            guard !isLoading else { return }

            isLoading = true
            Task {
                do {
                    // Use SyncManager to fetch and update the notification
                    _ = try await SyncManager.fetchFullContentIfNeeded(for: notification)

                    // After fetching, make sure rich text versions are created
                    await MainActor.run {
                        SyncManager.convertMarkdownToRichTextIfNeeded(for: notification)
                    }

                    // Update UI state
                    await MainActor.run {
                        isLoading = false
                        loadError = nil
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        loadError = error
                        print("Failed to load content for \(notification.json_url): \(error)")
                    }
                }
            }
        }

        private func navigateToDetailView(section: String) {
            guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
                return
            }

            let detailView = NewsDetailView(
                notifications: filteredNotifications,
                allNotifications: totalNotifications,
                currentIndex: index,
                initiallyExpandedSection: section
            )
            .environment(\.modelContext, modelContext)

            let hostingController = UIHostingController(rootView: detailView)
            hostingController.modalPresentationStyle = .fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootViewController = window.rootViewController
            {
                rootViewController.present(hostingController, animated: true)
            }
        }
    }

    private func NotificationRow(
        notification: NotificationData,
        editMode: Binding<EditMode>?,
        selectedNotificationIDs: Binding<Set<NotificationData.ID>>
    ) -> some View {
        // Create a local state to track the animation
        let isUnread = !notification.isViewed

        return VStack(alignment: .leading, spacing: 10) {
            // Top row: topic pill + archived pill
            HStack(spacing: 8) {
                if let topic = notification.topic, !topic.isEmpty {
                    TopicPill(topic: topic)
                }
                if notification.isArchived {
                    ArchivedPill()
                }
                Spacer()
                BookmarkButton(notification: notification)
            }

            // Title
            Text(notification.title)
                .font(.headline)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)

            // Publication Date
            if let pubDate = notification.pub_date {
                Text(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.disabled)
            }

            // Summary
            Group {
                if let bodyBlob = notification.body_blob,
                   let attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: bodyBlob)
                {
                    NonSelectableRichTextView(attributedString: attributedBody, lineLimit: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(notification.body.isEmpty ? "Loading content..." : notification.body)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .textSelection(.disabled)
                        .onAppear {
                            // Trigger background conversion only when this row appears
                            // and only if the rich text blob doesn't already exist
                            if notification.body_blob == nil {
                                Task {
                                    // This will trigger the optimized conversion in background
                                    SyncManager.convertMarkdownToRichTextIfNeeded(for: notification)
                                }
                            }
                        }
                }
            }

            // Affected Field
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .textSelection(.disabled)
            }

            // Domain
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .textSelection(.disabled)
            }

            // LazyLoadingQualityBadges
            HStack {
                LazyLoadingQualityBadges(notification: notification)
            }
            .padding(.top, 5)
        }
        .padding()
        .background(isUnread ? Color.blue.opacity(0.15) : Color.clear)
        .cornerRadius(10)
        .id(notification.id)
        .onLongPressGesture {
            withAnimation {
                editMode?.wrappedValue = .active
                selectedNotificationIDs.wrappedValue.insert(notification.id)
            }
        }
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { result in
                    switch result {
                    case .first:
                        // This is the double‐tap case
                        toggleReadStatus(notification)
                    case .second:
                        // This is the single‐tap case
                        openArticle(notification)
                    }
                }
        )
    }

    struct NonSelectableRichTextView: UIViewRepresentable {
        let attributedString: NSAttributedString
        var lineLimit: Int? = nil

        func makeUIView(context _: Context) -> UITextView {
            let textView = UITextView()
            textView.isEditable = false
            textView.isScrollEnabled = false
            textView.isSelectable = false // Disable selection
            textView.backgroundColor = .clear

            // Remove default padding
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0

            // Enable Dynamic Type
            textView.adjustsFontForContentSizeCategory = true

            // Ensure the text always starts at the same left margin
            textView.textAlignment = .left

            // Force `UITextView` to wrap by constraining its width
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.setContentHuggingPriority(.required, for: .horizontal)
            textView.setContentCompressionResistancePriority(.required, for: .horizontal)

            NSLayoutConstraint.activate([
                textView.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width - 40), // Ensures wrapping
            ])

            return textView
        }

        func updateUIView(_ uiView: UITextView, context _: Context) {
            let mutableString = NSMutableAttributedString(attributedString: attributedString)

            let bodyFont = UIFont.preferredFont(forTextStyle: .body)
            mutableString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: mutableString.length))

            uiView.attributedText = mutableString
            uiView.textAlignment = .left
            uiView.invalidateIntrinsicContentSize()
            uiView.layoutIfNeeded()
        }
    }

    private func handleScrollBegin() {
        isActivelyScrolling = true

        // Cancel any existing timer
        scrollIdleTimer?.cancel()

        // Create a new timer for when scrolling stops
        scrollIdleTimer = Task {
            // Wait for scroll to be idle (1 second)
            try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)

            await MainActor.run {
                isActivelyScrolling = false

                // If there's a pending update, run it now
                if pendingUpdateNeeded {
                    pendingUpdateNeeded = false
                    updateFilteredNotifications()
                }
            }
        }
    }

    private func openArticleWithSection(_ notification: NotificationData, section: String? = nil) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        let detailView = NewsDetailView(
            notifications: filteredNotifications,
            allNotifications: totalNotifications,
            currentIndex: index,
            initiallyExpandedSection: section
        )
        .environment(\.modelContext, modelContext)

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            rootViewController.present(hostingController, animated: true)
        }

        // Trigger content fetch and rich text conversion in the background
        Task {
            do {
                let updatedNotification = try await SyncManager.fetchFullContentIfNeeded(for: notification)

                // After fetching content, ensure rich text versions exist
                await MainActor.run {
                    SyncManager.convertMarkdownToRichTextIfNeeded(for: updatedNotification)
                }
            } catch {
                print("Error pre-loading full content: \(error)")
                // The UI will handle showing loading states if needed
            }
        }
    }

    private func openArticle(_ notification: NotificationData) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        let detailView = NewsDetailView(
            notifications: filteredNotifications,
            allNotifications: totalNotifications,
            currentIndex: index
        )
        .environment(\.modelContext, modelContext)

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.modalPresentationStyle = .fullScreen

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            rootViewController.present(hostingController, animated: true)
        }
    }

    private func determineSection(_ content: [String: Any]) -> String? {
        if content["sources_quality"] != nil {
            return "Source Analysis"
        }
        if content["argument_quality"] != nil {
            return "Logical Fallacies"
        }
        if content["source_type"] != nil {
            return "Source Analysis"
        }
        return nil
    }

    // Simplified bookmark icon on the trailing side
    private func BookmarkButton(notification: NotificationData) -> some View {
        Button {
            toggleBookmark(notification)
        } label: {
            Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                .foregroundColor(notification.isBookmarked ? .blue : .gray)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar and Filter Sheet

    var filterSheet: some View {
        VStack(spacing: 0) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isFilterViewPresented = false
                    }
                }
            FilterView(
                showUnreadOnly: $showUnreadOnly,
                showBookmarkedOnly: $showBookmarkedOnly,
                showArchivedContent: $showArchivedContent
            )
            .frame(height: filterViewHeight)
            .background(Color(UIColor.systemBackground))
            .cornerRadius(15, corners: [.topLeft, .topRight])
            .shadow(radius: 10)
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.height > 50 {
                            withAnimation {
                                isFilterViewPresented = false
                            }
                        }
                    }
            )
        }
        .transition(.move(edge: .bottom))
        .ignoresSafeArea()
        .padding(.bottom, tabBarHeight)
    }

    var editToolbar: some View {
        HStack {
            toolbarButton(
                icon: "envelope.badge",
                label: "Toggle Read"
            ) {
                performActionOnSelection { $0.isViewed.toggle() }
            }
            Spacer()
            toolbarButton(
                icon: "bookmark",
                label: "Bookmark"
            ) {
                performActionOnSelection { toggleBookmark($0) }
            }
            Spacer()
            toolbarButton(
                icon: "archivebox",
                label: "Archive"
            ) {
                performActionOnSelection { toggleArchive($0) }
            }
            Spacer()
            toolbarButton(
                icon: "trash",
                label: "Delete",
                isDestructive: true
            ) {
                handleEditModeDelete()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15, corners: [.topLeft, .topRight])
        .shadow(radius: 10)
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
            .foregroundColor(isDestructive ? .red : .primary)
            .frame(minWidth: 60)
        }
    }

    private func customEditButton() -> some View {
        Button(action: {
            withAnimation {
                if editMode?.wrappedValue == .inactive {
                    editMode?.wrappedValue = .active
                } else {
                    editMode?.wrappedValue = .inactive
                    selectedNotificationIDs.removeAll()
                }
            }
        }) {
            Text(editMode?.wrappedValue == .active ? "Cancel" : "Edit")
        }
    }

    // MARK: - Logic / Helpers

    private func handleTapGesture(for notification: NotificationData) {
        // If in Edit mode, toggle selection
        if editMode?.wrappedValue == .active {
            withAnimation {
                if selectedNotificationIDs.contains(notification.id) {
                    selectedNotificationIDs.remove(notification.id)
                } else {
                    selectedNotificationIDs.insert(notification.id)
                }
            }
        } else {
            // Otherwise, open article
            openArticle(notification)
        }
    }

    private func handleLongPressGesture(for notification: NotificationData) {
        // Long-press triggers Edit mode and selects the row
        withAnimation {
            if editMode?.wrappedValue == .inactive {
                editMode?.wrappedValue = .active
                selectedNotificationIDs.insert(notification.id)
            }
        }
    }

    private func handleEditModeDelete() {
        if !selectedNotificationIDs.isEmpty {
            // If user is deleting multiple selected rows
            articleToDelete = nil
            showDeleteConfirmation = true
        }
    }

    private func deleteNotification(_: NotificationData) {
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()
            updateFilteredNotifications()
            selectedNotificationIDs.removeAll()
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }

    private func deleteSelectedNotifications() {
        withAnimation {
            for id in selectedNotificationIDs {
                if let notification = filteredNotifications.first(where: { $0.id == id }) {
                    AppDelegate().removeNotificationIfExists(jsonURL: notification.json_url)
                }
            }
            saveChanges()
            updateFilteredNotifications()
            editMode?.wrappedValue = .inactive
            selectedNotificationIDs.removeAll()
        }
    }

    private func toggleReadStatus(_ notification: NotificationData) {
        notification.isViewed.toggle()
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()
            // Also clean up related notification, if any.
            AppDelegate().removeNotificationIfExists(jsonURL: notification.json_url)
        } catch {
            print("Failed to toggle read status: \(error)")
        }
    }

    private func toggleBookmark(_ notification: NotificationData) {
        notification.isBookmarked.toggle()
        saveChanges()
        updateFilteredNotifications()
    }

    private func toggleArchive(_ notification: NotificationData) {
        withAnimation {
            notification.isArchived.toggle()
            saveChanges()
            updateFilteredNotifications()
            // Also delete notification if exists.
            AppDelegate().removeNotificationIfExists(jsonURL: notification.json_url)
        }
    }

    private func performActionOnSelection(action: (NotificationData) -> Void) {
        if !selectedNotificationIDs.isEmpty {
            for id in selectedNotificationIDs {
                if let notification = filteredNotifications.first(where: { $0.id == id }) {
                    action(notification)
                }
            }
            saveChanges()
            updateFilteredNotifications()

            withAnimation {
                editMode?.wrappedValue = .inactive
                selectedNotificationIDs.removeAll()
            }
        }
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()
        } catch {
            print("Failed to save changes: \(error)")
        }
    }

    @MainActor
    private func updateFilteredNotifications(isBackgroundUpdate: Bool = false, force: Bool = false) {
        // Set a longer update interval for background refreshes (10 seconds)
        let updateInterval: TimeInterval = 10.0
        let now = Date()

        // For background updates, enforce a minimum time between updates
        if isBackgroundUpdate {
            guard now.timeIntervalSince(lastUpdateTime) > updateInterval,
                  !isUpdating
            else {
                return
            }
        }

        // Skip updates if we're actively scrolling, unless force=true (user explicitly tapped)
        if !force && isActivelyScrolling {
            pendingUpdateNeeded = true
            return
        }

        Task {
            isUpdating = true
            defer {
                isUpdating = false
                lastUpdateTime = Date()
            }

            // Reset pagination state when filters change
            self.lastLoadedDate = nil
            self.hasMoreContent = true
            self.totalNotifications = []
            self.filteredNotifications = []

            // Load the first page
            await loadPage(isInitialLoad: true)
        }
    }

    @MainActor
    private func loadPage(isInitialLoad: Bool = false) async {
        guard !isLoadingMorePages && (isInitialLoad || hasMoreContent) else { return }

        isLoadingMorePages = true
        defer { isLoadingMorePages = false }

        do {
            // Create the base predicate from filters
            let basePredicate = buildPredicate()

            // Create date boundary predicate if this isn't the first page
            var datePredicateWrapper: Predicate<NotificationData>? = nil
            if let oldestSoFar = lastLoadedDate, !isInitialLoad {
                // This predicate finds items older than the last one we loaded
                datePredicateWrapper = #Predicate<NotificationData> {
                    // Handle both pub_date and date with a fallback
                    ($0.pub_date ?? $0.date) < oldestSoFar
                }
            }

            // Combine the base predicate with the date boundary
            var combinedPredicate: Predicate<NotificationData>?
            if let basePredicate = basePredicate {
                if let datePredicateWrapper = datePredicateWrapper {
                    combinedPredicate = #Predicate<NotificationData> {
                        basePredicate.evaluate($0) && datePredicateWrapper.evaluate($0)
                    }
                } else {
                    combinedPredicate = basePredicate
                }
            } else {
                combinedPredicate = datePredicateWrapper
            }

            // Create the fetch descriptor with our combined predicate
            var descriptor = FetchDescriptor<NotificationData>(
                predicate: combinedPredicate
            )

            // Always sort by date in descending order
            descriptor.sortBy = [
                SortDescriptor(\.pub_date, order: .reverse),
                SortDescriptor(\.date, order: .reverse),
            ]

            // Limit the number of results per page
            descriptor.fetchLimit = pageSize

            // Fetch the notifications
            let fetchedNotifications = try modelContext.fetch(descriptor)

            // Update last loaded date for next pagination
            if let lastItem = fetchedNotifications.last {
                lastLoadedDate = lastItem.pub_date ?? lastItem.date
                print("Updated lastLoadedDate to: \(lastLoadedDate?.description ?? "nil")")
            }

            // Determine if we have more content to load
            hasMoreContent = !fetchedNotifications.isEmpty && fetchedNotifications.count == pageSize

            // Process the fetched notifications
            if isInitialLoad {
                // For initial load, replace the current content
                await processInitialPage(fetchedNotifications)
            } else {
                // For pagination, append the new content
                await processNextPage(fetchedNotifications)
            }
        } catch {
            print("Error fetching notifications: \(error)")
        }
    }

    @MainActor
    private func processInitialPage(_ notifications: [NotificationData]) async {
        // Sort the new page based on current sort order
        let sortedNotifications = sortNotifications(notifications)

        // Update the UI WITHOUT animation
        totalNotifications = sortedNotifications
        filteredNotifications = sortedNotifications

        updateGrouping()
    }

    @MainActor
    private func processNextPage(_ newNotifications: [NotificationData]) async {
        // Don't process if there's nothing new
        guard !newNotifications.isEmpty else {
            print("No more notifications to load")
            return
        }

        // Sort the combined results
        let combinedNotifications = totalNotifications + newNotifications
        let sortedCombined = sortNotifications(combinedNotifications)

        // Update the UI WITHOUT animation
        totalNotifications = sortedCombined
        filteredNotifications = sortedCombined

        updateGrouping()
        print("Added \(newNotifications.count) more notifications, total: \(sortedCombined.count)")
    }

    private func sortNotifications(_ notifications: [NotificationData]) -> [NotificationData] {
        return notifications.sorted { n1, n2 in
            switch sortOrder {
            case "oldest":
                return (n1.pub_date ?? n1.date) < (n2.pub_date ?? n2.date)
            case "bookmarked":
                if n1.isBookmarked != n2.isBookmarked {
                    return n1.isBookmarked
                }
                return (n1.pub_date ?? n1.date) > (n2.pub_date ?? n2.date)
            default: // "newest"
                return (n1.pub_date ?? n1.date) > (n2.pub_date ?? n2.date)
            }
        }
    }

    private func mergeAndProcessNotifications(_ newNotifications: [NotificationData]) async {
        // Move to background for heavy processing
        return await Task.detached {
            // Capture needed values
            let currentSortOrder = await self.sortOrder
            let currentBatchSize = await self.batchSize

            // Force a full replacement when the content is completely different or
            // when the topic filter has changed
            let isFullReplacement = true // Treat all updates as full replacements for now

            // Create a sorting function that properly uses effectiveDate
            let sortNotifications: ([NotificationData]) -> [NotificationData] = { notifications in
                notifications.sorted { n1, n2 in
                    switch currentSortOrder {
                    case "oldest":
                        return n1.effectiveDate < n2.effectiveDate
                    case "bookmarked":
                        if n1.isBookmarked != n2.isBookmarked {
                            return n1.isBookmarked
                        }
                        return n1.effectiveDate > n2.effectiveDate
                    default: // "newest"
                        return n1.effectiveDate > n2.effectiveDate
                    }
                }
            }

            // Sort all the notifications properly
            let sortedTotal = sortNotifications(newNotifications)

            // Debug the sorting
            await MainActor.run {
                print("-- Sorting Diagnostics --")
                print("Sort order: \(currentSortOrder)")
                if let firstFew = sortedTotal.prefix(3).map({ "\($0.effectiveDate): \($0.title.prefix(20))..." }).joined(separator: "\n- ").nilIfEmpty {
                    print("First few sorted items:\n- \(firstFew)")
                }

                // Extra diagnostics - check pub_date vs date
                for notification in sortedTotal.prefix(3) {
                    print("ID: \(notification.id)")
                    print("  pub_date: \(String(describing: notification.pub_date))")
                    print("  date: \(notification.date)")
                    print("  effectiveDate: \(notification.effectiveDate)")
                    print("  title: \(notification.title.prefix(30))")
                }
            }

            // Create the batched array for display, respecting the current batch size
            let batchedNotifications = Array(sortedTotal.prefix(currentBatchSize))

            // Update UI on main thread with optimized arrays
            await MainActor.run {
                let hasChanges = true // Always update when filtering

                // Always update if the topic has changed
                if hasChanges || isFullReplacement {
                    // Update the full collection
                    self.totalNotifications = sortedTotal

                    self.filteredNotifications = batchedNotifications
                    self.updateGrouping()
                }
            }
        }.value
    }

    @MainActor
    private func buildPredicate() -> Predicate<NotificationData>? {
        // Always create a fresh predicate based on current filter settings
        let topicPredicate = selectedTopic == "All" ? nil :
            #Predicate<NotificationData> { $0.topic == selectedTopic }
        let archivedPredicate = showArchivedContent ? nil :
            #Predicate<NotificationData> { !$0.isArchived }
        let unreadPredicate = showUnreadOnly ?
            #Predicate<NotificationData> { !$0.isViewed } : nil
        let bookmarkedPredicate = showBookmarkedOnly ?
            #Predicate<NotificationData> { $0.isBookmarked } : nil

        // Combine predicates
        var combinedPredicate: Predicate<NotificationData>? = nil
        for predicate in [topicPredicate, archivedPredicate, unreadPredicate, bookmarkedPredicate].compactMap({ $0 }) {
            if let existing = combinedPredicate {
                combinedPredicate = #Predicate<NotificationData> {
                    existing.evaluate($0) && predicate.evaluate($0)
                }
            } else {
                combinedPredicate = predicate
            }
        }

        return combinedPredicate
    }

    private func startBackgroundRefresh() {
        // Cancel any existing task first
        backgroundRefreshTask?.cancel()

        backgroundRefreshTask = Task {
            while !Task.isCancelled {
                // Use a much longer interval - 5 minutes instead of 30 seconds
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes

                if Task.isCancelled { break }

                // First check if we need to update in the background
                let needsUpdate = await checkForNewContent()

                // Only trigger UI update if we actually have new content
                if needsUpdate {
                    await MainActor.run {
                        updateFilteredNotifications(isBackgroundUpdate: true)
                    }
                }
            }
        }
    }

    private func checkForNewContent() async -> Bool {
        // This could check for new notifications since the last known one
        // without triggering a full UI refresh
        do {
            // Get the timestamp of our newest notification
            let newestTimestamp = filteredNotifications.first?.pub_date ?? .distantPast

            // Create a predicate to find only newer items
            let newerPredicate = #Predicate<NotificationData> {
                ($0.pub_date ?? $0.date) > newestTimestamp
            }

            // Create the fetch descriptor with our predicate
            var descriptor = FetchDescriptor<NotificationData>(
                predicate: newerPredicate
            )

            // We just need to know if there are any, not fetch them all
            descriptor.fetchLimit = 1

            // Check if there are any new notifications
            let newNotifications = try modelContext.fetch(descriptor)
            return !newNotifications.isEmpty
        } catch {
            print("Error checking for new content: \(error)")
            return false
        }
    }

    @MainActor
    private func processNotifications(_ notifications: [NotificationData]) async {
        // Move to background for heavy processing
        return await Task.detached {
            // Capture needed values
            let currentSortOrder = await self.sortOrder
            let currentBatchSize = await self.batchSize

            // Add debug logging to see what's happening
            print("Sort order: \(currentSortOrder)")

            // Make sure we consistently use effectiveDate, not a mix of date types
            let sortedNotifications = notifications.sorted { n1, n2 in
                // Debug: Print sample of what we're comparing
                if notifications.count > 0 && n1.id == notifications[0].id {
                    print("Comparing dates for sorting:")
                    print("  n1 pub_date: \(String(describing: n1.pub_date))")
                    print("  n1 date: \(n1.date)")
                    print("  n1 effectiveDate: \(n1.pub_date ?? n1.date)")
                    print("  n2 pub_date: \(String(describing: n2.pub_date))")
                    print("  n2 date: \(n2.date)")
                    print("  n2 effectiveDate: \(n2.pub_date ?? n2.date)")
                }

                // Use direct date comparison with explicit property access
                // to avoid any extension issues
                switch currentSortOrder {
                case "oldest":
                    // For oldest first, earlier dates come first
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 < date2
                case "bookmarked":
                    if n1.isBookmarked != n2.isBookmarked {
                        return n1.isBookmarked
                    }
                    // For bookmarked, sort by newest within bookmarked status
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 > date2
                default: // "newest"
                    // For newest first, later dates come first
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 > date2
                }
            }

            // Print first few sorted items to verify
            print("After sorting (\(currentSortOrder)):")
            for (i, notification) in sortedNotifications.prefix(3).enumerated() {
                let date = notification.pub_date ?? notification.date
                print("  \(i). \(date) - \(notification.title.prefix(20))...")
            }

            // Create the batched array
            let batchedNotifications = Array(sortedNotifications.prefix(currentBatchSize))

            // Update UI on main thread with copied arrays
            await MainActor.run {
                self.totalNotifications = sortedNotifications

                self.filteredNotifications = batchedNotifications

                self.updateGrouping()
            }
        }.value
    }

    private func loadMoreNotificationsIfNeeded(currentItem: NotificationData) {
        guard let currentIndex = filteredNotifications.firstIndex(where: { $0.id == currentItem.id }) else {
            return
        }

        // When we're within 5 items of the end, load more content
        let thresholdIndex = filteredNotifications.count - 5

        if currentIndex >= thresholdIndex && hasMoreContent && !isLoadingMorePages {
            Task {
                await loadPage(isInitialLoad: false)
            }
        }
    }

    private func updateGrouping() {
        // Use Task and MainActor rather than Task.detached to balance performance
        Task(priority: .userInitiated) {
            // Performing the sort and group operation in a non-blocking way to the main thread
            let sorted = filteredNotifications.sorted { n1, n2 in
                switch sortOrder {
                case "oldest":
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 < date2
                case "bookmarked":
                    if n1.isBookmarked != n2.isBookmarked {
                        return n1.isBookmarked
                    }
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 > date2
                default: // "newest"
                    let date1 = n1.pub_date ?? n1.date
                    let date2 = n2.pub_date ?? n2.date
                    return date1 > date2
                }
            }

            let newGroupingData: [(key: String, displayKey: String, notifications: [NotificationData])]

            switch groupingStyle {
            case "date":
                let groupedByDay = Dictionary(grouping: sorted) {
                    Calendar.current.startOfDay(for: $0.pub_date ?? $0.date)
                }
                let sortedDayKeys = groupedByDay.keys.sorted { $0 < $1 }
                newGroupingData = sortedDayKeys.map { day in
                    let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                    let notifications = groupedByDay[day] ?? []
                    return (key: displayKey, displayKey: displayKey, notifications: notifications)
                }
            case "topic":
                let groupedByTopic = Dictionary(grouping: sorted) { $0.topic ?? "Uncategorized" }
                newGroupingData = groupedByTopic.map {
                    (key: $0.key, displayKey: $0.key, notifications: $0.value)
                }.sorted { $0.key < $1.key }
            default:
                newGroupingData = [("", "", sorted)]
            }

            // Exit early if there's no difference to prevent unnecessary animation
            if areGroupingArraysEqual(self.sortedAndGroupedNotifications,
                                      newGroupingData.map { ($0.displayKey, $0.notifications) })
            {
                return
            }

            // Update on the main actor/UI
            await MainActor.run {
                self.sortedAndGroupedNotifications = newGroupingData.map { ($0.displayKey, $0.notifications) }
            }
        }
    }

    private func areGroupingArraysEqual(
        _ lhs: [(key: String, notifications: [NotificationData])],
        _ rhs: [(key: String, notifications: [NotificationData])]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (index, leftGroup) in lhs.enumerated() {
            let rightGroup = rhs[index]
            if leftGroup.key != rightGroup.key || leftGroup.notifications.map(\.id) != rightGroup.notifications.map(\.id) {
                return false
            }
        }
        return true
    }

    private func getEmptyStateMessage() -> String {
        let activeSubscriptions = subscriptions.filter { $0.value.isSubscribed }.keys.sorted()
        if activeSubscriptions.isEmpty {
            return "You are not currently subscribed to any topics. Click 'Subscriptions' below."
        }
        var message = "Please be patient, news will arrive automatically. You do not need to leave this application open.\n\nYou are currently subscribed to: \(activeSubscriptions.joined(separator: ", "))."
        if isAnyFilterActive {
            message += "\n\n"
            if showUnreadOnly && showBookmarkedOnly {
                message += "You are filtering to show only Unread articles that have also been Bookmarked."
            } else if showUnreadOnly {
                message += "You are filtering to show only Unread articles."
            } else if showBookmarkedOnly {
                message += "You are filtering to show only Bookmarked articles."
            }
            if !showArchivedContent {
                message += "\n\nYou can enable the 'Show archived' filter to show articles you archived earlier."
            }
        } else if !showArchivedContent && allNotifications.contains(where: { $0.isArchived }) {
            message += "\n\nYou can enable the 'Show archived' filter to show articles you archived earlier."
        }
        return message
    }

    // MARK: - Row Content Helpers

    private func rowContent(for notification: NotificationData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: topic pill + archived pill
            HStack(spacing: 8) {
                if let topic = notification.topic, !topic.isEmpty {
                    TopicPill(topic: topic)
                }
                if notification.isArchived {
                    ArchivedPill()
                }
            }
            .padding(.horizontal, 10)

            // Title - use accessible attributed text if available
            if let titleBlob = notification.title_blob,
               let attributedTitle = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: titleBlob)
            {
                AccessibleAttributedText(attributedString: attributedTitle)
                    .frame(height: 50) // Allow some space for the text to grow with Dynamic Type
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            } else {
                Text(notification.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
            }

            // Domain (optional)
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }

            // Body - use accessible attributed text if available
            if let bodyBlob = notification.body_blob,
               let attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: bodyBlob)
            {
                AccessibleAttributedText(attributedString: attributedBody)
                    .frame(minHeight: 50) // Allow space for dynamic type
                    .padding(.horizontal, 10)
            } else {
                Text(notification.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
            }

            // Affected (optional)
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 18)
            }
        }
        .onAppear {
            // Convert markdown to rich text if needed when row appears
            SyncManager.convertMarkdownToRichTextIfNeeded(for: notification)
        }
    }
}

struct LazyLoadingQualityBadges: View {
    let notification: NotificationData
    var onBadgeTap: ((String) -> Void)?
    @State private var scrollToSection: String? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var isLoading = false
    @State private var loadError: Error? = nil
    @State private var hasFetchedMetadata = false

    var body: some View {
        Group {
            // First try to use the locally stored data
            if notification.sources_quality != nil ||
                notification.argument_quality != nil ||
                notification.source_type != nil
            {
                QualityBadges(
                    sourcesQuality: notification.sources_quality,
                    argumentQuality: notification.argument_quality,
                    sourceType: notification.source_type,
                    scrollToSection: $scrollToSection,
                    onBadgeTap: onBadgeTap
                )
            } else if isLoading {
                // Show loading indicator
                ProgressView()
                    .frame(height: 20)
            } else if loadError != nil {
                // Show error state
                Text("Failed to load content")
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                // No data available yet, but don't eagerly load - just show placeholder
                // Only fetch when explicitly needed (user interaction)
                Color.clear.frame(height: 20)
            }
        }
        .onAppear {
            // Check if we've already tried to fetch metadata for this notification
            if !hasFetchedMetadata &&
                notification.sources_quality == nil &&
                notification.argument_quality == nil &&
                notification.source_type == nil
            {
                // Query database for metadata instead of making a network request
                fetchLocalMetadataOnly()
            }
        }
    }

    private func fetchLocalMetadataOnly() {
        // Mark that we've tried to fetch metadata to avoid repeated attempts
        hasFetchedMetadata = true

        // Only query the local database to see if we have any metadata already stored
        Task {
            // Check if there's any metadata in the database for this notification ID
            // without making a network request
            do {
                // Query the database for this notification by ID to ensure we have the latest data
                // Using string-based predicate to avoid macro expansion issues
                let descriptor = FetchDescriptor<NotificationData>()

                // Perform a simple fetch and filter manually
                let allNotifications = try modelContext.fetch(descriptor)
                if let updatedNotification = allNotifications.first(where: { $0.id == notification.id }) {
                    // If database has metadata that our current reference doesn't, update our view
                    await MainActor.run {
                        if updatedNotification.sources_quality != nil ||
                            updatedNotification.argument_quality != nil ||
                            updatedNotification.source_type != nil
                        {
                            // No need to trigger loadFullContent as the database already has the metadata
                            // Just force a view refresh with the latest data
                        }
                    }
                }
            } catch {
                print("Error fetching metadata from database: \(error)")
            }
        }
    }

    // This method should now only be called when explicitly needed (e.g., user taps on content)
    private func loadFullContent() {
        guard !isLoading else { return }

        isLoading = true
        Task {
            do {
                // Use SyncManager to fetch and update the notification
                _ = try await SyncManager.fetchFullContentIfNeeded(for: notification)

                // Update UI state
                await MainActor.run {
                    isLoading = false
                    loadError = nil
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadError = error
                    print("Failed to load content for \(notification.json_url): \(error)")
                }
            }
        }
    }
}

// MARK: - Pills

struct ArchivedPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox.fill")
                .font(.caption2)
            Text("Archived")
                .font(.caption2)
                .bold()
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(uiColor: .systemOrange).opacity(0.3))
        .cornerRadius(8)
    }
}

struct TopicPill: View {
    let topic: String

    var body: some View {
        Text(topic)
            .font(.caption2)
            .bold()
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(uiColor: .systemGray5))
            .cornerRadius(8)
    }
}

// MARK: - FilterView

struct FilterView: View {
    @Binding var showUnreadOnly: Bool
    @Binding var showBookmarkedOnly: Bool
    @Binding var showArchivedContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Filters")
                .font(.headline)
                .padding(.top)
            Toggle("Only unread", isOn: $showUnreadOnly)
            Toggle("Only bookmarked", isOn: $showBookmarkedOnly)
            Toggle("Show archived", isOn: $showArchivedContent)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15, corners: [.topLeft, .topRight])
        .shadow(radius: 10)
    }
}

// MARK: - RoundedCorner Utility

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

extension String {
    var nilIfEmpty: String? {
        return isEmpty ? nil : self
    }
}

struct RichTextView: UIViewRepresentable {
    let attributedString: NSAttributedString
    var lineLimit: Int? = nil

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear

        // Remove default padding
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        // Enable Dynamic Type
        textView.adjustsFontForContentSizeCategory = true

        // Ensure the text always starts at the same left margin
        textView.textAlignment = .left

        // Force `UITextView` to wrap by constraining its width
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width - 40), // Ensures wrapping
        ])

        return textView
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        let mutableString = NSMutableAttributedString(attributedString: attributedString)

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        mutableString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: mutableString.length))

        uiView.attributedText = mutableString
        uiView.textAlignment = .left
        uiView.invalidateIntrinsicContentSize()
        uiView.layoutIfNeeded()
    }
}
