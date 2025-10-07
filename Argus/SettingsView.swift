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
                    .id("settingsListTop")

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

                    VStack(alignment: .leading) {
                        Toggle("Show Unread Count on App Icon", isOn: $showBadge)

                        Text("When enabled, a red badge showing the number of unread articles appears on the Argus app icon. This count excludes archived articles.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                    }
                } header: {
                    Text("Display Preferences")
                }

                // Text Display Customization Section - Compact Design
                Section {
                    VStack(alignment: .leading, spacing: 15) {
                        // Quick Presets - Visual Cards
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick Presets")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(TextDisplayPreset.presets, id: \.name) { preset in
                                        PresetCardView(
                                            preset: preset,
                                            isSelected: isPresetSelected(preset),
                                            onTap: {
                                                textDisplaySettings = preset.settings
                                                saveTextDisplaySettings()
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 1)
                            }
                        }
                        
                        // Preview Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sample Article Title")
                                    .font(textDisplaySettings.font)
                                    .foregroundColor(textDisplaySettings.fontColor.color)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(textDisplaySettings.backgroundColor.color)
                                    .cornerRadius(6)
                                
                                Text("This is sample article text to preview your font and color settings.")
                                    .font(textDisplaySettings.descriptionFont)
                                    .foregroundColor(textDisplaySettings.fontColor.color.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(textDisplaySettings.backgroundColor.color)
                                    .cornerRadius(6)
                            }
                        }
                        
                        // Font Settings - Compact Layout
                        VStack(alignment: .leading, spacing: 12) {
                            // Font Family - Use menu picker for more options
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Font Family")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Menu {
                                    ForEach(FontFamily.allCases, id: \.self) { family in
                                        Button(family.displayName) {
                                            textDisplaySettings.fontFamily = family
                                            saveTextDisplaySettings()
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(textDisplaySettings.fontFamily.displayName)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(8)
                                }
                            }
                            
                            // Font Size and Weight in HStack
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Size")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    
                                    Picker("Font Size", selection: $textDisplaySettings.fontSize) {
                                        ForEach(FontSize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onChange(of: textDisplaySettings.fontSize) { _, _ in
                                        saveTextDisplaySettings()
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Weight")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    
                                    Picker("Font Weight", selection: $textDisplaySettings.fontWeight) {
                                        ForEach(FontWeight.allCases, id: \.self) { weight in
                                            Text(weight.displayName).tag(weight)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: textDisplaySettings.fontWeight) { _, _ in
                                        saveTextDisplaySettings()
                                    }
                                }
                            }
                        }
                        
                        // Color Settings - Compact Grid
                        HStack(spacing: 16) {
                            // Background Colors
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Background")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
                                    ForEach(BackgroundColorOption.allCases, id: \.self) { option in
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(option.color)
                                            .frame(height: 24)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(textDisplaySettings.backgroundColor == option ? Color.blue : Color.secondary.opacity(0.3), lineWidth: textDisplaySettings.backgroundColor == option ? 2 : 1)
                                            )
                                            .onTapGesture {
                                                textDisplaySettings.backgroundColor = option
                                                saveTextDisplaySettings()
                                            }
                                    }
                                }
                            }
                            
                            // Font Colors
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Text Color")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
                                    ForEach(FontColorOption.allCases, id: \.self) { option in
                                        Circle()
                                            .fill(option.color)
                                            .frame(height: 24)
                                            .overlay(
                                                Circle()
                                                    .stroke(textDisplaySettings.fontColor == option ? Color.blue : Color.secondary.opacity(0.3), lineWidth: textDisplaySettings.fontColor == option ? 2 : 1)
                                            )
                                            .onTapGesture {
                                                textDisplaySettings.fontColor = option
                                                saveTextDisplaySettings()
                                            }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Text Display")
                }

                // Phase 3.1: Auto-Sync Settings Interface
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // Basic cellular sync toggle
                        VStack(alignment: .leading) {
                            Toggle("Allow Sync on Cellular Data", isOn: $allowCellularSync)

                            Text("When disabled, articles will only be synchronized when connected to WiFi to save data. High-priority notifications will still be delivered immediately.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                        
                        Divider()
                        
                        // Phase 3.1: Streamlined Auto-Sync Controls
                        AutoSyncControlsView()
                    }
                } header: {
                    Text("Synchronization")
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
