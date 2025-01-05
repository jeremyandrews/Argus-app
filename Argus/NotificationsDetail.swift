import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.title)
                .bold()

            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.body)

            Text(notification.date, format: .dateTime.hour().minute().second())
                .font(.footnote)
                .foregroundColor(.gray)

            Spacer()

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
        }
        .padding()
        .navigationTitle("Detail")
        .onAppear {
            markAsViewed()
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
}
