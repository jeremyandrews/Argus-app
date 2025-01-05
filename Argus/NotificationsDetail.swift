import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Parse and display the title
            let attributedTitle = SwiftyMarkdown(string: notification.title).attributedString()
            Text(AttributedString(attributedTitle))
                .font(.title)
                .bold()

            // Parse and display the body
            let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
            Text(AttributedString(attributedBody))
                .font(.body)

            // Display the notification date
            Text(notification.date, style: .time)
                .font(.footnote)
                .foregroundColor(.gray)

            Spacer()
        }
        .padding()
        .navigationTitle("Detail")
    }

    private func updateBadgeCount() {
        let unviewedCount = (try? modelContext.fetch(
            FetchDescriptor<NotificationData>(
                predicate: #Predicate { $0.isViewed == false }
            )
        ))?.count ?? 0

        UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }
}
