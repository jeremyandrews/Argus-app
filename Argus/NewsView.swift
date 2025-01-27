import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode

    @Query(sort: \NotificationData.date, order: .reverse) private var allNotifications: [NotificationData]

    @State private var filteredNotifications: [NotificationData] = []
    @State private var selectedNotificationIDs: Set<NotificationData.ID> = []
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

    private var topics: [String] {
        return visibleTopics
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
                VStack {
                    headerView
                    topicsBar
                    mainContentView
                }
                if isFilterViewPresented {
                    filterSheet
                }
                if editMode?.wrappedValue == .active {
                    editToolbar
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    customEditButton()
                }
            }
            .onChange(of: allNotifications) { _, _ in
                updateFilteredNotifications()
            }
            .onChange(of: selectedTopic) { _, newTopic in
                if lastSelectedTopic != newTopic {
                    needsScrollReset = true
                    lastSelectedTopic = newTopic
                }
                updateFilteredNotifications()
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
        }
    }

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
                    .overlay(
                        Circle()
                            .fill(isAnyFilterActive ? .blue : .clear)
                            .frame(width: 8, height: 8)
                            .offset(x: 10, y: -10)
                    )
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal)
    }

    var topicsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(visibleTopics, id: \.self) { topic in
                    Button {
                        selectedTopic = topic
                    } label: {
                        Text(topic)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedTopic == topic
                                    ? Color.blue
                                    : Color.gray.opacity(0.2)
                            )
                            .foregroundColor(
                                selectedTopic == topic ? .white : .primary
                            )
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGray6))
    }

    var mainContentView: some View {
        Group {
            if filteredNotifications.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { proxy in
                    notificationsListView
                        .onAppear {
                            scrollProxy = proxy
                        }
                }
            }
        }
    }

    var emptyStateView: some View {
        ScrollView {
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
        .refreshable {
            Task {
                await SyncManager.shared.sendRecentArticlesToServer()
            }
        }
    }

    var notificationsListView: some View {
        List(filteredNotifications, id: \.id, selection: $selectedNotificationIDs) { notification in
            NotificationRow(notification: notification, editMode: editMode, selectedNotificationIDs: $selectedNotificationIDs)
                .onTapGesture {
                    handleTapGesture(for: notification)
                }
                .onLongPressGesture {
                    handleLongPressGesture(for: notification)
                }
        }
        .listStyle(PlainListStyle())
        .environment(\.editMode, editMode)
        .refreshable {
            Task {
                await SyncManager.shared.sendRecentArticlesToServer()
            }
        }
        .onChange(of: filteredNotifications) { _, _ in
            handleScrollReset()
        }
    }

    private func NotificationRow(notification: NotificationData, editMode _: Binding<EditMode>?, selectedNotificationIDs _: Binding<Set<NotificationData.ID>>) -> some View {
        HStack {
            rowContent(for: notification)
            Spacer()
            BookmarkButton(notification: notification)
        }
        .padding(.vertical, 8)
        .listRowBackground(notificationBackground(for: notification))
        .cornerRadius(8)
        .id(notification.id)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            ArchiveButton(notification: notification)
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
                    withAnimation {
                        deleteNotification(notification)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func BookmarkButton(notification: NotificationData) -> some View {
        Button {
            toggleBookmark(notification)
        } label: {
            Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                .foregroundColor(notification.isBookmarked ? .blue : .gray)
        }
        .buttonStyle(.plain)
    }

    private func ArchiveButton(notification: NotificationData) -> some View {
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

    private func DeleteButton(notification: NotificationData) -> some View {
        Button(role: .destructive) {
            if notification.isBookmarked {
                articleToDelete = notification
                showDeleteConfirmation = true
            } else {
                withAnimation {
                    deleteNotification(notification)
                }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func handleEditModeDelete() {
        if !selectedNotificationIDs.isEmpty {
            articleToDelete = nil // Ensure we're in bulk delete mode
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
                }
            }
            saveChanges()
            updateFilteredNotifications()
            editMode?.wrappedValue = .inactive
            selectedNotificationIDs.removeAll()
        }
    }

    private func notificationBackground(for notification: NotificationData) -> Color {
        notification.isViewed ? Color.clear : Color.blue.opacity(0.2)
    }

    private func handleTapGesture(for notification: NotificationData) {
        if editMode?.wrappedValue == .active {
            withAnimation {
                if selectedNotificationIDs.contains(notification.id) {
                    selectedNotificationIDs.remove(notification.id)
                } else {
                    selectedNotificationIDs.insert(notification.id)
                }
            }
        } else {
            openArticle(notification)
        }
    }

    private func handleLongPressGesture(for notification: NotificationData) {
        withAnimation {
            if editMode?.wrappedValue == .inactive {
                editMode?.wrappedValue = .active
                selectedNotificationIDs.insert(notification.id)
            }
        }
    }

    private func handleScrollReset() {
        if needsScrollReset {
            scrollProxy?.scrollTo(filteredNotifications.first?.id, anchor: .top)
            needsScrollReset = false
        }
    }

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
                label: "Toggle Read",
                action: { performActionOnSelection { $0.isViewed.toggle() } }
            )
            Spacer()
            toolbarButton(
                icon: "bookmark",
                label: "Bookmark",
                action: { performActionOnSelection { toggleBookmark($0) } }
            )
            Spacer()
            toolbarButton(
                icon: "archivebox",
                label: "Archive",
                action: { performActionOnSelection { toggleArchive($0) } }
            )
            Spacer()
            toolbarButton(
                icon: "trash",
                label: "Delete",
                action: { handleEditModeDelete() },
                isDestructive: true
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(15, corners: [.topLeft, .topRight])
        .shadow(radius: 10)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void, isDestructive: Bool = false) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10))
            }
        }
        .foregroundColor(isDestructive ? .red : .primary)
        .frame(minWidth: 60)
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

    private func updateFilteredNotifications() {
        filteredNotifications = allNotifications.filter { notification in
            let topicCondition = selectedTopic == "All" || notification.topic == selectedTopic
            let archivedCondition = showArchivedContent || !notification.isArchived
            let unreadCondition = !showUnreadOnly || !notification.isViewed
            let bookmarkedCondition = !showBookmarkedOnly || notification.isBookmarked
            return topicCondition && archivedCondition && unreadCondition && bookmarkedCondition
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

    private func openArticle(_ notification: NotificationData) {
        let detailView = NewsDetailView(notification: notification)
            .environment(\.modelContext, modelContext)
        let hostingController = UIHostingController(rootView: detailView)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            rootViewController.present(hostingController, animated: true, completion: nil)
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
        notification.isArchived.toggle()
        saveChanges()
        updateFilteredNotifications()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()
        } catch {
            print("Failed to save changes: \(error)")
        }
    }

    private func rowContent(for notification: NotificationData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let topic = notification.topic,
                   !topic.isEmpty
                {
                    TopicPill(topic: topic)
                }
                if notification.isArchived {
                    ArchivedPill()
                }
            }
            .padding(.horizontal, 10)

            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(.primary)
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            if !notification.article_title.isEmpty {
                Text(notification.article_title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
            }
            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.system(size: 14, weight: .light))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 18)
            }
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
}

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

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

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
