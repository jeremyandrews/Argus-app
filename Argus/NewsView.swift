import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    @State private var showBookmarkedOnly: Bool = false

    private var filteredNotifications: [NotificationData] {
        showBookmarkedOnly ? notifications.filter { $0.isBookmarked } : notifications
    }

    var body: some View {
        NavigationView {
            VStack {
                Picker("Filter", selection: $showBookmarkedOnly) {
                    Text("All News").tag(false)
                    Text("Bookmarked").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()

                List {
                    ForEach(filteredNotifications) { notification in
                        HStack {
                            // Unread indicator button
                            Button(action: {
                                toggleReadStatus(notification)
                            }) {
                                Image(systemName: notification.isViewed ? "circle" : "circle.fill")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 5)

                            // NavigationLink for the notification details
                            NavigationLink(destination: NotificationDetailView(notification: notification)) {
                                VStack(alignment: .leading) {
                                    let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                                    Text(AttributedString(attributedTitle))
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                                    Text(AttributedString(attributedBody))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)

                                    Text(notification.date, format: .dateTime.hour().minute())
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            Spacer()

                            // Bookmark button
                            Button(action: {
                                toggleBookmark(notification)
                            }) {
                                Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                                    .foregroundColor(notification.isBookmarked ? .blue : .gray)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete(perform: deleteNotifications)
                }
            }
            .navigationTitle(showBookmarkedOnly ? "Bookmarked" : "News")
            .toolbar {
                EditButton()
            }
        }
    }

    private func toggleReadStatus(_ notification: NotificationData) {
        notification.isViewed.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle read status: \(error)")
        }
    }

    private func toggleBookmark(_ notification: NotificationData) {
        notification.isBookmarked.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle bookmark: \(error)")
        }
    }

    private func deleteNotifications(offsets: IndexSet) {
        withAnimation {
            offsets.map { filteredNotifications[$0] }.forEach(modelContext.delete)
            updateBadgeCount()
        }
    }

    private func updateBadgeCount() {
        let unviewedCount = notifications.filter { !$0.isViewed }.count
        UNUserNotificationCenter.current().updateBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }
}
