import SafariServices
import SwiftData
import SwiftUI
import SwiftyMarkdown
import WebKit

struct NewsDetailView: View {
    @State private var notifications: [NotificationData]
    @State private var currentIndex: Int
    @State private var deletedIDs: Set<UUID> = []

    private var isCurrentIndexValid: Bool {
        currentIndex >= 0 && currentIndex < notifications.count
    }

    private var currentNotification: NotificationData? {
        guard isCurrentIndexValid else { return nil }
        return notifications[currentIndex]
    }

    @State private var scrollToSection: String? = nil
    let initiallyExpandedSection: String?

    @State private var showDeleteConfirmation = false
    @State private var additionalContent: [String: Any]? = nil
    @State private var isLoadingAdditionalContent = false
    @State private var expandedSections: [String: Bool] = [
        "Article": false,
        "Summary": true,
        "Relevance": false,
        "Critical Analysis": false,
        "Logical Fallacies": false,
        "Source Analysis": false,
        "Argus Speaks": false,
        "Neural Core Stats": false,
    ]

    @State private var isSharePresented = false
    @State private var selectedSections: Set<String> = []
    @State private var articleContent: String? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(
        notifications: [NotificationData],
        currentIndex: Int,
        initiallyExpandedSection: String? = nil
    ) {
        _notifications = State(initialValue: notifications)
        _currentIndex = State(initialValue: currentIndex)
        self.initiallyExpandedSection = initiallyExpandedSection
    }

    var body: some View {
        NavigationStack {
            Group {
                if currentNotification != nil {
                    VStack(spacing: 0) {
                        topBar
                        ScrollView {
                            articleHeaderStyle
                            additionalSectionsView
                        }
                        bottomToolbar
                    }
                } else {
                    Text("Article no longer available")
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                dismiss()
                            }
                        }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                setupDeletionHandling()
                markAsViewed()
                loadAdditionalContent()
                if let section = initiallyExpandedSection {
                    expandedSections[section] = true
                }
            }
            .onChange(of: notifications) { _, _ in
                validateAndAdjustIndex()
            }
            .alert("Are you sure you want to delete this article?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteNotification()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $isSharePresented) {
                ShareSelectionView(
                    content: additionalContent,
                    notification: currentNotification ?? notifications[0],
                    selectedSections: $selectedSections,
                    isPresented: $isSharePresented
                )
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.width > 100 {
                            dismiss()
                        }
                    }
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, 8)

            Spacer()

            HStack(spacing: 32) {
                Button {
                    goToPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                }
                .disabled(!isCurrentIndexValid || currentIndex == 0)

                Button {
                    goToNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                }
                .disabled(!isCurrentIndexValid || currentIndex == notifications.count - 1)
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            toolbarButton(icon: "envelope.badge", label: "Read") {
                toggleReadStatus()
            }

            Spacer()

            toolbarButton(icon: currentNotification?.isBookmarked ?? false ? "bookmark.fill" : "bookmark", label: "Bookmark") {
                toggleBookmark()
            }

            Spacer()

            toolbarButton(icon: "square.and.arrow.up", label: "Share") {
                isSharePresented = true
            }

            Spacer()

            toolbarButton(icon: currentNotification?.isArchived ?? false ? "tray.and.arrow.up.fill" : "archivebox", label: "Archive") {
                toggleArchive()
            }

            Spacer()

            toolbarButton(icon: "trash", label: "Delete", isDestructive: true) {
                showDeleteConfirmation = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(UIColor.systemBackground))
    }

    private func toolbarButton(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(buttonColor(label: label, isDestructive: isDestructive))
            .frame(minWidth: 60)
        }
    }

    private func buttonColor(label: String, isDestructive: Bool) -> Color {
        if isDestructive {
            return .red
        }

        guard let notification = currentNotification else {
            return .primary
        }

        switch label {
        case "Read":
            return notification.isViewed ? .primary : Color.blue.opacity(0.6)
        case "Bookmark":
            return notification.isBookmarked ? .blue : .primary
        case "Archive":
            return notification.isArchived ? .orange : .primary
        default:
            return .primary
        }
    }

    // MARK: - Navigation and Safety Methods

    // SAFETY: Added validation and safe navigation
    private func validateAndAdjustIndex() {
        if !isCurrentIndexValid {
            if let targetID = currentNotification?.id,
               let newIndex = notifications.firstIndex(where: { $0.id == targetID })
            {
                currentIndex = newIndex
            } else {
                currentIndex = max(0, notifications.count - 1)
            }
        }
    }

    private func setupDeletionHandling() {
        NotificationCenter.default.addObserver(
            forName: .willDeleteArticle,
            object: nil,
            queue: .main
        ) { notification in
            guard let articleID = notification.userInfo?["articleID"] as? UUID else { return }
            deletedIDs.insert(articleID)

            if currentNotification?.id == articleID {
                tryNavigateToValidArticle()
            }
        }
    }

    private func tryNavigateToValidArticle() {
        if let currentNotification {
            let currentID = currentNotification.id
            if let newIndex = notifications.firstIndex(where: {
                $0.id != currentID && !deletedIDs.contains($0.id)
            }) {
                currentIndex = newIndex
                return
            }
        }
        dismiss()
    }

    // SAFETY: Updated navigation methods with validation
    private func goToNext() {
        guard isCurrentIndexValid else { return }
        var nextIndex = currentIndex + 1

        while nextIndex < notifications.count {
            if !deletedIDs.contains(notifications[nextIndex].id) {
                currentIndex = nextIndex
                markAsViewed()
                loadAdditionalContent()
                return
            }
            nextIndex += 1
        }
    }

    private func goToPrevious() {
        guard isCurrentIndexValid else { return }
        var prevIndex = currentIndex - 1

        while prevIndex >= 0 {
            if !deletedIDs.contains(notifications[prevIndex].id) {
                currentIndex = prevIndex
                markAsViewed()
                loadAdditionalContent()
                return
            }
            prevIndex -= 1
        }
    }

    // MARK: - Main Article Header

    private var articleHeaderStyle: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Topic pill + "Archived" pill
            HStack(spacing: 8) {
                if let notification = currentNotification {
                    if let topic = notification.topic, !topic.isEmpty {
                        TopicPill(topic: topic)
                    }

                    if notification.isArchived {
                        ArchivedPill()
                    }
                }
            }

            // Title
            if let notification = currentNotification,
               let content = additionalContent,
               let articleURLString = content["url"] as? String,
               let articleURL = URL(string: articleURLString)
            {
                Link(destination: articleURL) {
                    Text(notification.title)
                        .font(.headline)
                        .fontWeight(notification.isViewed ? .regular : .bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.blue)
                }
            } else if let notification = currentNotification {
                Text(notification.title)
                    .font(.headline)
                    .fontWeight(notification.isViewed ? .regular : .bold)
                    .foregroundColor(.primary)
            }

            // Publication Date
            if let notification = currentNotification,
               let pubDate = notification.pub_date
            {
                Text("Published: \(pubDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Body
            if let notification = currentNotification {
                let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                Text(AttributedString(attributedBody))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                // Affected (optional)
                if !notification.affected.isEmpty {
                    Text(notification.affected)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                // Domain
                if let domain = notification.domain, !domain.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(domain)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(1)

                        if let content = additionalContent {
                            QualityBadges(
                                sourcesQuality: content["sources_quality"] as? Int,
                                argumentQuality: content["argument_quality"] as? Int,
                                sourceType: content["source_type"] as? String,
                                scrollToSection: $scrollToSection
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(currentNotification?.isViewed ?? true ? Color.clear : Color.blue.opacity(0.15))
    }

    // MARK: - Additional Sections

    private var additionalSectionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingAdditionalContent {
                ProgressView("Loading additional content...")
                    .padding()
            } else if let content = additionalContent {
                ScrollViewReader { proxy in
                    ForEach(getSections(from: content), id: \.header) { section in
                        VStack {
                            Divider()

                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedSections[section.header] ?? false },
                                    set: { expandedSections[section.header] = $0 }
                                )
                            ) {
                                sectionContent(for: section)
                            } label: {
                                Text(section.header)
                                    .font(.headline)
                            }
                            .id(section.header)
                            .padding([.leading, .trailing, .top])
                        }
                    }
                    .onChange(of: scrollToSection) { _, newSection in
                        if let section = newSection {
                            expandedSections[section] = true
                            withAnimation {
                                proxy.scrollTo(section, anchor: .top)
                            }
                            scrollToSection = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleReadStatus() {
        guard let notification = currentNotification else { return }
        notification.isViewed.toggle()
        saveModel()
        NotificationUtils.updateAppBadgeCount()
    }

    private func toggleBookmark() {
        guard let notification = currentNotification else { return }
        notification.isBookmarked.toggle()
        if notification.isBookmarked {
            AppDelegate().saveJSONLocally(notification: notification)
        } else {
            AppDelegate().deleteLocalJSON(notification: notification)
        }
        saveModel()
        NotificationUtils.updateAppBadgeCount()
    }

    private func toggleArchive() {
        guard let notification = currentNotification else { return }
        let wasArchived = notification.isArchived
        notification.isArchived.toggle()
        saveModel()
        NotificationUtils.updateAppBadgeCount()

        if !wasArchived {
            if currentIndex < notifications.count - 1 {
                currentIndex += 1
                markAsViewed()
                loadAdditionalContent()
            } else {
                dismiss()
            }
        }
    }

    private func deleteNotification() {
        guard let notification = currentNotification else { return }
        AppDelegate().deleteLocalJSON(notification: notification)
        modelContext.delete(notification)
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()

            if currentIndex < notifications.count - 1 {
                currentIndex += 1
                markAsViewed()
                loadAdditionalContent()
            } else {
                dismiss()
            }
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }

    // MARK: - Helper Methods

    private func markAsViewed() {
        guard let notification = currentNotification else { return }
        if !notification.isViewed {
            notification.isViewed = true
            saveModel()
            NotificationUtils.updateAppBadgeCount()
            AppDelegate().removeNotificationIfExists(jsonURL: notification.json_url)
        }
    }

    private func loadAdditionalContent() {
        guard let notification = currentNotification else { return }

        if notification.isBookmarked {
            let localFileURL = AppDelegate().getLocalFileURL(for: notification)
            if FileManager.default.fileExists(atPath: localFileURL.path) {
                do {
                    let data = try Data(contentsOf: localFileURL)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        additionalContent = json
                        return
                    }
                } catch {
                    print("Failed to load local JSON: \(error)")
                }
            }
        }

        let jsonURL = notification.json_url
        guard let url = URL(string: jsonURL) else {
            print("Error: Invalid JSON URL \(jsonURL)")
            return
        }

        isLoadingAdditionalContent = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    additionalContent = json
                } else {
                    additionalContent = ["Error": "No valid content found."]
                }
            } catch {
                additionalContent = ["Error": "Failed to load content: \(error.localizedDescription)"]
            }
            isLoadingAdditionalContent = false
        }
    }

    private func loadArticleContent(url: String) {
        guard let url = URL(string: url) else { return }
        articleContent = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let htmlString = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.articleContent = htmlString
                    }
                }
            } catch {
                print("Failed to load article content: \(error)")
                DispatchQueue.main.async {
                    self.articleContent = "Failed to load article content. Please try again."
                }
            }
        }
    }

    private func saveModel() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save context: \(error)")
        }
    }

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections = [
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
        ]

        if let insights = json["additional_insights"] as? String, !insights.isEmpty {
            sections.append(ContentSection(header: "Argus Speaks", content: insights))
        }

        sections.append(ContentSection(
            header: "Neural Core Stats",
            content: (
                json["model"] as? String ?? "Unknown",
                (json["elapsed_time"] as? Double) ?? 0.0,
                currentNotification?.date ?? Date(),
                json["stats"] as? String ?? "N/A",
                json["system_info"] as? [String: Any]
            )
        ))

        sections.append(ContentSection(header: "Preview", content: json["url"] as? String ?? ""))

        return sections
    }

    private func sectionContent(for section: ContentSection) -> some View {
        Group {
            if section.header == "Source Analysis", let content = section.content as? String {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Article Domain:")
                            if let domain = currentNotification?.domain?.replacingOccurrences(of: "www.", with: ""),
                               !domain.isEmpty
                            {
                                Text(domain)
                                    .foregroundColor(.blue)
                                    .onTapGesture {
                                        if let url = URL(string: "https://\(domain)") {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                            }
                            Text("") // blank line for spacing
                        }
                        Spacer()
                    }

                    let processedContent = processSourceAnalysisContent(content)
                    let attributedContent = SwiftyMarkdown(string: processedContent).attributedString()
                    Text(AttributedString(attributedContent))
                }
                .font(.body)
                .padding(.top, 8)
                .textSelection(.enabled)
            } else if section.header == "Neural Core Stats", let details = section.argusDetails {
                ArgusDetailsView(data: details)
            } else if section.header == "Preview" {
                VStack {
                    if let urlString = section.content as? String, let articleURL = URL(string: urlString) {
                        SafariView(url: articleURL)
                            .frame(height: 450)
                        Button("Open in Browser") {
                            UIApplication.shared.open(articleURL)
                        }
                        .padding(.top)
                    } else {
                        Text("Invalid URL")
                            .frame(height: 450)
                    }
                }
            } else if let markdownContent = section.content as? String {
                let attributedMarkdown = SwiftyMarkdown(string: markdownContent).attributedString()
                Text(AttributedString(attributedMarkdown))
                    .font(.body)
                    .padding(.top, 8)
                    .textSelection(.enabled)
            }
        }
    }

    private func processSourceAnalysisContent(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return content }

        var pubDateIndex = -1
        for (index, line) in lines.enumerated() {
            let lowercaseLine = line.lowercased()
            if lowercaseLine.starts(with: "publication date") || lowercaseLine.starts(with: "published") {
                pubDateIndex = index
                break
            }
        }

        if pubDateIndex > 0 && pubDateIndex <= 5 {
            return lines[pubDateIndex...].joined(separator: "\n")
        }

        let firstLine = lines[0].lowercased()
        if firstLine.contains("domain") && firstLine.contains("name") {
            return lines.dropFirst(3).joined(separator: "\n")
        }

        return content
    }
}

// MARK: - Supporting Structures

struct ArgusDetailsData {
    let model: String
    let elapsedTime: Double
    let date: Date
    let stats: String
    let systemInfo: [String: Any]?
}

struct ContentSection {
    let header: String
    let content: Any

    var argusDetails: ArgusDetailsData? {
        if case let (model, elapsedTime, date, stats, systemInfo) as (String, Double, Date, String, [String: Any]?) = content {
            return ArgusDetailsData(
                model: model,
                elapsedTime: elapsedTime,
                date: date,
                stats: stats,
                systemInfo: systemInfo
            )
        }
        return nil
    }
}

struct ArgusDetailsView: View {
    let data: ArgusDetailsData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated with \(data.model) in \(String(format: "%.2f", data.elapsedTime)) seconds.")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .textSelection(.enabled)

            Text("Metrics:")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .textSelection(.enabled)

            Text(formattedStats(data.stats))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(.leading, 16)
                .textSelection(.enabled)

            if let sysInfo = data.systemInfo {
                Text("System Information:")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 8)

                if let buildInfo = sysInfo["build_info"] as? [String: Any] {
                    VStack(alignment: .leading) {
                        Text("Build Details:")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        FormatBuildInfo(buildInfo)
                    }
                    .padding(.leading, 16)
                }

                if let runtimeMetrics = sysInfo["runtime_metrics"] as? [String: Any] {
                    VStack(alignment: .leading) {
                        Text("Runtime Metrics:")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        FormatRuntimeMetrics(runtimeMetrics)
                    }
                    .padding(.leading, 16)
                }
            }

            Text("Received from Argus on \(data.date, format: .dateTime.month(.wide).day().year().hour().minute().second()).")
                .textSelection(.enabled)
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }

    private func formattedStats(_ stats: String) -> String {
        let parts = stats.split(separator: ":").map { String($0) }
        guard parts.count == 6 else {
            return "Invalid stats format"
        }

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        func formattedNumber(_ value: String) -> String {
            if let number = Int(value), let formatted = numberFormatter.string(from: NSNumber(value: number)) {
                return formatted
            }
            return value
        }

        let descriptions = [
            "Articles reviewed: \(formattedNumber(parts[0]))",
            "Matched: \(formattedNumber(parts[1]))",
            "Queued to review: \(formattedNumber(parts[2]))",
            "Life safety queue: \(formattedNumber(parts[3]))",
            "Matched topics queue: \(formattedNumber(parts[4]))",
            "Clients: \(formattedNumber(parts[5]))",
        ]

        return descriptions.joined(separator: "\n")
    }

    struct FormatBuildInfo: View {
        let buildInfo: [String: Any]

        init(_ buildInfo: [String: Any]) {
            self.buildInfo = buildInfo
        }

        var body: some View {
            VStack(alignment: .leading) {
                if let version = buildInfo["version"] as? String {
                    Text("Version: \(version)")
                }
                if let rustVersion = buildInfo["rust_version"] as? String {
                    Text("Rust: \(rustVersion)")
                }
                if let targetOs = buildInfo["target_os"] as? String {
                    Text("OS: \(targetOs)")
                }
                if let targetArch = buildInfo["target_arch"] as? String {
                    Text("Arch: \(targetArch)")
                }
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    struct FormatRuntimeMetrics: View {
        let metrics: [String: Any]

        init(_ metrics: [String: Any]) {
            self.metrics = metrics
        }

        var body: some View {
            VStack(alignment: .leading) {
                if let cpuUsage = metrics["cpu_usage_percent"] as? Double {
                    Text("CPU: \(String(format: "%.2f%%", cpuUsage))")
                }
                if let memoryTotal = metrics["memory_total_kb"] as? Int {
                    Text("Total Memory: \(formatMemory(memoryTotal))")
                }
                if let memoryUsage = metrics["memory_usage_kb"] as? Int {
                    Text("Used Memory: \(formatMemory(memoryUsage))")
                }
                if let threadCount = metrics["thread_count"] as? Int {
                    Text("Threads: \(threadCount)")
                }
                if let uptime = metrics["uptime_seconds"] as? Int {
                    Text("Uptime: \(formatUptime(uptime))")
                }
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
        }

        private func formatMemory(_ kb: Int) -> String {
            let units = ["KB", "MB", "GB", "TB"]
            var value = Double(kb)
            var unitIndex = 0

            while value >= 1024 && unitIndex < units.count - 1 {
                value /= 1024
                unitIndex += 1
            }

            return String(format: "%.2f %@", value, units[unitIndex])
        }

        private func formatUptime(_ seconds: Int) -> String {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
    }
}

struct ShareSelectionView: View {
    let content: [String: Any]?
    let notification: NotificationData
    @Binding var selectedSections: Set<String>
    @Binding var isPresented: Bool
    @State private var formatText = true
    @State private var shareItems: [Any] = []

    private var isShareSheetPresented: Binding<Bool> {
        Binding<Bool>(
            get: { !self.shareItems.isEmpty },
            set: { newValue in
                if !newValue {
                    self.shareItems = []
                    self.isPresented = false
                } else {
                    self.prepareShareContent()
                }
            }
        )
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Select the sections to share:").padding(.top)) {
                    ForEach(getSections(from: content ?? [:]), id: \.header) { section in
                        if section.header != "Article Preview" {
                            Button(action: {
                                if selectedSections.contains(section.header) {
                                    selectedSections.remove(section.header)
                                } else {
                                    selectedSections.insert(section.header)
                                }
                            }) {
                                HStack {
                                    Text(section.header)
                                    Spacer()
                                    if selectedSections.contains(section.header) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $formatText) {
                        VStack(alignment: .leading) {
                            Text("Format text")
                            Text("Some apps are unable to handle formatted text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Share Content")
            .navigationBarItems(
                leading: Button("Cancel") { isPresented = false },
                trailing: Button("Share") {
                    isShareSheetPresented.wrappedValue = true
                }
                .disabled(selectedSections.isEmpty)
            )
        }
        .sheet(isPresented: isShareSheetPresented) {
            ActivityViewController(activityItems: shareItems) { _, _, _, _ in
                isShareSheetPresented.wrappedValue = false
            }
        }
        .onAppear {
            if selectedSections.isEmpty {
                selectedSections = ["Title", "Brief Summary", "Summary", "Article URL"]
            }
        }
    }

    private func prepareShareContent() {
        var shareText = ""

        for section in getSections(from: content ?? [:]) {
            if selectedSections.contains(section.header) {
                if section.header == "Article URL" {
                    if let url = section.content as? String {
                        shareText += "\(url)\n\n"
                    }
                } else if section.header == "Title" || section.header == "Brief Summary" {
                    if let shareableContent = section.content as? String {
                        shareText += "\(shareableContent)\n\n"
                    }
                } else if section.header == "Neural Core Stats" {
                    if let details = section.argusDetails {
                        shareText += "NEURAL CORE STATS\n\n"
                        shareText += """
                        Generated with \(details.model) in \(String(format: "%.2f", details.elapsedTime)) seconds.
                        Metrics:
                        \(formattedStats(details.stats))
                        """

                        if let sysInfo = details.systemInfo {
                            shareText += "System Information:\n"
                            if let buildInfo = sysInfo["build_info"] as? [String: Any] {
                                shareText += "\nBuild Details:\n"
                                if let version = buildInfo["version"] as? String {
                                    shareText += "Version: \(version)\n"
                                }
                                if let rustVersion = buildInfo["rust_version"] as? String {
                                    shareText += "Rust: \(rustVersion)\n"
                                }
                                if let targetOs = buildInfo["target_os"] as? String {
                                    shareText += "OS: \(targetOs)\n"
                                }
                                if let targetArch = buildInfo["target_arch"] as? String {
                                    shareText += "Arch: \(targetArch)\n"
                                }
                            }

                            if let runtimeMetrics = sysInfo["runtime_metrics"] as? [String: Any] {
                                shareText += "\nRuntime Metrics:\n"
                                if let cpuUsage = runtimeMetrics["cpu_usage_percent"] as? Double {
                                    shareText += "CPU: \(String(format: "%.2f%%", cpuUsage))\n"
                                }
                                if let memoryTotal = runtimeMetrics["memory_total_kb"] as? Int {
                                    shareText += "Total Memory: \(formatMemory(memoryTotal))\n"
                                }
                                if let memoryUsage = runtimeMetrics["memory_usage_kb"] as? Int {
                                    shareText += "Used Memory: \(formatMemory(memoryUsage))\n"
                                }
                                if let threadCount = runtimeMetrics["thread_count"] as? Int {
                                    shareText += "Threads: \(threadCount)\n"
                                }
                                if let uptime = runtimeMetrics["uptime_seconds"] as? Int {
                                    shareText += "Uptime: \(formatUptime(uptime))\n"
                                }
                            }
                            shareText += "\n"
                        }

                        shareText += "Received from Argus on \(details.date.formatted(.dateTime.month(.wide).day().year().hour().minute().second()))\n\n"
                    }
                } else if section.header != "Description" {
                    shareText += "\(section.header.uppercased())\n\n"
                    if let shareableContent = section.content as? String {
                        shareText += "\(shareableContent)\n\n"
                    }
                }
            }
        }

        if formatText {
            let formattedText = SwiftyMarkdown(string: shareText).attributedString()
            shareItems = [formattedText]
        } else {
            shareItems = [shareText]
        }
    }

    private var sectionHeaders: [String] {
        getSections(from: content ?? [:]).map { $0.header }
    }

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        var sections = [
            ContentSection(header: "Title", content: json["tiny_title"] as? String ?? ""),
            ContentSection(header: "Brief Summary", content: json["tiny_summary"] as? String ?? ""),
            ContentSection(header: "Article URL", content: json["url"] as? String ?? ""),
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
        ]

        if let insights = json["additional_insights"] as? String, !insights.isEmpty {
            sections.append(ContentSection(header: "Argus Speaks", content: insights))
        }

        sections.append(ContentSection(
            header: "Neural Core Stats",
            content: (
                json["model"] as? String ?? "Unknown",
                (json["elapsed_time"] as? Double) ?? 0.0,
                notification.date,
                json["stats"] as? String ?? "N/A",
                json["system_info"] as? [String: Any]
            )
        ))

        return sections
    }

    private func formatMemory(_ kb: Int) -> String {
        let gb = Double(kb) / 1_048_576.0
        return String(format: "%.2f GB", gb)
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func formattedStats(_ stats: String) -> String {
        let parts = stats.split(separator: ":").map { String($0) }
        guard parts.count == 6 else {
            return "Invalid stats format"
        }

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        func formattedNumber(_ value: String) -> String {
            if let number = Int(value), let formatted = numberFormatter.string(from: NSNumber(value: number)) {
                return formatted
            }
            return value
        }

        let descriptions = [
            "• Articles reviewed: \(formattedNumber(parts[0]))",
            "• Matched: \(formattedNumber(parts[1]))",
            "• Queued to review: \(formattedNumber(parts[2]))",
            "• Life safety queue: \(formattedNumber(parts[3]))",
            "• Matched topics queue: \(formattedNumber(parts[4]))",
            "• Clients: \(formattedNumber(parts[5]))",
        ]

        return descriptions.joined(separator: "\n")
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: UIActivityViewController.CompletionWithItemsHandler?

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @AppStorage("useReaderMode") private var useReaderMode: Bool = true

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = useReaderMode
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
