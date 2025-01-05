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
            Spacer()
        }
        .padding()
        .navigationTitle("Detail")
        .onAppear {
            if !notification.isViewed {
                notification.isViewed = true
                try? modelContext.save() // Persist the change
            }
        }
    }
}
