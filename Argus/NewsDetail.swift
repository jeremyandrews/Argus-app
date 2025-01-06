import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                Text(AttributedString(attributedTitle))
                    .font(.title)
                    .bold()
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                Text(AttributedString(attributedBody))
                    .font(.body)

                Text(notification.date, format: .dateTime.hour().minute().second())
                    .font(.footnote)
                    .foregroundColor(.gray)

                Button(action: {
                    toggleReadStatus()
                }) {
                    HStack {
                        Image(systemName: notification.isViewed ? "envelope.open" : "envelope.badge")
                            .foregroundColor(notification.isViewed ? .blue : .red)
                        Text(notification.isViewed ? "Mark as Unread" : "Mark as Read")
                    }
                }
                .padding()
                .buttonStyle(.bordered)

                Button(action: {
                    toggleBookmark()
                }) {
                    HStack {
                        Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundColor(notification.isBookmarked ? .blue : .gray)
                        Text(notification.isBookmarked ? "Remove Bookmark" : "Add Bookmark")
                    }
                }
                .padding()
                .buttonStyle(.bordered)

                Button(role: .destructive, action: {
                    deleteNotification()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                }
                .padding()
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("") // No title at the top navigation bar
        .onAppear {
            markAsViewed()
        }
    }

    private func toggleReadStatus() {
        notification.isViewed.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle read status: \(error)")
        }
    }

    private func toggleBookmark() {
        notification.isBookmarked.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle bookmark: \(error)")
        }
    }

    private func markAsViewed() {
        if !notification.isViewed {
            notification.isViewed = true
            do {
                try modelContext.save()
                updateBadgeCount()
            } catch {
                print("Failed to mark notification as viewed: \(error)")
            }
        }
    }

    private func updateBadgeCount() {
        let unviewedCount = (try? modelContext.fetch(
            FetchDescriptor<NotificationData>(
                predicate: #Predicate { !$0.isViewed }
            )
        ))?.count ?? 0

        UNUserNotificationCenter.current().updateBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }

    private func deleteNotification() {
        modelContext.delete(notification)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }
}
