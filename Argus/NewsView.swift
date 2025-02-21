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
    @State private var showUnreadOnly: Bool = false
    @State private var showBookmarkedOnly: Bool = false
    @State private var showArchivedContent: Bool = false
    @State private var isFilterViewPresented: Bool = false
    @State private var selectedTopic: String = "All"
    @State private var subscriptions: [String: Subscription] = [:]
    @State private var needsTopicReset: Bool = false
    @State private var filterViewHeight: CGFloat = 200
    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastSelectedTopic: String = "All"
    @State private var needsScrollReset: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var articleToDelete: NotificationData?
    @State private var totalNotifications: [NotificationData] = []
    @State private var batchSize: Int = 50 // Start by displaying 50 items

    @AppStorage("sortOrder") private var sortOrder: String = "newest"
    @AppStorage("groupingStyle") private var groupingStyle: String = "none"

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
                .onChange(of: selectedTopic) { _, newTopic in
                    // If we changed topics, reset scroll if desired
                    if lastSelectedTopic != newTopic {
                        needsScrollReset = true
                        lastSelectedTopic = newTopic
                    }
                }
                .onChange(of: showArchivedContent) { _, _ in
                    needsTopicReset = true
                }
                .onChange(of: showUnreadOnly) { _, _ in
                    needsTopicReset = true
                }
                .onChange(of: showBookmarkedOnly) { _, _ in
                    needsTopicReset = true
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
                    subscriptions = SubscriptionsView().loadSubscriptions()
                    updateFilteredNotifications()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NotificationPermissionGranted"))) { _ in
                    subscriptions = SubscriptionsView().loadSubscriptions()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ArticleArchived"))) { _ in
                    updateFilteredNotifications()
                }
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
                        // Then trigger the filter update
                        updateFilteredNotifications()
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

    private func NotificationRow(
        notification: NotificationData,
        editMode: Binding<EditMode>?,
        selectedNotificationIDs: Binding<Set<NotificationData.ID>>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                // TOPIC + ARCHIVED
                HStack(spacing: 8) {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }
                    if notification.isArchived {
                        ArchivedPill()
                    }
                }

                // TITLE (bold if unread)
                let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                Text(AttributedString(attributedTitle))
                    .font(.headline)
                    .fontWeight(notification.isViewed ? .regular : .bold)

                // PUBLICATION DATE
                if let pubDate = notification.pub_date {
                    Text(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // SUMMARY
                let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                Text(AttributedString(attributedBody))
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                // AFFECTED
                if !notification.affected.isEmpty {
                    Text(notification.affected)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // DOMAIN
                if let domain = notification.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(domain)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(1)

                        LazyLoadingQualityBadges(
                            jsonURL: notification.json_url,
                            onBadgeTap: { section in
                                guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
                                    return
                                }
                                let detailView = NewsDetailView(
                                    notifications: filteredNotifications,
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
                        )
                    }
                }
            }

            Spacer()

            // Bookmark icon on the far trailing side
            BookmarkButton(notification: notification)

            // Checkmark if in Edit mode
            if editMode?.wrappedValue == .active {
                if selectedNotificationIDs.wrappedValue.contains(notification.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear {
            ContentCache.shared.loadContent(for: notification.json_url)
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
            // Double-tap toggles read/unread
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
        .onAppear {
            ContentCache.shared.loadContent(for: notification.json_url)
        }
    }

    private func openArticleWithSection(_ notification: NotificationData, _: [String: Any], _ section: String? = nil) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        let detailView = NewsDetailView(
            notifications: filteredNotifications,
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

    private func deleteNotification(_ notification: NotificationData) {
        AppDelegate().deleteLocalJSON(notification: notification)
        modelContext.delete(notification)
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
                    AppDelegate().deleteLocalJSON(notification: notification)
                    modelContext.delete(notification)
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
        if notification.isBookmarked {
            AppDelegate().saveJSONLocally(notification: notification)
        } else {
            AppDelegate().deleteLocalJSON(notification: notification)
        }
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
    private func updateFilteredNotifications() {
        let context = ArgusApp.sharedModelContainer.mainContext

        let topicPredicate = selectedTopic == "All" ? nil :
            #Predicate<NotificationData> { $0.topic == selectedTopic }

        let archivedPredicate = showArchivedContent ? nil :
            #Predicate<NotificationData> { !$0.isArchived }

        let unreadPredicate = showUnreadOnly ?
            #Predicate<NotificationData> { !$0.isViewed } : nil

        let bookmarkedPredicate = showBookmarkedOnly ?
            #Predicate<NotificationData> { $0.isBookmarked } : nil

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

        let dateSortDescriptor = SortDescriptor<NotificationData>(\.date, order: .reverse)

        do {
            let descriptor = FetchDescriptor<NotificationData>(
                predicate: combinedPredicate,
                sortBy: [dateSortDescriptor]
            )

            totalNotifications = try context.fetch(descriptor)

            filteredNotifications = Array(totalNotifications.prefix(batchSize))
            updateGrouping()

        } catch {
            print("Failed to fetch filtered notifications: \(error)")
            filteredNotifications = []
            totalNotifications = []
        }
    }

    private func loadMoreNotificationsIfNeeded(currentItem: NotificationData) {
        guard let lastItem = filteredNotifications.last else { return }

        if currentItem.id == lastItem.id {
            let nextBatchSize = filteredNotifications.count + 50
            if nextBatchSize <= totalNotifications.count {
                withAnimation {
                    filteredNotifications = Array(totalNotifications.prefix(nextBatchSize))
                }
                updateGrouping() // ✅ Ensure grouping updates dynamically
            }
        }
    }

    private func updateGrouping() {
        let sorted = filteredNotifications.sorted { n1, n2 in
            switch sortOrder {
            case "oldest":
                return n1.date < n2.date
            case "bookmarked":
                if n1.isBookmarked != n2.isBookmarked {
                    return n1.isBookmarked
                }
                return n1.date > n2.date
            default: // "newest"
                return n1.date > n2.date
            }
        }

        let newGroupingData: [(key: String, displayKey: String, notifications: [NotificationData])]

        switch groupingStyle {
        case "date":
            let groupedByDay = Dictionary(grouping: sorted) { $0.date.dayOnly }

            let sortedDayKeys = groupedByDay.keys.sorted(by: >) // Ensure correct sorting

            newGroupingData = sortedDayKeys.map { dateKey in
                let displayKey = dateKey.formatted(.dateTime.month(.abbreviated).day().year()) // UI-visible
                let uniqueKey = "\(displayKey)-\(UUID().uuidString)" // Unique for SwiftUI refresh
                let items = groupedByDay[dateKey] ?? []
                return (key: uniqueKey, displayKey: displayKey, notifications: items)
            }

        case "topic":
            let groupedByTopic = Dictionary(grouping: sorted) { $0.topic ?? "Uncategorized" }
            newGroupingData = groupedByTopic
                .map { (key: $0.key, displayKey: $0.key, notifications: $0.value) }
                .sorted { $0.key < $1.key } // Alphabetical

        default:
            newGroupingData = [("", "", sorted)]
        }

        DispatchQueue.main.async {
            if !areGroupingArraysEqual(sortedAndGroupedNotifications, newGroupingData.map { ($0.key, $0.notifications) }) {
                sortedAndGroupedNotifications = newGroupingData.map { ($0.displayKey, $0.notifications) } // Keep UI clean
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

    private func openArticle(_ notification: NotificationData) {
        guard let index = filteredNotifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }

        let detailView = NewsDetailView(
            notifications: filteredNotifications,
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
    let jsonURL: String
    @State private var content: [String: Any]? = nil
    var onBadgeTap: ((String) -> Void)?

    var body: some View {
        Group {
            if let content = content ?? ContentCache.shared.getContent(for: jsonURL) {
                QualityBadges(
                    sourcesQuality: content["sources_quality"] as? Int,
                    argumentQuality: content["argument_quality"] as? Int,
                    sourceType: content["source_type"] as? String,
                    scrollToSection: .constant(nil),
                    onBadgeTap: onBadgeTap
                )
            } else {
                Color.clear.frame(height: 20)
                    .onAppear {
                        if ContentCache.shared.getContent(for: jsonURL) == nil {
                            ContentCache.shared.loadContent(for: jsonURL)
                        }
                    }
            }
        }
        .onAppear {
            // Try to load content immediately if available
            if content == nil {
                content = ContentCache.shared.getContent(for: jsonURL)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .init("ContentLoaded-\(jsonURL)"))
        ) { _ in
            self.content = ContentCache.shared.getContent(for: jsonURL)
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
