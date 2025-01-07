import SwiftData
import SwiftUI
import SwiftyMarkdown

struct NotificationDetailView: View {
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
                    let attributedBody = SwiftyMarkdown(string: notification.body).attributedString()
                    Text(AttributedString(attributedBody))
                        .font(.footnote)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(UIColor.systemGray6))
                        )
                        .padding([.leading, .trailing])
                }

                // Additional Content
                if isLoadingAdditionalContent {
                    ProgressView("Loading additional content...")
                        .padding()
                } else if let content = additionalContent {
                    ForEach(getSections(from: content), id: \.header) { section in
                        if section.header != "Article" { // Removed Article block
                            VStack {
                                Divider()
                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { expandedSections[section.header] ?? false },
                                        set: { expandedSections[section.header] = $0 }
                                    )
                                ) {
                                    if let markdownContent = section.content as? String {
                                        let attributedMarkdown = SwiftyMarkdown(string: markdownContent).attributedString()
                                        Text(AttributedString(attributedMarkdown))
                                            .font(.body)
                                            .padding(.top, 8)
                                    } else if section.header == "Argus Details", let technicalData = section.content as? (String, Double, Date) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Generated with \(technicalData.0) in \(String(format: "%.2f", technicalData.1)) seconds.")
                                            Text("Received from Argus at \(technicalData.2, format: .dateTime.hour().minute().second()).")
                                        }
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
        guard let jsonURL = notification.json_url, let url = URL(string: jsonURL) else { return }
        isLoadingAdditionalContent = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
                    notification.date
                )
            ),
        ]
    }

    private struct Section {
        let header: String
        let content: Any
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
                updateBadgeCount()
            } catch {
                print("Failed to mark notification as viewed: \(error)")
            }
        }
    }

    private func updateBadgeCount() {
        let unviewedCount = (try? modelContext.fetch(
            FetchDescriptor<NotificationData>(
                predicate: #Predicate { !$0.isViewed }
            )
        ))?.count ?? 0

        UNUserNotificationCenter.current().updateBadgeCount(unviewedCount) { error in
            if let error = error {
                print("Failed to set badge count: \(error)")
            }
        }
    }

    private func deleteNotification() {
        modelContext.delete(notification)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            print("Failed to delete notification: \(error)")
        }
    }
}
