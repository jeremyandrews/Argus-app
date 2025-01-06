import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    @State private var showUnreadOnly: Bool = false
    @State private var showBookmarkedOnly: Bool = false
    @State private var isFilterMenuPresented: Bool = false

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
                // Header with title and filter button
                HStack {
                    Text("Argus")
                        .font(.largeTitle)
                        .bold()
                        .padding(.bottom, 8)

                    Spacer()

                    Button(action: {
                        isFilterMenuPresented.toggle()
                    }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(.primary)
                            .padding(.bottom, 8)
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
                        HStack {
                            // Read/Unread icon
                            Button(action: {
                                toggleReadStatus(notification)
                            }) {
                                Image(systemName: notification.isViewed ? "circle" : "circle.fill")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)

                            // NavigationLink to details
                            NavigationLink(destination: NotificationDetailView(notification: notification)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    // SwiftyMarkdown formatted title
                                    let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                                    Text(AttributedString(attributedTitle))
                                        .font(.headline)
                                        .lineLimit(2)
                                        .foregroundColor(.primary)

                                    // SwiftyMarkdown formatted body
                                    let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                                    Text(AttributedString(attributedBody))
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .foregroundColor(.secondary)
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
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteNotifications)
                }
                .listStyle(PlainListStyle())
            }
        }
    }

    private func toggleReadStatus(_ notification: NotificationData) {
        notification.isViewed.toggle()
        do {
            try modelContext.save()
            updateBadgeCount() // Ensure badge count is updated
        } catch {
            print("Failed to toggle read status: \(error)")
        }
    }

    private func updateBadgeCount() {
        let unviewedCount = notifications.filter { !$0.isViewed }.count
        UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }

    private func toggleBookmark(_ notification: NotificationData) {
        notification.isBookmarked.toggle()
        saveChanges()
    }

    private func deleteNotifications(offsets: IndexSet) {
        withAnimation {
            let notificationsToDelete = offsets.map { filteredNotifications[$0] }
            notificationsToDelete.forEach(modelContext.delete)
            saveChanges()
        }
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save changes: \(error)")
        }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            scene.windows.first?.rootViewController?.dismiss(animated: true, completion: nil)
                        }
                    }
                }
            }
        }
    }
}
