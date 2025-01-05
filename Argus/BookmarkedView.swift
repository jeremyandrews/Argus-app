import SwiftData
import SwiftUI

struct BookmarkedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse)
    private var allNotifications: [NotificationData]

    private var bookmarkedNotifications: [NotificationData] {
        allNotifications.filter { $0.isBookmarked }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(bookmarkedNotifications) { notification in
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
                }
                .onDelete(perform: deleteNotifications)
            }
            .navigationTitle("Bookmarked")
            .toolbar {
                EditButton()
            }
        }
    }

    private func deleteNotifications(offsets: IndexSet) {
        withAnimation {
            offsets.map { bookmarkedNotifications[$0] }.forEach(modelContext.delete)
        }
    }
}
