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

    private var filteredNotifications: [NotificationData] {
        var result = notifications
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
                // Header with Edit button and filters
                HStack {
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

                // Article list
                List {
                    ForEach(filteredNotifications) { notification in
                        // Updated list row gesture to toggle selection in edit mode or navigate otherwise
                        HStack {
                            if isEditing {
                                // Selection checkbox
                                Button(action: {
                                    toggleSelection(notification)
                                }) {
                                    Image(systemName: selectedNotifications.contains(notification) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 8)
                            }

                            // Row content with conditional NavigationLink
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

                            // Bookmark icon
                            Button(action: {
                                toggleBookmark(notification)
                            }) {
                                Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                                    .foregroundColor(notification.isBookmarked ? .blue : .gray)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                        .background(isEditing && selectedNotifications.contains(notification) ? Color.gray.opacity(0.2) : Color.clear)
                        .listRowBackground(notification.isViewed ? Color.clear : Color.blue.opacity(0.4))
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
        } catch {
            print("Failed to save changes: \(error)")
        }
    }

    // Helper function for row content
    private func rowContent(for notification: NotificationData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(.primary)

            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.subheadline)
                .lineLimit(2)
                .foregroundColor(.secondary)
        }
    }

    private func performActionOnSelection(action: (NotificationData) -> Void) {
        for notification in selectedNotifications {
            action(notification)
        }
        saveChanges()
        // Exit edit mode
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
