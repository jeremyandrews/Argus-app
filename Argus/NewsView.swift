import SwiftData
import SwiftUI
import UIKit

struct NewsView: View {
    // MARK: - View Model

    /// View model that manages article state and operations
    @StateObject var viewModel = NewsViewModel()

    // MARK: - Environment

    @Environment(\.editMode) private var editMode
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    /// UI State
    @State private var isFilterViewPresented: Bool = false
    @State private var filterViewHeight: CGFloat = 200
    @State private var showDeleteConfirmation = false
    @State private var articleToDelete: NotificationData?
    @State var isActivelyScrolling: Bool = false
    @State private var scrollIdleTimer: Task<Void, Never>? = nil
    @State private var scrollProxy: ScrollViewProxy?
    @State private var needsScrollReset: Bool = false

    /// Tab bar height from parent view
    @Binding var tabBarHeight: CGFloat

    // MARK: - Computed Properties

    /// Message for delete confirmation dialog
    var deleteConfirmationMessage: String {
        if articleToDelete != nil {
            return "This article is bookmarked. Are you sure you want to delete it?"
        } else {
            let count = viewModel.selectedArticleIds.count
            return count == 1
                ? "Are you sure you want to delete this article?"
                : "Are you sure you want to delete \(count) articles?"
        }
    }

    /// Determines if any filter is active
    private var isAnyFilterActive: Bool {
        viewModel.showUnreadOnly || viewModel.showBookmarkedOnly || viewModel.showArchivedContent
    }

    /// List of topics to show in topic bar
    private var visibleTopics: [String] {
        // Get unique topics from allArticles (which already match all non-topic filters)
        // No need to filter further since allArticles is already filtered by showUnreadOnly, 
        // showBookmarkedOnly, and showArchivedContent in the ViewModel
        let topics = Set(viewModel.allArticles.compactMap { $0.topic })
        return ["All"] + topics.sorted()
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                // Main List containing header, topic bar, and articles
                List(selection: $viewModel.selectedArticleIds) {
                    // Header Section
                    Section {
                        headerView
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)

                        topicsBar
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }

                    // Content Section - either empty state or articles
                    if viewModel.filteredArticles.isEmpty {
                        Section {
                            emptyStateView
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        // Build each group as a section
                        ForEach(viewModel.groupedArticles, id: \.key) { group in
                            if !group.key.isEmpty {
                                Section(header: Text(group.key)) {
                                    ForEach(group.notifications.uniqued(), id: \.id) { notification in
                                        NotificationRow(
                                            notification: notification,
                                            editMode: editMode,
                                            selectedNotificationIDs: $viewModel.selectedArticleIds
                                        )
                                        .onAppear {
                                            loadMoreNotificationsIfNeeded(currentItem: notification)
                                        }
                                    }
                                }
                            } else {
                                // Single group with no header
                                ForEach(group.notifications.uniqued(), id: \.id) { notification in
                                    NotificationRow(
                                        notification: notification,
                                        editMode: editMode,
                                        selectedNotificationIDs: $viewModel.selectedArticleIds
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
                        await viewModel.syncWithServer()
                    }
                }
                // Edit mode handling
                .onChange(of: editMode?.wrappedValue) { _, newValue in
                    if newValue == .inactive {
                        viewModel.selectedArticleIds.removeAll()
                    }
                }
                // Notification handling
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleArchived"))) { _ in
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleViewed"))) { _ in
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DetailViewClosed"))) { _ in
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleReadStatusChanged"))) { _ in
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                // Initial setup
                .onAppear {
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
                // Handle scrolling for better performance
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if !isActivelyScrolling {
                                handleScrollBegin()
                            }
                        }
                )
                // Delete confirmation dialog
                .confirmationDialog(
                    deleteConfirmationMessage,
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        withAnimation {
                            if let article = articleToDelete {
                                Task {
                                    await viewModel.deleteArticle(article)
                                }
                                articleToDelete = nil
                            } else {
                                Task {
                                    await viewModel.performBatchOperation(.delete)
                                }
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        articleToDelete = nil
                    }
                }

                // Filter sheet and edit toolbar
                if isFilterViewPresented {
                    filterSheet
                        .zIndex(1)
                }

                if editMode?.wrappedValue == .active {
                    editToolbar
                        .zIndex(1)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    customEditButton()
                }
            }
        }
    }

    // Central handler for all filter changes
    private func handleFilterChange(topicChanged: Bool = false, newTopic: String? = nil, isDataChange _: Bool = false) {
        Task {
            // Handle topic changes
            if topicChanged, let newTopic = newTopic {
                await viewModel.applyTopicFilter(newTopic)
                needsScrollReset = true
            } else {
                // Just refresh with current filters
                await viewModel.refreshArticles()
            }

            // If we need to scroll to top after filter changes and we're not actively scrolling
            if needsScrollReset && !isActivelyScrolling {
                needsScrollReset = false
                // (Scroll reset logic would go here if we had direct scroll control)
            }
        }
    }

    // MARK: - Subviews

    /// Header view with logo and filter button
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

    /// Topic filtering bar
    var topicsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(visibleTopics, id: \.self) { topic in
                    Button {
                        withAnimation {
                            let lastTopic = viewModel.selectedTopic

                            Task {
                                await viewModel.applyTopicFilter(topic)
                            }

                            // Request scroll reset if topic changes
                            if lastTopic != topic {
                                needsScrollReset = true
                            }
                        }
                    } label: {
                        Text(topic)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedTopic == topic ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(viewModel.selectedTopic == topic ? .white : .primary)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGray6))
    }

    /// Empty state view shown when no articles are available
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
                // Use the shared DomainSourceView component
                DomainSourceView(
                    domain: domain,
                    sourceType: notification.source_type,
                    onTap: {
                        // Only load full content when user taps on the domain
                        if notification.sources_quality == nil,
                           notification.argument_quality == nil,
                           notification.source_type == nil
                        {
                            loadFullContent()
                        } else {
                            navigateToDetailView(section: "Source Analysis")
                        }
                    },
                    onSourceTap: {
                        navigateToDetailView(section: "Source Analysis")
                    }
                )

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
                    generateBodyBlob(notificationID: notification.id)
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

    // Load summaryContent from NewsView+Extensions.swift

    // Load affectedFieldView from NewsView+Extensions.swift

    private func domainView(_ notification: NotificationData) -> some View {
        Group {
            if let domain = notification.domain, !domain.isEmpty {
                DomainSourceView(
                    domain: domain,
                    sourceType: notification.source_type,
                    onTap: {
                        // We'll just use the default tap behavior here like before
                        openArticle(notification)
                    },
                    onSourceTap: {
                        // Also open the article when source type is tapped
                        openArticle(notification)
                    }
                )
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
                if viewModel.pendingUpdateNeeded {
                    Task {
                        await viewModel.refreshArticles()
                    }
                }
            }
        }
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
                showUnreadOnly: Binding(
                    get: { viewModel.showUnreadOnly },
                    set: { viewModel.showUnreadOnly = $0 }
                ),
                showBookmarkedOnly: Binding(
                    get: { viewModel.showBookmarkedOnly },
                    set: { viewModel.showBookmarkedOnly = $0 }
                ),
                showArchivedContent: Binding(
                    get: { viewModel.showArchivedContent },
                    set: { viewModel.showArchivedContent = $0 }
                )
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
                    viewModel.selectedArticleIds.removeAll()
                }
            }
        }) {
            Text(editMode?.wrappedValue == .active ? "Cancel" : "Edit")
        }
    }

    // MARK: - Logic / Helpers

    // Fast path for topic switching using shared database manager
    @MainActor
    private func updateTopicFromCache(newTopic: String, previousTopic _: String) {
        // First check if we have this topic in the cache for immediate feedback
        if isCacheValid && notificationsCache.keys.contains(newTopic) {
            // Show instant UI update from cache
            let cachedTopicData = notificationsCache[newTopic] ?? []
            let filtered = filterNotificationsWithCurrentSettings(cachedTopicData)

            // Update UI immediately with cached data
            Task(priority: .userInitiated) {
                let updatedGrouping = await createGroupedNotifications(filtered)

                await MainActor.run {
                    self.filteredNotifications = filtered
                    self.sortedAndGroupedNotifications = updatedGrouping
                }
            }
        }

        // Then use the optimized DatabaseCoordinator to get fresh data
        // even if we had cached data, we refresh to ensure accuracy
        Task(priority: isCacheValid ? .background : .userInitiated) {
            // Use the new optimized database method
            let articles = await DatabaseCoordinator.shared.fetchArticlesForTopic(
                newTopic,
                showUnreadOnly: viewModel.showUnreadOnly,
                showBookmarkedOnly: viewModel.showBookmarkedOnly,
                showArchivedContent: viewModel.showArchivedContent
            )

            // If we got fresh data from the database, update the UI
            if !articles.isEmpty {
                let updatedGrouping = await createGroupedNotifications(articles)

                await MainActor.run {
                    // Update the UI with the fresh data
                    self.filteredNotifications = articles
                    self.sortedAndGroupedNotifications = updatedGrouping

                    // Update cache with the fresh data
                    self.notificationsCache[newTopic] = articles
                    self.lastCacheUpdate = Date()
                    self.isCacheValid = true
                }
            } else if !isCacheValid || !notificationsCache.keys.contains(newTopic) {
                // Only fall back to traditional method if we don't have cached data
                await MainActor.run {
                    updateFilteredNotifications(force: true)
                }
            }
        }
    }

    private func handleTapGesture(for notification: NotificationData) {
        // If in Edit mode, toggle selection
        if editMode?.wrappedValue == .active {
            withAnimation {
                if viewModel.selectedArticleIds.contains(notification.id) {
                    viewModel.selectedArticleIds.remove(notification.id)
                } else {
                    viewModel.selectedArticleIds.insert(notification.id)
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
                viewModel.selectedArticleIds.insert(notification.id)
            }
        }
    }

    private func handleEditModeDelete() {
        if !viewModel.selectedArticleIds.isEmpty {
            // If user is deleting multiple selected rows
            articleToDelete = nil
            showDeleteConfirmation = true
        }
    }

    private func deleteNotification(_ notification: NotificationData) {
        Task {
            await viewModel.deleteArticle(notification)

            // Update app badge count
            NotificationUtils.updateAppBadgeCount()

            // Clear selection
            viewModel.selectedArticleIds.removeAll()
        }
    }

    private func deleteSelectedNotifications() {
        withAnimation {
            Task {
                await viewModel.performBatchOperation(.delete)
            }
            editMode?.wrappedValue = .inactive
            // The selectedArticleIds are cleared in the ViewModel's performBatchOperation
        }
    }

    private func toggleReadStatus(_ notification: NotificationData) {
        Task {
            await viewModel.toggleReadStatus(for: notification)
        }
    }

    private func toggleBookmark(_ notification: NotificationData) {
        Task {
            await viewModel.toggleBookmark(for: notification)
        }
    }

    private func toggleArchive(_ notification: NotificationData) {
        Task {
            await viewModel.toggleArchive(for: notification)
        }
    }

    private func performActionOnSelection(action: (NotificationData) -> Void) {
        if !viewModel.selectedArticleIds.isEmpty {
            // For complex operations that aren't directly supported by viewModel batch operations,
            // we apply the action to each selected article
            for id in viewModel.selectedArticleIds {
                if let notification = viewModel.filteredArticles.first(where: { $0.id == id }) {
                    action(notification)
                }
            }

            // Reset selection state
            withAnimation {
                editMode?.wrappedValue = .inactive
                viewModel.selectedArticleIds.removeAll()
            }
        }
    }

    // Load openArticle, generateBodyBlob, and loadMoreNotificationsIfNeeded from NewsView+Extensions.swift

    @MainActor
    private func updateFilteredNotifications(force: Bool = false) {
        Task {
            await viewModel.updateFilteredArticles(
                isBackgroundUpdate: false,
                force: force,
                isActivelyScrolling: isActivelyScrolling
            )
        }
    }

    private func filterNotificationsWithCurrentSettings(_ notifications: [NotificationData]) -> [NotificationData] {
        return notifications.filter { note in
            let archivedCondition = viewModel.showArchivedContent || !note.isArchived
            let unreadCondition = !viewModel.showUnreadOnly || !note.isViewed
            let bookmarkedCondition = !viewModel.showBookmarkedOnly || note.isBookmarked
            return archivedCondition && unreadCondition && bookmarkedCondition
        }
    }

    private func createGroupedNotifications(_ notifications: [NotificationData]) async -> [(key: String, notifications: [NotificationData])] {
        return await Task.detached(priority: .userInitiated) {
            // Group notifications
            switch await viewModel.groupingStyle {
            case "date":
                let groupedByDay = Dictionary(grouping: notifications) {
                    Calendar.current.startOfDay(for: $0.pub_date ?? $0.date)
                }
                let sortedDayKeys = groupedByDay.keys.sorted { $0 > $1 }
                return sortedDayKeys.map { day in
                    let displayKey = day.formatted(date: .abbreviated, time: .omitted)
                    let notifications = groupedByDay[day] ?? []
                    return (key: displayKey, notifications: notifications)
                }
            case "topic":
                let groupedByTopic = Dictionary(grouping: notifications) { $0.topic ?? "Uncategorized" }
                return groupedByTopic.map {
                    (key: $0.key, notifications: $0.value)
                }.sorted { $0.key < $1.key }
            default:
                return [("", notifications)]
            }
        }.value
    }

    private func getEmptyStateMessage() -> String {
        let activeSubscriptions = viewModel.subscriptions.filter { $0.value.isSubscribed }.keys.sorted()
        if activeSubscriptions.isEmpty {
            return "You are not currently subscribed to any topics. Click 'Subscriptions' below."
        }
        var message = "Please be patient, news will arrive automatically. You do not need to leave this application open.\n\nYou are currently subscribed to: \(activeSubscriptions.joined(separator: ", "))."
        if isAnyFilterActive {
            message += "\n\n"
            if viewModel.showUnreadOnly && viewModel.showBookmarkedOnly {
                message += "You are filtering to show only Unread articles that have also been Bookmarked."
            } else if viewModel.showUnreadOnly {
                message += "You are filtering to show only Unread articles."
            } else if viewModel.showBookmarkedOnly {
                message += "You are filtering to show only Bookmarked articles."
            }
            if !viewModel.showArchivedContent {
                message += "\n\nYou can enable the 'Show archived' filter to show articles you archived earlier."
            }
        } else if !viewModel.showArchivedContent && viewModel.allArticles.contains(where: { $0.isArchived }) {
            message += "\n\nYou can enable the 'Show archived' filter to show articles you archived earlier."
        }
        return message
    }

    // Private properties needed for caching
    @State private var notificationsCache: [String: [NotificationData]] = [:]
    @State private var lastCacheUpdate = Date.distantPast
    @State private var isCacheValid = false
    @State private var filteredNotifications: [NotificationData] = []
    @State private var sortedAndGroupedNotifications: [(key: String, notifications: [NotificationData])] = []
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
