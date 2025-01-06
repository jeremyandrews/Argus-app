import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\ .modelContext) private var modelContext
    @Environment(\ .dismiss) private var dismiss

    var body: some View {
        VStack {
            // Top Bar with Back and Icons
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                Spacer()

                Button(action: {
                    toggleReadStatus()
                }) {
                    Image(systemName: notification.isViewed ? "envelope.open" : "envelope.badge")
                        .foregroundColor(notification.isViewed ? .blue : .red)
                }

                Button(action: {
                    toggleBookmark()
                }) {
                    Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundColor(notification.isBookmarked ? .blue : .gray)
                }

                Button(role: .destructive, action: {
                    deleteNotification()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
            .padding()

            // Scrollable Title
            ScrollView(.horizontal) {
                let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
                Text(AttributedString(attributedTitle))
                    .font(.title)
                    .bold()
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
            }
            .padding([.leading, .trailing])

            // Body
            ScrollView {
                let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                Text(AttributedString(attributedBody))
                    .font(.body)
                    .padding([.leading, .trailing])

                Text(notification.date, format: .dateTime.hour().minute().second())
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .padding([.leading, .trailing, .top])
            }

            Spacer()
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
