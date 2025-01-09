import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    @State private var showUnreadOnly: Bool = false
    @State private var showBookmarkedOnly: Bool = false
    @State private var isFilterMenuPresented: Bool = false
    @State private var isEditing: Bool = false
    @State private var selectedNotifications: Set<NotificationData> = []
    @State private var showDeleteConfirmation: Bool = false
    @State private var selectedTopic: String = "All" // Current tab selection

    private var topics: [String] {
        let uniqueTopics = Set(notifications.compactMap { $0.topic }).sorted()
        return ["All"] + uniqueTopics
    }

    private var filteredNotifications: [NotificationData] {
        var result = notifications

        // Filter by selected topic
        if selectedTopic != "All" {
            result = result.filter { $0.topic == selectedTopic }
        }

        // Additional filters
        if showUnreadOnly {
            result = result.filter { !$0.isViewed }
        }
        if showBookmarkedOnly {
            result = result.filter { $0.isBookmarked }
        }
        return result
    }

    var body: some View {
        NavigationView {
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

                    Button(isEditing ? "Done" : "Edit") {
                        isEditing.toggle()
                        if !isEditing {
                            selectedNotifications.removeAll()
                        }
                    }

                    Button(action: {
                        isFilterMenuPresented.toggle()
                    }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(.primary)
                            .padding(.leading, 8)
                    }
                    .sheet(isPresented: $isFilterMenuPresented) {
                        FilterView(
                            showUnreadOnly: $showUnreadOnly,
                            showBookmarkedOnly: $showBookmarkedOnly
                        )
                    }
                }
                .padding(.horizontal)

                // Tab bar for topics
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(topics, id: \.self) { topic in
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

                // Article list
                List {
                    ForEach(filteredNotifications) { notification in
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
                                NavigationLink(destination: NotificationDetailView(notification: notification)) {
                                    rowContent(for: notification)
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
                    }
                }
                .listStyle(PlainListStyle())

                // Toolbar for actions
                if isEditing && !selectedNotifications.isEmpty {
                    HStack {
                        Button(action: {
                            performActionOnSelection { $0.isViewed = true }
                        }) {
                            Image(systemName: "envelope.open.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }

                        Button(action: {
                            performActionOnSelection { $0.isViewed = false }
                        }) {
                            Image(systemName: "envelope.badge.fill")
                                .font(.title2)
                        }

                        Button(action: {
                            showDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.title2)
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemGray6))
                }
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
    }

    private func toggleSelection(_ notification: NotificationData) {
        if selectedNotifications.contains(notification) {
            selectedNotifications.remove(notification)
        } else {
            selectedNotifications.insert(notification)
        }
    }

    private func deleteSelectedNotifications() {
        withAnimation {
            for notification in selectedNotifications {
                modelContext.delete(notification)
            }
            selectedNotifications.removeAll()
            isEditing = false
            saveChanges()
        }
    }

    private func toggleBookmark(_ notification: NotificationData) {
        notification.isBookmarked.toggle()
        saveChanges()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            AppDelegate().updateBadgeCount()
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

struct FilterView: View {
    @Binding var showUnreadOnly: Bool
    @Binding var showBookmarkedOnly: Bool

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Filters")) {
                    Toggle("Unread", isOn: $showUnreadOnly)
                    Toggle("Bookmarked", isOn: $showBookmarkedOnly)
                }
            }
            .navigationTitle("Show only")
        }
    }
}
