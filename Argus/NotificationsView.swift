import SwiftData
import SwiftUI

struct NotificationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NotificationData.date, order: .reverse) private var notifications: [NotificationData]

    var body: some View {
        NavigationView {
            List {
                ForEach(notifications) { notification in
                    NavigationLink(destination: NotificationDetailView(notification: notification)) {
                        HStack {
                            if !notification.isViewed {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 10, height: 10)
                                    .padding(.trailing, 5)
                            }
                            VStack(alignment: .leading) {
                                Text(notification.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(notification.body)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Text(notification.date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text(notification.date, format: .dateTime.hour().minute())
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
                .onDelete(perform: deleteNotifications)
            }
            .navigationTitle("Notifications")
            .toolbar {
                EditButton()
            }
        }
        .onAppear {
            updateBadgeCount()
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

        UNUserNotificationCenter.current().setBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }
}
