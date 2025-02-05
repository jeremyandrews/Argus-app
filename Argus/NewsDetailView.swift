import SafariServices
import SwiftData
import SwiftUI
import SwiftyMarkdown
import WebKit

struct NewsDetailView: View {
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
        "Argus Details": false,
    ]
    @State private var isSharePresented = false
    @State private var selectedSections: Set<String> = []
    @State private var articleContent: String? = nil
    var notification: NotificationData
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    struct ContentView: View {
        var body: some View {
            ArgusDetailsView(technicalData: (
                "ArgusModel v1.0",
                0.1234,
                Date(),
                "200066:16514:419:0:0:1"
            ))
        }
    }

    // Preview
    struct ContentView_Previews: PreviewProvider {
        static var previews: some View {
            ContentView()
        }
    }

    var body: some View {
        VStack {
            topBar
            titleView
            contentScrollView
            Spacer()
        }
        .onAppear {
            markAsViewed()
            loadAdditionalContent()
        }
        .alert("Are you sure you want to delete this article?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteNotification()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isSharePresented) {
            ShareSelectionView(content: additionalContent, notification: notification, selectedSections: $selectedSections, isPresented: $isSharePresented)
        }
        .navigationBarHidden(true)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width > 100 {
                        dismiss()
                    }
                }
        )
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundColor(.primary)
            }
            Spacer()
            Button(action: { toggleReadStatus() }) {
                Image(systemName: notification.isViewed ? "envelope.open" : "envelope.badge")
                    .foregroundColor(notification.isViewed ? .gray : .blue)
            }
            Button(action: { toggleBookmark() }) {
                Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundColor(notification.isBookmarked ? .blue : .gray)
            }
            Button(action: { isSharePresented = true }) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.blue)
            }
            Button(action: { toggleArchive() }) {
                Image(systemName: notification.isArchived ? "tray.and.arrow.up.fill" : "archivebox")
                    .foregroundColor(notification.isArchived ? .orange : .gray)
            }
            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
        }
        .padding()
    }

    private var titleView: some View {
        Group {
            if let content = additionalContent, let articleURL = content["url"] as? String, let link = URL(string: articleURL) {
                Button(action: { UIApplication.shared.open(link) }) {
                    Text(notification.title)
                        .font(.title3)
                        .bold()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding([.leading, .trailing])
            }
        }
    }

    private var contentScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                domainView
                articleTitleView
                bodyContentView
                affectedTextView
                additionalContentView
            }
        }
    }

    private var domainView: some View {
        Group {
            if let domain = notification.domain, !domain.isEmpty {
                Text(domain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
        }
    }

    private var articleTitleView: some View {
        Group {
            if !notification.article_title.isEmpty {
                Text(notification.article_title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .textSelection(.enabled)
            }
        }
    }

    private var bodyContentView: some View {
        let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
        return Text(AttributedString(attributedBody))
            .font(.footnote)
            .padding([.leading, .trailing])
            .textSelection(.enabled)
    }

    private var affectedTextView: some View {
        Group {
            if !notification.affected.isEmpty {
                Text(notification.affected)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding([.leading, .trailing, .top])
                    .textSelection(.enabled)
            }
        }
    }

    private var additionalContentView: some View {
        Group {
            if isLoadingAdditionalContent {
                ProgressView("Loading additional content...")
                    .padding()
            } else if let content = additionalContent {
                ForEach(getSections(from: content), id: \.header) { section in
                    VStack {
                        Divider()
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedSections[section.header] ?? false },
                                set: {
                                    expandedSections[section.header] = $0
                                    if section.header == "Preview", $0 {
                                        loadArticleContent(url: section.content as? String ?? "")
                                    }
                                }
                            )
                        ) {
                            sectionContent(for: section)
                        } label: {
                            Text(section.header)
                                .font(.headline)
                        }
                        .padding([.leading, .trailing, .top])
                    }
                }
            }
        }
    }

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        [
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
            ContentSection(
                header: "Argus Details",
                content: (
                    json["model"] as? String ?? "Unknown",
                    (json["elapsed_time"] as? Double) ?? 0.0,
                    notification.date,
                    json["stats"] as? String ?? "N/A"
                )
            ),
            ContentSection(header: "Preview", content: json["url"] as? String ?? ""),
        ]
    }

    private func sectionContent(for section: ContentSection) -> some View {
        Group {
            if section.header == "Argus Details", let technicalData = section.content as? (String, Double, Date, String) {
                ArgusDetailsView(technicalData: technicalData)
            } else if section.header == "Preview" {
                VStack {
                    if let url = section.content as? String, let articleURL = URL(string: url) {
                        SafariView(url: articleURL)
                            .frame(height: 450)
                    } else {
                        Text("Invalid URL")
                            .frame(height: 450)
                    }
                    if let url = section.content as? String, let articleURL = URL(string: url) {
                        Button("Open in Browser") {
                            UIApplication.shared.open(articleURL)
                        }
                        .padding(.top)
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

    private func loadAdditionalContent() {
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

        // Fallback to downloading the content if not bookmarked or local file unavailable
        let jsonURL = notification.json_url // json_url is now guaranteed to be non-optional

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
        articleContent = nil // Reset content to show loading indicator
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

    private func toggleReadStatus() {
        notification.isViewed.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle read status: \(error)")
        }
    }

    private func toggleBookmark() {
        notification.isBookmarked.toggle()
        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle bookmark: \(error)")
        }
    }

    private func toggleArchive() {
        notification.isArchived.toggle()
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: Notification.Name("ArticleArchived"), object: nil)
            dismiss()
        } catch {
            print("Failed to toggle archive status: \(error)")
        }
    }

    private func markAsViewed() {
        if !notification.isViewed {
            notification.isViewed = true
            do {
                try modelContext.save()
                NotificationUtils.updateAppBadgeCount()
            } catch {
                print("Failed to mark notification as viewed: \(error)")
            }
        }
    }

    private func deleteNotification() {
        AppDelegate().deleteLocalJSON(notification: notification)
        modelContext.delete(notification)
        do {
            try modelContext.save()
            NotificationUtils.updateAppBadgeCount()
            dismiss()
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }
}

struct ContentSection {
    let header: String
    let content: Any
}

struct ArgusDetailsView: View {
    let technicalData: (String, Double, Date, String)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated with \(technicalData.0) in \(String(format: "%.2f", technicalData.1)) seconds.")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
            Text("Metrics:")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Text(formattedStats(technicalData.3))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(.leading, 16)
                .textSelection(.enabled)
            Text("Received from Argus on \(technicalData.2, format: .dateTime.month(.wide).day().year().hour().minute().second()).")
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
                selectedSections = ["Description", "Article", "Summary"]
            }
        }
    }

    private func prepareShareContent() {
        var shareText = ""
        for section in getSections(from: content ?? [:]) {
            if selectedSections.contains(section.header) && section.header != "Preview" {
                if section.header != "Description" {
                    shareText += "\(section.header.uppercased())\n\n"
                }
                if let shareableContent = section.content as? String {
                    shareText += "\(shareableContent)\n\n"
                } else if section.header == "Argus Details", let technicalData = section.content as? (String, Double, Date, String) {
                    shareText += formatArgusDetails(technicalData) + "\n\n"
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

    private func toggleSection(_ header: String) {
        if selectedSections.contains(header) {
            selectedSections.remove(header)
        } else {
            selectedSections.insert(header)
        }
    }

    private func formatArgusDetails(_ technicalData: (String, Double, Date, String)) -> String {
        let (model, elapsedTime, date, stats) = technicalData
        return """
        Generated with \(model) in \(String(format: "%.2f", elapsedTime)) seconds.
        Metrics:
        \(formattedStats(stats))
        Received from Argus on \(date.formatted(.dateTime.month(.wide).day().year().hour().minute().second()))
        """
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

    private func getSections(from json: [String: Any]) -> [ContentSection] {
        [
            ContentSection(header: "Description", content: notification.body),
            ContentSection(header: "Article", content: json["url"] as? String ?? ""),
            ContentSection(header: "Summary", content: json["summary"] as? String ?? ""),
            ContentSection(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            ContentSection(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            ContentSection(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            ContentSection(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
            ContentSection(
                header: "Argus Details",
                content: (
                    json["model"] as? String ?? "Unknown",
                    (json["elapsed_time"] as? Double) ?? 0.0,
                    notification.date,
                    json["stats"] as? String ?? "N/A"
                )
            ),
            ContentSection(header: "Article Preview", content: json["url"] as? String ?? ""),
        ]
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

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = true
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
