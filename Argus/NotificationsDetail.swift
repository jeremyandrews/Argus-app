import SwiftData
import SwiftUI

struct NotificationDetailView: View {
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(notification.title)
                .font(.title)
                .bold()
            Text(notification.body)
                .font(.body)
            Text(notification.date, style: .date)
                .font(.footnote)
                .foregroundColor(.gray)
            Text(notification.date, format: .dateTime.hour().minute().second())
                .font(.footnote)
                .foregroundColor(.gray)
            Spacer()
        }
        .padding()
        .navigationTitle("Detail")
        .onAppear {
            if !notification.isViewed {
                notification.isViewed = true
                try? modelContext.save() // Persist the change
                updateBadgeCount()
            }
        }
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
