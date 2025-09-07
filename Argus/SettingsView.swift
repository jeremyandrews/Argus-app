import SwiftUI
import UserNotifications

// MARK: - PresetCardView

struct PresetCardView: View {
    let preset: TextDisplayPreset
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Live preview of the preset
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(preset.settings.font.weight(.medium))
                    .foregroundColor(preset.settings.fontColor.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                
                Text(preset.description)
                    .font(preset.settings.descriptionFont)
                    .foregroundColor(preset.settings.fontColor.color.opacity(0.7))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 140, height: 60)
            .background(preset.settings.backgroundColor.color)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
            
            // Preset name below the preview
            Text(preset.name)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .center)
        }
        .onTapGesture {
            onTap()
        }
    }
}

struct SettingsView: View {
    @Environment(TabNavigationState.self) private var tabNavigation
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
    @State private var isAtTop: Bool = true
    @State private var textDisplaySettings: TextDisplaySettings = UserDefaults.standard.textDisplaySettings

    private var versionInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (Build \(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(autoDeleteDays == 0 ? "Disabled" : "After \(autoDeleteDays) day\(autoDeleteDays == 1 ? "" : "s")")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { Double(autoDeleteDays) },
                                set: { autoDeleteDays = Int($0) }
                            ), in: 0 ... 7, step: 1)
                            .accentColor(.blue)

                            HStack {
                                ForEach(0 ... 7, id: \.self) { mark in
                                    Text("\(mark)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                } header: {
                    Text("Storage Management")
                } footer: {
                    Text("Articles are automatically deleted after the selected timeframe. Bookmarked articles are never deleted.")
                }
                    .id("settingsListTop")

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Sort Articles By", selection: $sortOrder) {
                            Text("Newest First").tag("newest")
                            Text("Oldest First").tag("oldest")
                            Text("Bookmarked First").tag("bookmarked")
                        }
                        .pickerStyle(.menu)

                        Text(sortOrderExplanation)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Group Articles By", selection: $groupingStyle) {
                            Text("By Date").tag("date")
                            Text("By Topic").tag("topic")
                            Text("No Grouping").tag("none")
                        }
                        .pickerStyle(.menu)

                        Text(groupingExplanation)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show Badge on App Icon", isOn: $showBadge)

                        Text("Display unread article count as a red badge on the app icon.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Article Organization")
                }

                // Reading Experience Section - iOS18+ Design with Progressive Disclosure
                Section {
                    ReadingExperienceView(textDisplaySettings: $textDisplaySettings, onSettingsChanged: saveTextDisplaySettings)
                } header: {
                    Text("Reading Experience")
                }

                // Synchronization Section - iOS18+ Design
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        // Cellular Data Settings
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Allow Cellular Data", isOn: $allowCellularSync)
                            
                            Text("When disabled, articles sync only on WiFi to save data usage. Push notifications are always delivered.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Auto-Sync Controls
                        AutoSyncControlsView()
                    }
                } header: {
                    Text("Synchronization")
                } footer: {
                    Text("Control when and how articles are downloaded to your device.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use Reader Mode", isOn: $useReaderMode)

                        Text("Remove ads and distractions when viewing articles in Safari.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Web Browsing")
                } footer: {
                    Text("Reader mode may not be available for all websites.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Argus is an artificial intelligence (AI) agent designed to monitor and analyze numerous information sources. As an \"AI agent\", Argus performs tasks autonomously, making decisions based on the data it receives.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("The name \"Argus\" is inspired by Argus Panoptes, the all-seeing giant in Greek mythology, reflecting the program's ability to monitor and analyze numerous information sources.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text(versionInfo)
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
                    
                    NavigationLink(destination: SyncStatisticsView()) {
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundColor(.blue)
                            Text("Sync Statistics")
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
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Settings")
            .background(
                // Scroll position detection using geometry reader
                GeometryReader { geometry in
                    Color.clear
                        .onChange(of: geometry.frame(in: .global).minY) { _, newY in
                            // Simple heuristic: if the form is scrolled significantly, we're not at top
                            let newIsAtTop = newY > 50 // Form typically starts around 140-160, so 50 means we've scrolled up significantly
                            if newIsAtTop != isAtTop {
                                isAtTop = newIsAtTop
                                tabNavigation.updateScrollPosition(for: 2, isAtTop: newIsAtTop, scrollOffset: newY)
                            }
                        }
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: .tabScrollToTop)) { notification in
                if let tabIndex = notification.object as? Int, tabIndex == 2 {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("settingsListTop", anchor: .top)
                    }
                }
            }
            .onAppear {
                textDisplaySettings = UserDefaults.standard.textDisplaySettings
            }
            }
        }
    }
    
    private func saveTextDisplaySettings() {
        UserDefaults.standard.textDisplaySettings = textDisplaySettings
    }
    
    private func isPresetSelected(_ preset: TextDisplayPreset) -> Bool {
        return textDisplaySettings.fontFamily == preset.settings.fontFamily &&
               textDisplaySettings.fontSize == preset.settings.fontSize &&
               textDisplaySettings.fontWeight == preset.settings.fontWeight &&
               textDisplaySettings.backgroundColor == preset.settings.backgroundColor &&
               textDisplaySettings.fontColor == preset.settings.fontColor
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
