import SwiftData
import SwiftUI

struct TopicStatistic: Identifiable {
    var id: String { topic }
    let topic: String
    let totalCount: Int
    let unreadCount: Int
    let bookmarkedCount: Int
    
    // New filtered fields (based on current quality filter)
    let filteredTotalCount: Int
    let filteredUnreadCount: Int
    let filteredBookmarkedCount: Int
}

class TopicDiagnosticViewModel: ObservableObject {
    @Published var statistics: [TopicStatistic] = []
    @Published var isLoading = false
    @Published var totalArticleCount = 0
    @Published var isMarkingAsRead: Set<String> = []

    func refreshStatistics() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            let stats = try await ArticleService.shared.getTopicStatistics()
            let total = try await ArticleService.shared.getTotalArticleCount()

            await MainActor.run {
                self.statistics = stats
                self.totalArticleCount = total
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                AppLogger.database.error("❌ Failed to load topic statistics: \(error)")
            }
        }
    }
    
    func markAllAsRead(forTopic topic: String) async {
        _ = await MainActor.run {
            isMarkingAsRead.insert(topic)
        }
        
        do {
            let markedCount = try await ArticleService.shared.markAllArticlesAsRead(forTopic: topic)
            AppLogger.database.info("Marked \(markedCount) articles as read in topic '\(topic)'")
            
            // Refresh statistics to show updated counts
            await refreshStatistics()
        } catch {
            AppLogger.database.error("❌ Failed to mark articles as read for topic '\(topic)': \(error)")
        }
        
        _ = await MainActor.run {
            isMarkingAsRead.remove(topic)
        }
    }
}

struct TopicDiagnosticView: View {
    @StateObject var viewModel = TopicDiagnosticViewModel()
    @State private var showingConfirmationAlert = false
    @State private var topicToMarkAsRead: String = ""
    
    // Get current quality filter for display
    private var currentQualityFilter: String {
        UserDefaults.standard.qualityFilter
    }

    var body: some View {
        VStack {
            if viewModel.isLoading {
                ProgressView("Gathering statistics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Enhanced header with sections
                            HStack(spacing: 0) {
                                // Topic column
                                Text("Topic")
                                    .bold()
                                    .frame(width: 120, alignment: .leading)
                                    .padding(.trailing, 8)
                                
                                // All Content section
                                VStack {
                                    Text("All Content")
                                        .bold()
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    HStack(spacing: 0) {
                                        Text("Total")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 50, alignment: .trailing)
                                        Text("Unread")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 60, alignment: .trailing)
                                        Text("Bookmarked")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 80, alignment: .trailing)
                                    }
                                }
                                .padding(.trailing, 16)
                                
                                // Filtered Content section
                                VStack {
                                    Text("Filtered (\(currentQualityFilter))")
                                        .bold()
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    HStack(spacing: 0) {
                                        Text("Total")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 50, alignment: .trailing)
                                        Text("Unread")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 60, alignment: .trailing)
                                        Text("Bookmarked")
                                            .bold()
                                            .font(.caption2)
                                            .frame(width: 80, alignment: .trailing)
                                    }
                                }
                                .padding(.trailing, 16)
                                
                                // Action column
                                Text("Action")
                                    .bold()
                                    .font(.caption2)
                                    .frame(width: 80, alignment: .center)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.systemGray6))
                            
                            Divider()
                            
                            // Data rows
                            LazyVStack(spacing: 0) {
                                ForEach(viewModel.statistics) { stat in
                                    HStack(spacing: 0) {
                                        // Topic
                                        Text(stat.topic)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 120, alignment: .leading)
                                            .padding(.trailing, 8)
                                        
                                        // All Content columns
                                        HStack(spacing: 0) {
                                            Text("\(stat.totalCount)")
                                                .frame(width: 50, alignment: .trailing)
                                            Text("\(stat.unreadCount)")
                                                .foregroundColor(stat.unreadCount > 0 ? .blue : .gray)
                                                .frame(width: 60, alignment: .trailing)
                                            Text("\(stat.bookmarkedCount)")
                                                .foregroundColor(stat.bookmarkedCount > 0 ? .orange : .gray)
                                                .frame(width: 80, alignment: .trailing)
                                        }
                                        .padding(.trailing, 16)
                                        
                                        // Filtered Content columns
                                        HStack(spacing: 0) {
                                            Text("\(stat.filteredTotalCount)")
                                                .foregroundColor(.secondary)
                                                .frame(width: 50, alignment: .trailing)
                                            Text("\(stat.filteredUnreadCount)")
                                                .foregroundColor(stat.filteredUnreadCount > 0 ? .blue : .gray)
                                                .frame(width: 60, alignment: .trailing)
                                            Text("\(stat.filteredBookmarkedCount)")
                                                .foregroundColor(stat.filteredBookmarkedCount > 0 ? .orange : .gray)
                                                .frame(width: 80, alignment: .trailing)
                                        }
                                        .padding(.trailing, 16)
                                        
                                        // Action button
                                        Button(action: {
                                            if stat.unreadCount > 0 {
                                                topicToMarkAsRead = stat.topic
                                                showingConfirmationAlert = true
                                            }
                                        }) {
                                            if viewModel.isMarkingAsRead.contains(stat.topic) {
                                                ProgressView()
                                                    .scaleEffect(0.7)
                                            } else {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(stat.unreadCount > 0 ? .blue : .gray)
                                            }
                                        }
                                        .disabled(stat.unreadCount == 0 || viewModel.isMarkingAsRead.contains(stat.topic))
                                        .frame(width: 80, alignment: .center)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    
                                    if stat.id != viewModel.statistics.last?.id {
                                        Divider()
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            // Total count section
                            HStack {
                                Text("Total articles: \(viewModel.totalArticleCount)")
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .frame(minWidth: 550) // Ensure minimum width for horizontal scrolling
                    }
                }
            }
        }
        .onAppear {
            Task {
                await viewModel.refreshStatistics()
            }
        }
        .navigationTitle("Topic Statistics")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task {
                        await viewModel.refreshStatistics()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .alert("Mark All as Read", isPresented: $showingConfirmationAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Mark as Read", role: .destructive) {
                Task {
                    await viewModel.markAllAsRead(forTopic: topicToMarkAsRead)
                }
            }
        } message: {
            if let stat = viewModel.statistics.first(where: { $0.topic == topicToMarkAsRead }) {
                Text("Mark all \(stat.unreadCount) unread articles in '\(topicToMarkAsRead)' as read?")
            }
        }
    }
}

#Preview {
    NavigationView {
        TopicDiagnosticView()
    }
}
