import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var allNotifications: [NotificationData]
    @State private var filteredNotifications: [NotificationData] = []
    @State private var showUnreadOnly: Bool = false
    @State private var showBookmarkedOnly: Bool = false
    @State private var showArchivedContent: Bool = false
    @State private var isFilterViewPresented: Bool = false
    @State private var isEditing: Bool = false
    @State private var selectedNotifications: Set<NotificationData> = []
    @State private var showDeleteConfirmation: Bool = false
    @State private var selectedTopic: String = "All"
    @State private var subscriptions: [String: Subscription] = [:]
    @State private var needsTopicReset: Bool = false
    @State private var filterViewHeight: CGFloat = 200
    @Binding var tabBarHeight: CGFloat

    private var topics: [String] {
        return visibleTopics
    }

    private var isAnyFilterActive: Bool {
        showUnreadOnly || showBookmarkedOnly || showArchivedContent
    }

    private var visibleTopics: [String] {
        let filteredNotifications = allNotifications.filter { notification in
            let archivedCondition = showArchivedContent || !notification.isArchived
            let unreadCondition = !showUnreadOnly || !notification.isViewed
            let bookmarkedCondition = !showBookmarkedOnly || notification.isBookmarked
            return archivedCondition && unreadCondition && bookmarkedCondition
        }
        let topics = Set(filteredNotifications.compactMap { $0.topic })
        return ["All"] + topics.sorted()
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

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack {
                    // Header
                    HStack {
                        Image("Argus")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                        Text("Argus")
                            .font(.largeTitle)
                            .bold()
                        Spacer()
                        if !filteredNotifications.isEmpty {
                            Button(isEditing ? "Done" : "Edit") {
                                isEditing.toggle()
                                if !isEditing {
                                    selectedNotifications.removeAll()
                                }
                            }
                        }
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

                    // Tab bar for topics
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(visibleTopics, id: \.self) { topic in
                                Button(action: {
                                    selectedTopic = topic
                                }) {
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

                    // Main content
                    if filteredNotifications.isEmpty {
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
                    } else {
                        // Article list
                        List {
                            ForEach(filteredNotifications, id: \.id) { notification in
                                HStack {
                                    if isEditing {
                                        Button(action: {
                                            toggleSelection(notification)
                                        }) {
                                            Image(systemName: selectedNotifications.contains(notification) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(.blue)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 8)
                                    }
                                    if !isEditing {
                                        rowContent(for: notification)
                                            .onTapGesture {
                                                openArticle(notification)
                                            }
                                    } else {
                                        rowContent(for: notification)
                                            .onTapGesture {
                                                toggleSelection(notification)
                                            }
                                    }
                                    Spacer()
                                    Button(action: {
                                        toggleBookmark(notification)
                                    }) {
                                        Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                                            .foregroundColor(notification.isBookmarked ? .blue : .gray)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 8)
                                .listRowBackground(isEditing && selectedNotifications.contains(notification) ? Color.blue.opacity(0.4) : notification.isViewed ? Color.clear : Color.blue.opacity(0.2))
                                .cornerRadius(8)
                                .gesture(
                                    LongPressGesture().onEnded { _ in
                                        isEditing = true
                                        selectedNotifications.insert(notification)
                                    }
                                )
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        toggleArchive(notification)
                                    } label: {
                                        Label(notification.isArchived ? "Unarchive" : "Archive", systemImage: notification.isArchived ? "tray.and.arrow.up.fill" : "archivebox")
                                    }
                                    .tint(.orange)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteNotification(notification)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete(perform: deleteNotifications)
                        }
                        .listStyle(PlainListStyle())
                        .refreshable {
                            Task {
                                await SyncManager.shared.sendRecentArticlesToServer()
                            }
                        }
                        .toolbar {
                            if isEditing {
                                ToolbarItemGroup(placement: .bottomBar) {
                                    Button(action: {
                                        performActionOnSelection { notification in
                                            notification.isViewed.toggle()
                                        }
                                        updateFilteredNotifications()
                                    }) {
                                        Label("Toggle Read", systemImage: "envelope.badge")
                                    }
                                    .labelStyle(.iconOnly)

                                    Spacer()

                                    Button(action: {
                                        performActionOnSelection { notification in
                                            toggleBookmark(notification)
                                        }
                                        updateFilteredNotifications()
                                    }) {
                                        Label("Bookmark", systemImage: "bookmark")
                                    }
                                    .labelStyle(.iconOnly)

                                    Spacer()

                                    Button(action: {
                                        performActionOnSelection { notification in
                                            toggleArchive(notification)
                                        }
                                        updateFilteredNotifications()
                                    }) {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .labelStyle(.iconOnly)

                                    Spacer()

                                    Button(action: {
                                        showDeleteConfirmation = true
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                }

                // Bottom sheet filter view
                if isFilterViewPresented {
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
            }
        }
        .onChange(of: allNotifications) { _, _ in
            updateFilteredNotifications()
        }
        .onChange(of: selectedTopic) { _, _ in
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
        .onChange(of: visibleTopics) {
            if needsTopicReset {
                if !visibleTopics.contains(selectedTopic) {
                    selectedTopic = "All"
                }
                needsTopicReset = false
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
            "Are you sure you want to delete \(selectedNotifications.count) articles?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelectedNotifications()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func toggleSelection(_ notification: NotificationData) {
        if selectedNotifications.contains(notification) {
            selectedNotifications.remove(notification)
        } else {
            selectedNotifications.insert(notification)
        }
    }

    private func openArticle(_ notification: NotificationData) {
        let detailView = NewsDetailView(notification: notification)
            .environment(\.modelContext, modelContext) // <-- inject the same context

        let hostingController = UIHostingController(rootView: detailView)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            rootViewController.present(hostingController, animated: true, completion: nil)
        }
    }

    private func deleteNotifications(at offsets: IndexSet) {
        withAnimation {
            let notificationsToDelete = offsets.map { filteredNotifications[$0] }
            for notification in notificationsToDelete {
                deleteNotification(notification)
            }
        }
    }

    private func deleteNotification(_ notification: NotificationData) {
        withAnimation {
            AppDelegate().deleteLocalJSON(notification: notification)
            modelContext.delete(notification)
            do {
                try modelContext.save()
                NotificationUtils.updateAppBadgeCount()
                // Update filteredNotifications after deletion
                updateFilteredNotifications()
            } catch {
                print("Failed to delete notification: \(error)")
            }
        }
    }

    private func deleteSelectedNotifications() {
        withAnimation {
            for notification in selectedNotifications {
                AppDelegate().deleteLocalJSON(notification: notification)
                modelContext.delete(notification)
            }
            selectedNotifications.removeAll()
            isEditing = false
            saveChanges()
            updateFilteredNotifications()
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
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(.primary)

            // Display domain if available
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }

            // Display article title
            if !notification.article_title.isEmpty {
                Text(notification.article_title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
            }

            // Display body text
            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.system(size: 14, weight: .light))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)

            // Display affected text if not empty
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
        for notification in selectedNotifications {
            action(notification)
        }
        saveChanges()
        isEditing = false
        selectedNotifications.removeAll()
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
