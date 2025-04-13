import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("autoDeleteDays") private var autoDeleteDays: Int = UserDefaults.standard.object(forKey: "autoDeleteDays") == nil ? 3 : UserDefaults.standard.integer(forKey: "autoDeleteDays")
    @AppStorage("sortOrder") private var sortOrder: String = "newest"
    @AppStorage("groupingStyle") private var groupingStyle: String = "date"
    @AppStorage("showBadge") private var showBadge: Bool = true {
        didSet {
            if showBadge {
                NotificationUtils.updateAppBadgeCount()
            } else {
                UNUserNotificationCenter.current().updateBadgeCount(0)
            }
        }
    }

    @AppStorage("useReaderMode") private var useReaderMode: Bool = true
    @AppStorage("allowCellularSync") private var allowCellularSync: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text(autoDeleteDays == 0 ? "Disabled" : "After \(autoDeleteDays) day\(autoDeleteDays == 1 ? "" : "s")")
                            .font(.headline)
                            .padding(.bottom, 5)

                        VStack(spacing: 4) {
                            Slider(value: Binding(
                                get: { Double(autoDeleteDays) },
                                set: { autoDeleteDays = Int($0) }
                            ), in: 0 ... 7, step: 1)

                            HStack {
                                ForEach(0 ... 7, id: \.self) { mark in
                                    Text("\(mark)")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 4)
                        }

                        Text("Automatically delete articles older than the selected number of days. Bookmarked or Archived articles will not be automatically deleted.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }
                } header: {
                    Text("Auto-delete Articles")
                }

                Section {
                    VStack(alignment: .leading) {
                        Picker("Sort Articles By", selection: $sortOrder) {
                            Text("Newest First").tag("newest")
                            Text("Oldest First").tag("oldest")
                            Text("Bookmarked First").tag("bookmarked")
                        }

                        Text(sortOrderExplanation)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }

                    VStack(alignment: .leading) {
                        Picker("Group Articles By", selection: $groupingStyle) {
                            Text("By Date").tag("date") // Moved to first position
                            Text("By Topic").tag("topic")
                            Text("No Grouping").tag("none")
                        }

                        Text(groupingExplanation)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }
                } header: {
                    Text("Display Preferences")
                }

                Section {
                    VStack(alignment: .leading) {
                        Toggle("Show Unread Count on App Icon", isOn: $showBadge)

                        Text("When enabled, a red badge showing the number of unread articles appears on the Argus app icon. This count excludes archived articles.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }

                    VStack(alignment: .leading) {
                        Toggle("Allow Sync on Cellular Data", isOn: $allowCellularSync)

                        Text("When disabled, articles will only be synchronized when connected to WiFi to save data. High-priority notifications will still be delivered immediately.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }
                } header: {
                    Text("Notifications")
                }

                Section {
                    VStack(alignment: .leading) {
                        Toggle("Use Reader Mode When Available", isOn: $useReaderMode)

                        Text("Reader mode removes ads and other distractions when viewing articles. Some websites may not support this feature.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }
                } header: {
                    Text("Preview")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Argus is an artificial intelligence (AI) agent designed to monitor and analyze numerous information sources. As an \"AI agent\", Argus performs tasks autonomously, making decisions based on the data it receives.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("The name \"Argus\" is inspired by Argus Panoptes, the all-seeing giant in Greek mythology, reflecting the program's ability to monitor and analyze numerous information sources.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        HStack {
                            Spacer()
                            Image("Argus")
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 40)
                                .padding(.top, 20)
                            Spacer()
                        }
                    }
                } header: {
                    Text("About Argus")
                }

                // Debug section for testing SwiftData
                Section {
                    NavigationLink(destination: TopicDiagnosticView()) {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                                .foregroundColor(.green)
                            Text("Topic Statistics")
                        }
                    }
                    .foregroundColor(.primary)

                    Button(action: {
                        Task {
                            let viewModel = NewsViewModel()
                            let removedCount = await viewModel.removeDuplicateArticles()
                            // Show alert with results
                            let message = "Successfully removed \(removedCount) duplicate articles."
                            #if os(iOS)
                                let alert = UIAlertController(title: "Cleanup Complete", message: message, preferredStyle: .alert)
                                alert.addAction(UIAlertAction(title: "OK", style: .default))
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController
                                {
                                    rootViewController.present(alert, animated: true)
                                }
                            #endif
                        }
                    }) {
                        HStack {
                            Image(systemName: "delete.left.fill")
                                .foregroundColor(.red)
                            Text("Remove Duplicate Articles")
                        }
                    }
                    .foregroundColor(.primary)

                    Text("This section provides diagnostic and maintenance tools for the application.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Debug")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var sortOrderExplanation: String {
        switch sortOrder {
        case "newest":
            return "Shows most recent articles first, with older articles below."
        case "oldest":
            return "Shows older articles first, with newer articles below."
        case "bookmarked":
            return "Shows bookmarked articles first, then sorts remaining articles by date (newest first)."
        default:
            return ""
        }
    }

    private var groupingExplanation: String {
        switch groupingStyle {
        case "none":
            return "Shows all articles in a single continuous list."
        case "date":
            return "Groups articles by their publication date, making it easier to find content from specific days."
        case "topic":
            return "Groups articles by their topic, helping you focus on specific areas of interest."
        default:
            return ""
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
