import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NewsDetailView: View {
    @State private var showDeleteConfirmation = false
    @State private var additionalContent: [String: Any]? = nil // State to store parsed JSON
    @State private var isLoadingAdditionalContent = false // State for loading status
    @State private var expandedSections: [String: Bool] = [
        "Article": false,
        "Summary": true,
        "Relevance": false,
        "Critical Analysis": false,
        "Logical Fallacies": false,
        "Source Analysis": false,
        "Argus Details": false,
    ]

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
            // Top Bar with Icons (Custom Toolbar)
            HStack(spacing: 16) {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.primary)
                }

                Spacer()

                Button(action: {
                    toggleReadStatus()
                }) {
                    Image(systemName: notification.isViewed ? "envelope.open" : "envelope.badge")
                        .foregroundColor(notification.isViewed ? .gray : .blue)
                }

                Button(action: {
                    toggleBookmark()
                }) {
                    Image(systemName: notification.isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundColor(notification.isBookmarked ? .blue : .gray)
                }

                Button(role: .destructive, action: {
                    showDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
            .padding()

            // Clickable Title
            if let content = additionalContent, let articleURL = content["url"] as? String, let link = URL(string: articleURL) {
                Button(action: {
                    UIApplication.shared.open(link)
                }) {
                    Text(notification.title)
                        .font(.title3)
                        .bold()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding([.leading, .trailing])
            }

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Display domain if available
                    if let domain = notification.domain, !domain.isEmpty {
                        Text(domain)
                            .font(.system(size: 14, weight: .medium)) // 3/4 the size of the title
                            .foregroundColor(.blue)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                    }

                    // Display article title
                    if !notification.article_title.isEmpty {
                        Text(notification.article_title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 10)
                    }

                    let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                    Text(AttributedString(attributedBody))
                        .font(.footnote)
                        .padding([.leading, .trailing])

                    // Display affected text if not empty
                    if !notification.affected.isEmpty {
                        Text(notification.affected)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding([.leading, .trailing, .top])
                    }
                }

                // Additional Content
                if isLoadingAdditionalContent {
                    ProgressView("Loading additional content...")
                        .padding()
                } else if let content = additionalContent {
                    ForEach(getSections(from: content), id: \ .header) { section in
                        if section.header != "Article" {
                            VStack {
                                Divider()
                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { expandedSections[section.header] ?? false },
                                        set: { expandedSections[section.header] = $0 }
                                    )
                                ) {
                                    if section.header == "Argus Details", let technicalData = section.content as? (String, Double, Date, String) {
                                        ArgusDetailsView(technicalData: technicalData)
                                    } else if let markdownContent = section.content as? String {
                                        let attributedMarkdown = SwiftyMarkdown(string: markdownContent).attributedString()
                                        Text(AttributedString(attributedMarkdown))
                                            .font(.body)
                                            .padding(.top, 8)
                                    }
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
        guard let jsonURL = notification.json_url, let url = URL(string: jsonURL) else { return }
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

    private func getSections(from json: [String: Any]) -> [Section] {
        [
            Section(header: "Article", content: json["url"] as? String ?? ""),
            Section(header: "Summary", content: json["summary"] as? String ?? ""),
            Section(header: "Relevance", content: json["relation_to_topic"] as? String ?? ""),
            Section(header: "Critical Analysis", content: json["critical_analysis"] as? String ?? ""),
            Section(header: "Logical Fallacies", content: json["logical_fallacies"] as? String ?? ""),
            Section(header: "Source Analysis", content: json["source_analysis"] as? String ?? ""),
            Section(
                header: "Argus Details",
                content: (
                    json["model"] as? String ?? "Unknown",
                    (json["elapsed_time"] as? Double) ?? 0.0,
                    notification.date,
                    json["stats"] as? String ?? "N/A"
                )
            ),
        ]
    }

    private struct Section {
        let header: String
        let content: Any
    }

    struct ArgusDetailsView: View {
        let technicalData: (String, Double, Date, String)

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Generated with \(technicalData.0) in \(String(format: "%.2f", technicalData.1)) seconds.")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                Text("Metrics:")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text(formattedStats(technicalData.3))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .padding(.leading, 16)
                Text("Received from Argus on \(technicalData.2, format: .dateTime.month(.wide).day().year().hour().minute().second()).")
            }
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(8)
        }

        private func formattedStats(_ stats: String) -> String {
            // Split the stats string by ":"
            let parts = stats.split(separator: ":").map { String($0) }

            // Ensure we have exactly 6 parts
            guard parts.count == 6 else {
                return "Invalid stats format"
            }

            // Helper to format numbers with commas
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal

            func formattedNumber(_ value: String) -> String {
                if let number = Int(value), let formatted = numberFormatter.string(from: NSNumber(value: number)) {
                    return formatted
                }
                return value
            }

            // Map the parts to their respective descriptions with formatted numbers
            let descriptions = [
                "Articles reviewed: \(formattedNumber(parts[0]))",
                "Matched: \(formattedNumber(parts[1]))",
                "Queued to review: \(formattedNumber(parts[2]))",
                "Life safety queue: \(formattedNumber(parts[3]))",
                "Matched topics queue: \(formattedNumber(parts[4]))",
                "Clients: \(formattedNumber(parts[5]))",
            ]

            // Join the descriptions with newlines for better readability
            return descriptions.joined(separator: "\n")
        }
    }

    static func formattedStats(_ stats: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        let parts = stats.split(separator: ":").map { part -> String in
            if let number = Int(part), let formatted = formatter.string(from: NSNumber(value: number)) {
                return formatted
            }
            return String(part) // Return unformatted part if conversion fails
        }

        return parts.joined(separator: ":")
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

    private func markAsViewed() {
        if !notification.isViewed {
            notification.isViewed = true
            do {
                try modelContext.save()
                AppDelegate().updateBadgeCount()
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
            AppDelegate().updateBadgeCount()
            dismiss()
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }
}
