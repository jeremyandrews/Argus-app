import SwiftData
import SwiftUI
import SwiftyMarkdown

extension Date {
    var dayOnly: Date {
        Calendar.current.startOfDay(for: self)
    }
}

@Observable
final class ContentCache: @unchecked Sendable {
    static let shared = ContentCache()
    private let cache = NSCache<NSString, NSDictionary>()
    private let queue = DispatchQueue(label: "com.argus.contentcache", attributes: .concurrent)
    private var loadingTasks: [String: Task<Void, Never>] = [:]

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func getContent(for url: String) -> [String: Any]? {
        queue.sync {
            cache.object(forKey: url as NSString) as? [String: Any]
        }
    }

    func loadContent(for jsonURL: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard self?.cache.object(forKey: jsonURL as NSString) == nil,
                  self?.loadingTasks[jsonURL] == nil
            else {
                return
            }

            let task = Task { @MainActor in
                defer {
                    self?.queue.async(flags: .barrier) { [weak self] in
                        self?.loadingTasks[jsonURL] = nil
                    }
                }

                guard let url = URL(string: jsonURL) else { return }

                do {
                    let (data, _) = try await URLSession.shared.data(from: url)

                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.cache.setObject(json as NSDictionary, forKey: jsonURL as NSString)

                        NotificationCenter.default.post(
                            name: Notification.Name("ContentLoaded-\(jsonURL)"),
                            object: nil
                        )
                    }
                } catch {
                    print("Failed to load content for \(jsonURL): \(error)")
                }
            }

            self?.loadingTasks[jsonURL] = task
        }
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
                        updateFilteredNotifications()
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
                        }
                        // Don't call updateFilteredNotifications() here as it will be
                        // triggered by the onChange handler
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

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Topic and Archive pills
                HStack(spacing: 8) {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                    if notification.isArchived {
                        ArchivedPill()
                    }
                }

                // Title
                let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                Text(AttributedString(attributedTitle))
                    .font(.headline)
                    .fontWeight(notification.isViewed ? .regular : .bold)

                // Publication Date
                if let pubDate = notification.pub_date {
                    Text(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // Summary
                let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                Text(AttributedString(attributedBody))
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

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
        }
    }

    private struct DomainView: View {
        let domain: String
        let notification: NotificationData
        let modelContext: ModelContext
        let filteredNotifications: [NotificationData]
        let totalNotifications: [NotificationData]
        @State private var cachedContent: [String: Any]? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)

                // Try local data first, fallback to cached content
                if notification.sources_quality != nil ||
                    notification.argument_quality != nil ||
                    notification.source_type != nil
                {
                    // Use local data
                    QualityBadges(
                        sourcesQuality: notification.sources_quality,
                        argumentQuality: notification.argument_quality,
                        sourceType: notification.source_type,
                        scrollToSection: .constant(nil),
                        onBadgeTap: { section in
                            navigateToDetailView(section: section)
                        }
                    )
                } else if let content = cachedContent ?? ContentCache.shared.getContent(for: notification.json_url) {
                    // Use cached content
                    QualityBadges(
                        sourcesQuality: content["sources_quality"] as? Int,
                        argumentQuality: content["argument_quality"] as? Int,
                        sourceType: content["source_type"] as? String,
                        scrollToSection: .constant(nil),
                        onBadgeTap: { section in
                            navigateToDetailView(section: section)
                        }
                    )
                    .onAppear {
                        // Update notification with cached data
                        updateFromCache(content)
                    }
                } else {
                    // No data available yet - load it
                    Color.clear.frame(height: 20)
                        .onAppear {
                            ContentCache.shared.loadContent(for: notification.json_url)
                        }
                }
            }
            .onAppear {
                if cachedContent == nil && notification.sources_quality == nil {
                    cachedContent = ContentCache.shared.getContent(for: notification.json_url)
                    if cachedContent == nil {
                        ContentCache.shared.loadContent(for: notification.json_url)
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .init("ContentLoaded-\(notification.json_url)"))
            ) { _ in
                if let content = ContentCache.shared.getContent(for: notification.json_url) {
                    self.cachedContent = content
                    updateFromCache(content)
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

        private func updateFromCache(_ content: [String: Any]) {
            Task { @MainActor in
                if notification.sources_quality == nil {
                    notification.sources_quality = content["sources_quality"] as? Int
                }
                if notification.argument_quality == nil {
                    notification.argument_quality = content["argument_quality"] as? Int
                }
                if notification.source_type == nil {
                    notification.source_type = content["source_type"] as? String
                }

                if notification.sources_quality != nil ||
                    notification.argument_quality != nil ||
                    notification.source_type != nil
                {
                    try? modelContext.save()
                }
            }
        }
    }

    private func NotificationRow(
        notification: NotificationData,
        editMode: Binding<EditMode>?,
        selectedNotificationIDs: Binding<Set<NotificationData.ID>>
    ) -> some View {
        HStack {
            NotificationContentView(
                notification: notification,
                modelContext: modelContext,
                filteredNotifications: filteredNotifications,
                totalNotifications: totalNotifications
            )

            Spacer()

            BookmarkButton(notification: notification)
        }
        .padding()
        .background(notification.isViewed ? Color.clear : Color.blue.opacity(0.15))
        .cornerRadius(10)
        .id(notification.id)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleArchive(notification)
            } label: {
                Label(
                    notification.isArchived ? "Unarchive" : "Archive",
                    systemImage: notification.isArchived ? "tray.and.arrow.up.fill" : "archivebox"
                )
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !notification.isBookmarked) {
            if notification.isBookmarked {
                Button {
                    articleToDelete = notification
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            } else {
                Button(role: .destructive) {
                    deleteNotification(notification)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            toggleReadStatus(notification)
        }
        .onTapGesture(count: 1) {
            if editMode?.wrappedValue == .active {
                withAnimation {
                    if selectedNotificationIDs.wrappedValue.contains(notification.id) {
                        selectedNotificationIDs.wrappedValue.remove(notification.id)
                    } else {
                        selectedNotificationIDs.wrappedValue.insert(notification.id)
                    }
                }
            } else {
                handleTapGesture(for: notification)
            }
        }
        .onLongPressGesture {
            handleLongPressGesture(for: notification)
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

    private func openArticleWithSection(_ notification: NotificationData, _: [String: Any], section: String? = nil) {
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
    private func updateFilteredNotifications(isBackgroundUpdate: Bool = false) {
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

        // Skip updates if we're actively scrolling
        if isActivelyScrolling {
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

        // Update the UI
        withAnimation(.easeInOut(duration: 0.3)) {
            self.totalNotifications = sortedNotifications
            self.filteredNotifications = sortedNotifications
        }

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

        // Update the UI
        withAnimation(.easeInOut(duration: 0.3)) {
            self.totalNotifications = sortedCombined
            self.filteredNotifications = sortedCombined
        }

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

                    // Apply animation for the update
                    withAnimation(.easeInOut(duration: 0.3)) {
                        // For a full replacement or when filter changes, use the batch size
                        self.filteredNotifications = batchedNotifications
                    }

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

                withAnimation(.easeInOut(duration: 0.3)) {
                    self.filteredNotifications = batchedNotifications
                }

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
        Task.detached(priority: .userInitiated) { [sortOrder, groupingStyle] in
            // First get the sorted array - using the same sorting logic as in processNotifications
            let sorted = await MainActor.run {
                self.filteredNotifications.sorted { n1, n2 in
                    // Use direct date comparison with explicit property access
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
            }

            let newGroupingData: [(key: String, displayKey: String, notifications: [NotificationData])]

            switch groupingStyle {
            case "date":
                // Group by day
                let groupedByDay = Dictionary(grouping: sorted) {
                    let date = $0.pub_date ?? $0.date
                    return date.dayOnly
                }

                // Sort the days based on current sort order
                let sortedDayKeys: [Date]
                if sortOrder == "oldest" {
                    // For oldest first, sort days in ascending order
                    sortedDayKeys = groupedByDay.keys.sorted(by: <)
                } else {
                    // For newest first or bookmarked, sort days in descending order
                    sortedDayKeys = groupedByDay.keys.sorted(by: >)
                }

                // Create the grouped data structure
                newGroupingData = sortedDayKeys.map { dateKey in
                    let displayKey = dateKey.formatted(.dateTime.month(.abbreviated).day().year())

                    // Keep the order of notifications within each group consistent with overall sort
                    let sortedGroupNotifications = groupedByDay[dateKey] ?? []

                    return (key: displayKey, displayKey: displayKey, notifications: sortedGroupNotifications)
                }

            case "topic":
                let groupedByTopic = Dictionary(grouping: sorted) { $0.topic ?? "Uncategorized" }
                newGroupingData = groupedByTopic
                    .map { (key: $0.key, displayKey: $0.key, notifications: $0.value) }
                    .sorted { $0.key < $1.key }

            default:
                newGroupingData = [("", "", sorted)]
            }

            // Update UI on main thread with final result
            await MainActor.run {
                if !self.areGroupingArraysEqual(self.sortedAndGroupedNotifications,
                                                newGroupingData.map { ($0.displayKey, $0.notifications) })
                {
                    self.sortedAndGroupedNotifications = newGroupingData.map { ($0.displayKey, $0.notifications) }
                }
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

            // Title
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(.primary)
                .padding(.horizontal, 10)

            // Domain (optional)
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }

            // Body
            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.system(size: 14, weight: .light))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)

            // Affected (optional)
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 18)
            }
        }
    }
}

struct LazyLoadingQualityBadges: View {
    let notification: NotificationData
    @State private var content: [String: Any]? = nil
    var onBadgeTap: ((String) -> Void)?
    @State private var scrollToSection: String? = nil
    @Environment(\.modelContext) private var modelContext

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
            } else if let content = content ?? ContentCache.shared.getContent(for: notification.json_url) {
                // Fall back to the cached content if local data isn't available
                QualityBadges(
                    sourcesQuality: content["sources_quality"] as? Int,
                    argumentQuality: content["argument_quality"] as? Int,
                    sourceType: content["source_type"] as? String,
                    scrollToSection: $scrollToSection,
                    onBadgeTap: onBadgeTap
                )
                .onAppear {
                    // Update local data when we get it from cache
                    updateNotificationFromCache(notification, content)
                }
            } else {
                // If neither local nor cached data is available, load it
                Color.clear.frame(height: 20)
                    .onAppear {
                        ContentCache.shared.loadContent(for: notification.json_url)
                    }
            }
        }
        .onAppear {
            // Try to load content if needed
            if notification.sources_quality == nil &&
                notification.argument_quality == nil &&
                notification.source_type == nil
            {
                if content == nil {
                    content = ContentCache.shared.getContent(for: notification.json_url)
                }
                if content == nil {
                    ContentCache.shared.loadContent(for: notification.json_url)
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .init("ContentLoaded-\(notification.json_url)"))
        ) { _ in
            if let newContent = ContentCache.shared.getContent(for: notification.json_url) {
                self.content = newContent
                // Update notification with fetched data
                updateNotificationFromCache(notification, newContent)
            }
        }
    }

    // Helper to update notification with cached data
    private func updateNotificationFromCache(_ notification: NotificationData, _ content: [String: Any]) {
        Task { @MainActor in
            // Only update if not already set
            if notification.sources_quality == nil {
                notification.sources_quality = content["sources_quality"] as? Int
            }
            if notification.argument_quality == nil {
                notification.argument_quality = content["argument_quality"] as? Int
            }
            if notification.source_type == nil {
                notification.source_type = content["source_type"] as? String
            }

            // Save context if we made changes
            if notification.sources_quality != nil ||
                notification.argument_quality != nil ||
                notification.source_type != nil
            {
                do {
                    try modelContext.save()
                } catch {
                    print("Failed to save updated notification: \(error)")
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
