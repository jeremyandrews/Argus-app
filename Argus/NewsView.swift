import SwiftData
import SwiftUI
import UIKit

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
    @State private var notificationsCache: [String: [NotificationData]] = [:]
    @State private var lastCacheUpdate: Date = .distantPast
    @State private var isCacheValid: Bool = false
    // Tracks the previous filter state to detect actual changes and avoid redundant updates
    // This helps prevent unnecessary database queries and UI refreshes
    @State private var lastFilterState: (
        topic: String,
        unread: Bool,
        bookmarked: Bool,
        archived: Bool,
        notificationCount: Int
    ) = ("All", false, false, false, 0)
    // Task that manages debounced filter updates to prevent rapid successive updates
    // when multiple filter settings change in quick succession
    @State private var filterChangeDebouncer: Task<Void, Never>? = nil
    // Timestamp of the most recent filter change, used to determine appropriate debounce intervals
    @State private var lastFilterChangeTime: Date = .distantPast

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
                .onChange(of: editMode?.wrappedValue) { _, newValue in
                    if newValue == .inactive {
                        selectedNotificationIDs.removeAll()
                    }
                }
                // When topic changes, use the specialized filter handler with the topic change flag
                // to ensure immediate responsive update
                .onChange(of: selectedTopic) { _, newTopic in
                    handleFilterChange(topicChanged: lastSelectedTopic != newTopic, newTopic: newTopic)
                }
                // Filter setting changes may require topic reset and filtered notifications update
                // but can use debounced updates for better performance
                .onChange(of: showUnreadOnly) { _, _ in
                    needsTopicReset = true
                    handleFilterChange()
                }
                .onChange(of: showBookmarkedOnly) { _, _ in
                    needsTopicReset = true
                    handleFilterChange()
                }
                .onChange(of: showArchivedContent) { _, _ in
                    needsTopicReset = true
                    handleFilterChange()
                }
                // When notification data changes, update with debouncing
                // This is separate from filter changes and doesn't need topic reset logic
                .onChange(of: allNotifications.count) { _, _ in
                    // Just a notification count change - might need a different type of update
                    // Use debouncing to avoid multiple quick updates
                    handleFilterChange(isDataChange: true)
                }
                // Dedicated observer for badge updates that only triggers when read status changes
                // This prevents over-fetching and only updates the badge count when needed
                .onChange(of: allNotifications.filter { !$0.isViewed }.count) { _, _ in
                    NotificationUtils.updateAppBadgeCount()
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

    // Central handler for all filter changes with smart debouncing
    // - Immediately processes topic changes (for responsive UI)
    // - Handles topic reset logic when filters affect available topics
    // - Applies variable debounce intervals based on user activity and recency of changes
    // - Cancels pending updates when new changes occur
    // Parameters:
    //   - topicChanged: Whether the selected topic has changed (requires immediate update)
    //   - newTopic: The new topic if topic has changed
    //   - isDataChange: Whether this is a data change rather than a filter settings change
    private func handleFilterChange(topicChanged: Bool = false, newTopic: String? = nil, isDataChange: Bool = false) {
        // Cancel any pending debounced update
        filterChangeDebouncer?.cancel()

        // Handle topic change - these need immediate attention
        if topicChanged, let newTopic = newTopic {
            needsScrollReset = true
            lastSelectedTopic = newTopic
            // Topic changes should force an update without debouncing
            updateFilteredNotifications(force: true)
            return
        }

        // Check if this is a filter change that needs topic reset
        if needsTopicReset && !isDataChange {
            if !visibleTopics.contains(selectedTopic) {
                selectedTopic = "All"
            }
            needsTopicReset = false
        }

        // Determine appropriate debounce interval based on:
        // - How recently a change was made (avoid rapid successive updates)
        // - Whether the user is actively scrolling (avoid UI hitches)
        // - Whether this is an isolated change (can be faster)
        let now = Date()
        let timeSinceLastChange = now.timeIntervalSince(lastFilterChangeTime)

        // Amount of debounce depends on how recently we updated
        let debounceInterval: TimeInterval
        if timeSinceLastChange < 0.5 {
            // For very rapid changes, use a longer debounce
            debounceInterval = 0.5
        } else if isActivelyScrolling {
            // Longer debounce while scrolling
            debounceInterval = 0.75
        } else {
            // Small debounce for isolated changes
            debounceInterval = 0.25
        }

        // Create a debouncer task
        filterChangeDebouncer = Task {
            // Wait for the debounce period
            try? await Task.sleep(for: .seconds(debounceInterval))

            if Task.isCancelled { return }

            // Update the last change timestamp
            await MainActor.run {
                lastFilterChangeTime = Date()
                // Now actually perform the update
                updateFilteredNotifications(force: false)
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
            // Use the new markdown utilities to get attributed strings
            titleAttributedString = getAttributedString(
                for: .title,
                from: notification,
                createIfMissing: true
            )

            bodyAttributedString = getAttributedString(
                for: .body,
                from: notification,
                createIfMissing: true
            )
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
                    AppLogger.database.error("Error fetching metadata from database: \(error)")
                }
            }
        }

        private func loadFullContent() {
            guard !isLoading else { return }

            isLoading = true
            Task {
                // Generate rich text content for the fields based on what's currently available
                _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
                _ = getAttributedString(for: .body, from: notification, createIfMissing: true)

                // Update UI state
                await MainActor.run {
                    isLoading = false
                    loadError = nil
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

    @MainActor
    fileprivate func generateBodyBlob(notificationID: UUID) async {
        // 1) Grab the main-context
        let mainContext = ArgusApp.sharedModelContainer.mainContext

        // 2) Re-fetch that same NotificationData in the main context
        let descriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate { $0.id == notificationID }
        )
        guard
            let mainThreadNotification = try? mainContext.fetch(descriptor).first
        else {
            return
        }

        // 3) Build the attributed .body and persist it
        _ = getAttributedString(for: .body, from: mainThreadNotification, createIfMissing: true)

        do {
            try mainContext.save()
        } catch {
            AppLogger.database.error("Failed to save body_blob in main context: \(error)")
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
            // Top row
            headerRow(notification)

            // Title
            titleView(notification)

            // Publication Date
            publicationDateView(notification)

            // Summary
            summaryContent(notification)

            // Affected Field
            affectedFieldView(notification)

            // Domain
            domainView(notification)

            // Quality Badges
            badgesView(notification)
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
        .onAppear {
            loadMoreNotificationsIfNeeded(currentItem: notification)

            // If the blob doesn't exist yet, generate and save it on the main thread
            if notification.body_blob == nil {
                Task {
                    await generateBodyBlob(notificationID: notification.id)
                }
            }
        }
    }

    // Helper functions for each part of the row
    private func headerRow(_ notification: NotificationData) -> some View {
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
    }

    private func titleView(_ notification: NotificationData) -> some View {
        Text(notification.title)
            .font(.headline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func publicationDateView(_ notification: NotificationData) -> some View {
        Group {
            if let pubDate = notification.pub_date {
                Text(dateFormatter.string(from: pubDate))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.disabled)
            }
        }
    }

    private func summaryContent(_ notification: NotificationData) -> some View {
        Group {
            if let bodyBlob = notification.body_blob,
               let attributedBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: bodyBlob)
            {
                NonSelectableRichTextView(attributedString: attributedBody, lineLimit: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(notification.body.isEmpty ? "(Error: missing data)" : notification.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .textSelection(.disabled)
            }
        }
    }

    private func affectedFieldView(_ notification: NotificationData) -> some View {
        Group {
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .textSelection(.disabled)
            }
        }
    }

    private func domainView(_ notification: NotificationData) -> some View {
        Group {
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                    .textSelection(.disabled)
            }
        }
    }

    private func badgesView(_ notification: NotificationData) -> some View {
        HStack {
            LazyLoadingQualityBadges(notification: notification)
        }
        .padding(.top, 5)
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

    private func openArticle(_ notification: NotificationData) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        // Pre-load the rich text content synchronously before creating the detail view
        // This ensures formatted content is shown immediately
        let titleAttrString = getAttributedString(for: .title, from: notification, createIfMissing: true)
        let bodyAttrString = getAttributedString(for: .body, from: notification, createIfMissing: true)

        let detailView = NewsDetailView(
            notification: notification,
            preloadedTitle: titleAttrString,
            preloadedBody: bodyAttrString,
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

        // After presenting the view, start a background task to prepare the next few articles
        // This makes swiping through articles smoother
        Task(priority: .userInitiated) {
            // Find the next few articles (up to 3) that might be viewed next
            let nextIndices = [index + 1, index + 2, index + 3].filter { $0 < filteredNotifications.count }

            // Pre-load their rich text content (but with less priority than the current article)
            for nextIndex in nextIndices {
                let nextNotification = filteredNotifications[nextIndex]
                // This will cache the blobs if they don't exist yet
                Task(priority: .background) {
                    await generateBodyBlob(notificationID: nextNotification.id)
                }
            }
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
            AppLogger.database.error("Failed to delete notification: \(error)")
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
            AppLogger.database.error("Failed to toggle read status: \(error)")
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
            AppLogger.database.error("Failed to save changes: \(error)")
        }
    }

    // Handles filter changes with minimal UI blocking by:
    // 1. Using in-memory cache for fast topic filtering when possible
    // 2. Moving heavy database operations to background threads
    // 3. Only updating UI state on the main thread once data is ready
    // 4. Implementing smart debouncing to avoid redundant updates
    // This significantly improves responsiveness when filtering large datasets
    @MainActor
    private func updateFilteredNotifications(isBackgroundUpdate: Bool = false, force: Bool = false) {
        // Update the instance property instead of creating a new local variable
        lastFilterState = (
            selectedTopic,
            showUnreadOnly,
            showBookmarkedOnly,
            showArchivedContent,
            allNotifications.count
        )

        // Check update timing and scrolling constraints
        let updateInterval: TimeInterval = 10.0
        let now = Date()
        if isBackgroundUpdate {
            guard now.timeIntervalSince(lastUpdateTime) > updateInterval,
                  !isUpdating
            else {
                return
            }
        }

        if !force && isActivelyScrolling {
            pendingUpdateNeeded = true
            return
        }

        Task {
            // Set updating flag
            isUpdating = true
            defer {
                isUpdating = false
                lastUpdateTime = Date()
            }

            // Check for new content when forced
            if force {
                let hasNewContent = await checkForNewContent()
                if hasNewContent {
                    isCacheValid = false
                }
            }

            // Fast path: Use cache for quick filtering
            if !force && isCacheValid && now.timeIntervalSince(lastCacheUpdate) < 60.0 &&
                notificationsCache.keys.contains("All")
            {
                if let cachedData = notificationsCache["All"] {
                    // IMPORTANT: Create a local copy of the filtered data before updating UI
                    let filtered: [NotificationData]
                    if selectedTopic == "All" {
                        filtered = filterNotificationsWithCurrentSettings(cachedData)
                    } else {
                        let topicFiltered = cachedData.filter { $0.topic == selectedTopic }
                        filtered = filterNotificationsWithCurrentSettings(topicFiltered)
                    }

                    // Update grouping first with the filtered data before updating the UI
                    let updatedGrouping = await createGroupedNotifications(filtered)

                    // Now update the UI in one step to prevent flickering
                    await MainActor.run {
                        self.sortedAndGroupedNotifications = updatedGrouping
                        self.filteredNotifications = filtered
                    }
                    return
                }
            }

            // Reset pagination state but keep current data visible until new data is ready
            await MainActor.run {
                self.lastLoadedDate = nil
                self.hasMoreContent = true
                // Don't clear existing data yet
                // self.totalNotifications = []
                // self.filteredNotifications = []
            }

            // Load the first page in the background
            let (newNotifications, groups) = await loadPageAndPrepareGroups()

            // Only update UI when we have the new data ready
            await MainActor.run {
                // Update all state at once to minimize flickering
                self.totalNotifications = newNotifications
                self.filteredNotifications = newNotifications
                self.sortedAndGroupedNotifications = groups
            }

            // Cache the results
            await updateNotificationsCache()
        }
    }

    // Add this new helper function to prepare groups without updating UI
    private func loadPageAndPrepareGroups() async -> ([NotificationData], [(key: String, notifications: [NotificationData])]) {
        guard !isLoadingMorePages else { return ([], []) }

        await MainActor.run {
            isLoadingMorePages = true
        }

        defer {
            Task { @MainActor in
                isLoadingMorePages = false
            }
        }

        // Capture values needed for background processing
        let currentTopic = selectedTopic
        let currentShowUnreadOnly = showUnreadOnly
        let currentShowBookmarkedOnly = showBookmarkedOnly
        let currentShowArchivedContent = showArchivedContent
        let currentSortOrder = sortOrder
        let currentGroupingStyle = groupingStyle
        let currentPageSize = pageSize

        // Perform the fetch in a background context
        let result = await BackgroundContextManager.shared.performBackgroundTask { backgroundContext in
            do {
                // [Same predicate building code as loadPage function]
                // ...

                var basePredicate: Predicate<NotificationData>?

                if currentTopic != "All" {
                    basePredicate = #Predicate<NotificationData> { $0.topic == currentTopic }
                }

                if !currentShowArchivedContent {
                    let archivePredicate = #Predicate<NotificationData> { !$0.isArchived }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && archivePredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = archivePredicate
                    }
                }

                if currentShowUnreadOnly {
                    let unreadPredicate = #Predicate<NotificationData> { !$0.isViewed }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && unreadPredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = unreadPredicate
                    }
                }

                if currentShowBookmarkedOnly {
                    let bookmarkPredicate = #Predicate<NotificationData> { $0.isBookmarked }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && bookmarkPredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = bookmarkPredicate
                    }
                }

                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: basePredicate
                )

                // Sort by date
                if currentSortOrder == "oldest" {
                    descriptor.sortBy = [
                        SortDescriptor(\.pub_date, order: .forward),
                        SortDescriptor(\.date, order: .forward),
                    ]
                } else {
                    descriptor.sortBy = [
                        SortDescriptor(\.pub_date, order: .reverse),
                        SortDescriptor(\.date, order: .reverse),
                    ]
                }

                descriptor.fetchLimit = currentPageSize

                // Fetch the notifications
                let fetchedNotifications = try backgroundContext.fetch(descriptor)

                // Directly prepare the grouping data
                let groupedData: [(key: String, notifications: [NotificationData])]

                switch currentGroupingStyle {
                case "date":
                    let groupedByDay = Dictionary(grouping: fetchedNotifications) {
                        Calendar.current.startOfDay(for: $0.pub_date ?? $0.date)
                    }
                    let sortedDayKeys = groupedByDay.keys.sorted { $0 > $1 }
                    groupedData = sortedDayKeys.map { day in
                        let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                        let notifications = groupedByDay[day] ?? []
                        return (key: displayKey, notifications: notifications)
                    }
                case "topic":
                    let groupedByTopic = Dictionary(grouping: fetchedNotifications) { $0.topic ?? "Uncategorized" }
                    groupedData = groupedByTopic.map {
                        (key: $0.key, notifications: $0.value)
                    }.sorted { $0.key < $1.key }
                default:
                    groupedData = [("", fetchedNotifications)]
                }

                return (fetchedNotifications, groupedData)
            } catch {
                AppLogger.sync.error("Error fetching notifications: \(error)")
                return ([], [])
            }
        }

        return result
    }

    private func createGroupedNotifications(_ notifications: [NotificationData]) async -> [(key: String, notifications: [NotificationData])] {
        let currentGroupingStyle = groupingStyle
        let currentSortOrder = sortOrder

        return await Task.detached(priority: .userInitiated) {
            // Sort notifications in background
            let sorted = notifications.sorted { n1, n2 in
                switch currentSortOrder {
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

            // Group notifications
            switch currentGroupingStyle {
            case "date":
                let groupedByDay = Dictionary(grouping: sorted) {
                    Calendar.current.startOfDay(for: $0.pub_date ?? $0.date)
                }
                let sortedDayKeys = groupedByDay.keys.sorted { $0 > $1 }
                return sortedDayKeys.map { day in
                    let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                    let notifications = groupedByDay[day] ?? []
                    return (key: displayKey, notifications: notifications)
                }
            case "topic":
                let groupedByTopic = Dictionary(grouping: sorted) { $0.topic ?? "Uncategorized" }
                return groupedByTopic.map {
                    (key: $0.key, notifications: $0.value)
                }.sorted { $0.key < $1.key }
            default:
                return [("", sorted)]
            }
        }.value
    }

    // Helper function to filter notifications with current settings
    private func filterNotificationsWithCurrentSettings(_ notifications: [NotificationData]) -> [NotificationData] {
        return notifications.filter { note in
            let archivedCondition = showArchivedContent || !note.isArchived
            let unreadCondition = !showUnreadOnly || !note.isViewed
            let bookmarkedCondition = !showBookmarkedOnly || note.isBookmarked
            return archivedCondition && unreadCondition && bookmarkedCondition
        }
    }

    // Updates notification caches in the background to speed up future filtering.
    // Key optimizations:
    // 1. Performs all processing work on a background thread
    // 2. Creates separate caches for each topic to enable instant topic switching
    // 3. Only builds the cache once but can reuse it for multiple filter operations
    // 4. Only returns to the main thread to update the final cache references
    // This dramatically improves performance by avoiding repeated database queries
    private func updateNotificationsCache() async {
        await BackgroundContextManager.shared.performBackgroundTask { _ in
            // Only update the cache if we have data
            guard !self.totalNotifications.isEmpty else { return }

            // Create a copy of the data for thread safety
            let notificationsToCache = self.totalNotifications

            // Store in the cache based on topic
            var newCache: [String: [NotificationData]] = [:]
            newCache["All"] = notificationsToCache

            // Get unique topics and store them separately
            let topics = Set(notificationsToCache.compactMap { $0.topic })
            for topic in topics {
                let topicNotifications = notificationsToCache.filter { $0.topic == topic }
                newCache[topic] = topicNotifications
            }

            // Update the main thread cache
            Task { @MainActor in
                self.notificationsCache = newCache
                self.lastCacheUpdate = Date()
                self.isCacheValid = true
            }
        }
    }

    // Performs efficient paginated database fetching on a background thread.
    // Optimizations include:
    // 1. Building predicates in the background to avoid main thread work
    // 2. Using SwiftData's sortDescriptors to let the database handle sorting
    // 3. Setting appropriate fetch limits to only load what's needed
    // 4. Capturing state variables before background work to avoid race conditions
    // 5. Only returning to the main thread for final UI updates
    // This keeps scrolling smooth even with large datasets
    private func loadPage(isInitialLoad: Bool = false) async {
        guard !isLoadingMorePages && (isInitialLoad || hasMoreContent) else { return }

        await MainActor.run {
            isLoadingMorePages = true
        }

        defer {
            Task { @MainActor in
                isLoadingMorePages = false
            }
        }

        // Capture values needed for background processing
        let currentTopic = selectedTopic
        let currentShowUnreadOnly = showUnreadOnly
        let currentShowBookmarkedOnly = showBookmarkedOnly
        let currentShowArchivedContent = showArchivedContent
        let currentSortOrder = sortOrder
        let currentLastLoadedDate = lastLoadedDate
        let currentPageSize = pageSize

        // Perform the fetch in a background context
        let result = await BackgroundContextManager.shared.performBackgroundTask { backgroundContext in
            do {
                // Build the predicate
                var basePredicate: Predicate<NotificationData>?

                // Topic filter
                if currentTopic != "All" {
                    basePredicate = #Predicate<NotificationData> { $0.topic == currentTopic }
                }

                // Archive filter
                if !currentShowArchivedContent {
                    let archivePredicate = #Predicate<NotificationData> { !$0.isArchived }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && archivePredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = archivePredicate
                    }
                }

                // Unread filter
                if currentShowUnreadOnly {
                    let unreadPredicate = #Predicate<NotificationData> { !$0.isViewed }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && unreadPredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = unreadPredicate
                    }
                }

                // Bookmark filter
                if currentShowBookmarkedOnly {
                    let bookmarkPredicate = #Predicate<NotificationData> { $0.isBookmarked }
                    if let existing = basePredicate {
                        basePredicate = #Predicate<NotificationData> {
                            existing.evaluate($0) && bookmarkPredicate.evaluate($0)
                        }
                    } else {
                        basePredicate = bookmarkPredicate
                    }
                }

                // Date boundary predicate for pagination
                var datePredicateWrapper: Predicate<NotificationData>? = nil
                if let oldestSoFar = currentLastLoadedDate, !isInitialLoad {
                    datePredicateWrapper = #Predicate<NotificationData> {
                        if let pubDate = $0.pub_date {
                            return pubDate < oldestSoFar
                        } else {
                            return $0.date < oldestSoFar
                        }
                    }
                }

                // Combine predicates
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

                // Create the fetch descriptor
                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: combinedPredicate
                )

                // Sort by date
                if currentSortOrder == "oldest" {
                    descriptor.sortBy = [
                        SortDescriptor(\.pub_date, order: .forward),
                        SortDescriptor(\.date, order: .forward),
                    ]
                } else {
                    descriptor.sortBy = [
                        SortDescriptor(\.pub_date, order: .reverse),
                        SortDescriptor(\.date, order: .reverse),
                    ]
                }

                // Set fetch limit for pagination
                // For initial load, still use a reasonable page size
                descriptor.fetchLimit = currentPageSize

                // Fetch the notifications
                let fetchedNotifications = try backgroundContext.fetch(descriptor)

                // Track last loaded date for pagination
                let newLastLoadedDate: Date? = fetchedNotifications.last?.pub_date ?? fetchedNotifications.last?.date

                // Determine if we have more content to load
                let hasMore = !fetchedNotifications.isEmpty && fetchedNotifications.count == currentPageSize

                return (fetchedNotifications, newLastLoadedDate, hasMore)
            } catch {
                AppLogger.sync.error("Error fetching notifications: \(error)")
                return ([], nil, false)
            }
        }

        // Process results on the main thread
        await MainActor.run {
            let (notificationsToProcess, newLastLoadedDate, hasMore) = result

            if let newLastLoadedDate = newLastLoadedDate {
                self.lastLoadedDate = newLastLoadedDate
            }

            self.hasMoreContent = hasMore

            if isInitialLoad {
                self.totalNotifications = notificationsToProcess
                self.filteredNotifications = notificationsToProcess
            } else {
                // For pagination, add the newly fetched items
                self.totalNotifications.append(contentsOf: notificationsToProcess)
                self.filteredNotifications.append(contentsOf: notificationsToProcess)
            }

            // Update grouping
            updateGrouping()
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
            AppLogger.sync.debug("No more notifications to load")
            return
        }

        // Sort the combined results
        let combinedNotifications = totalNotifications + newNotifications
        let sortedCombined = sortNotifications(combinedNotifications)

        // Update the UI WITHOUT animation
        totalNotifications = sortedCombined
        filteredNotifications = sortedCombined

        updateGrouping()
        AppLogger.database.debug("Added \(newNotifications.count) more notifications, total: \(sortedCombined.count)")
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
                AppLogger.database.debug("-- Sorting Diagnostics --")
                AppLogger.database.debug("Sort order: \(currentSortOrder)")
                if let firstFew = sortedTotal.prefix(3).map({ "\($0.effectiveDate): \($0.title.prefix(20))..." }).joined(separator: "\n- ").nilIfEmpty {
                    AppLogger.database.debug("First few sorted items:\n- \(firstFew)")
                }

                // Extra diagnostics - check pub_date vs date
                for notification in sortedTotal.prefix(3) {
                    AppLogger.database.debug("ID: \(notification.id)")
                    AppLogger.database.debug("  pub_date: \(String(describing: notification.pub_date))")
                    AppLogger.database.debug("  date: \(notification.date)")
                    AppLogger.database.debug("  effectiveDate: \(notification.effectiveDate)")
                    AppLogger.database.debug("  title: \(notification.title.prefix(30))")
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

    // Creates an optimized database query predicate based on current filter settings
    // Combines multiple filter conditions efficiently to minimize database load
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

        // Background refresh uses a long interval (5 minutes) to minimize battery usage
        // while still keeping content reasonably fresh
        // Only triggers UI updates if there is actually new content
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

    // Efficiently determines if new content exists without fetching all items.
    // Optimizations:
    // 1. Uses a background context for the database query
    // 2. Creates a targeted predicate that only looks for newer items
    // 3. Sets a fetchLimit=1 to return as soon as any new item is found
    // 4. Returns just a boolean result rather than fetching actual content
    // This allows for frequent polling without performance penalties
    private func checkForNewContent() async -> Bool {
        return await BackgroundContextManager.shared.performBackgroundTask { backgroundContext in
            do {
                // Get the timestamp of our newest notification
                let newestTimestamp = self.filteredNotifications.first?.pub_date ?? .distantPast

                // Create a predicate to find only newer items
                let newerPredicate = #Predicate<NotificationData> {
                    if let pubDate = $0.pub_date {
                        return pubDate > newestTimestamp
                    } else {
                        return $0.date > newestTimestamp
                    }
                }

                // Create the fetch descriptor with our predicate
                var descriptor = FetchDescriptor<NotificationData>(
                    predicate: newerPredicate
                )

                // We just need to know if there are any, not fetch them all
                descriptor.fetchLimit = 1

                // Check if there are any new notifications
                let newNotifications = try backgroundContext.fetch(descriptor)
                return !newNotifications.isEmpty
            } catch {
                AppLogger.sync.error("Error checking for new content: \(error)")
                return false
            }
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
            AppLogger.database.debug("Sort order: \(currentSortOrder)")

            // Make sure we consistently use effectiveDate, not a mix of date types
            let sortedNotifications = notifications.sorted { n1, n2 in
                // Debug: Show a sample of what we're comparing
                if notifications.count > 0 && n1.id == notifications[0].id {
                    AppLogger.database.debug("Comparing dates for sorting:")
                    AppLogger.database.debug("  n1 pub_date: \(String(describing: n1.pub_date))")
                    AppLogger.database.debug("  n1 date: \(n1.date)")
                    AppLogger.database.debug("  n1 effectiveDate: \(n1.pub_date ?? n1.date)")
                    AppLogger.database.debug("  n2 pub_date: \(String(describing: n2.pub_date))")
                    AppLogger.database.debug("  n2 date: \(n2.date)")
                    AppLogger.database.debug("  n2 effectiveDate: \(n2.pub_date ?? n2.date)")
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

            // Show the first few sorted items to verify
            AppLogger.database.debug("After sorting (\(currentSortOrder)):")
            for (i, notification) in sortedNotifications.prefix(3).enumerated() {
                let date = notification.pub_date ?? notification.date
                AppLogger.database.debug("  \(i). \(date) - \(notification.title.prefix(20))...")
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

    // Performs expensive sorting and grouping operations on a background thread.
    // Benefits include:
    // 1. Moving Dictionary grouping operations off the main thread
    // 2. Performing date calculations in the background
    // 3. Handling complex sorting logic without blocking UI
    // 4. Only dispatching back to main thread for the final UI update
    // This prevents UI hitches when changing grouping styles or when data updates
    private func updateGrouping() {
        Task {
            // Prepare the grouping in the background
            let updatedGrouping = await createGroupedNotifications(filteredNotifications)

            // Update UI in one step
            await MainActor.run {
                self.sortedAndGroupedNotifications = updatedGrouping
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
