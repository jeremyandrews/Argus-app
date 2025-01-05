import SwiftData
import SwiftUI

struct NewsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    var body: some View {
        NavigationView {
            List {
                ForEach(notifications) { notification in
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
                                Text(notification.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(notification.body)
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
            .navigationTitle("News")
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
            offsets.map { notifications[$0] }.forEach(modelContext.delete)
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
