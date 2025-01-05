import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Display formatted title
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.title)
                .bold()

            // Display formatted body
            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.body)

            // Display timestamp with "HH:MM:SS"
            Text(notification.date, format: .dateTime.hour().minute().second())
                .font(.footnote)
                .foregroundColor(.gray)

            Spacer()
        }
        .padding()
        .navigationTitle("Detail")
        .onAppear {
            markAsViewed()
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
