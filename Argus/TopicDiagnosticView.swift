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
    
    // Computed properties for totals
    var totalAllContent: (total: Int, unread: Int, bookmarked: Int) {
        statistics.reduce((0, 0, 0)) { result, stat in
            (result.0 + stat.totalCount,
             result.1 + stat.unreadCount,
             result.2 + stat.bookmarkedCount)
        }
    }
    
    var totalFilteredContent: (total: Int, unread: Int, bookmarked: Int) {
        statistics.reduce((0, 0, 0)) { result, stat in
            (result.0 + stat.filteredTotalCount,
             result.1 + stat.filteredUnreadCount,
             result.2 + stat.filteredBookmarkedCount)
        }
    }

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
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("Gathering statistics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Header row
                        HStack(spacing: 0) {
                            // Topic column header
                            Text("Topic")
                                .font(.system(.body, design: .monospaced))
                                .bold()
                                .frame(width: 180, alignment: .leading)
                                .padding(.trailing, 12)
                            
                            // All Content - Total
                            Text("Total")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // All Content - Unread
                            Text("Unread")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // All Content - Bookmarked
                            Text("Bookmarked")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                                .padding(.trailing, 16)
                            
                            // Filtered Content - Total
                            Text("Filtered Total")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // Filtered Content - Unread
                            Text("Filtered Unread")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // Filtered Content - Bookmarked
                            Text("Filtered Bookmarked")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 120, alignment: .trailing)
                                .padding(.trailing, 16)
                            
                            // Action column header
                            Text("Action")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .center)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray6))
                        
                        Divider()
                        
                        // Data rows
                        ForEach(viewModel.statistics) { stat in
                            HStack(spacing: 0) {
                                // Topic - no truncation, let it expand naturally
                                Text(stat.topic)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 180, alignment: .leading)
                                    .padding(.trailing, 12)
                                
                                // All Content - Total
                                Text("\(stat.totalCount)")
                                    .frame(width: 60, alignment: .trailing)
                                    .padding(.trailing, 8)
                                
                                // All Content - Unread
                                Text("\(stat.unreadCount)")
                                    .foregroundColor(stat.unreadCount > 0 ? .blue : .gray)
                                    .frame(width: 70, alignment: .trailing)
                                    .padding(.trailing, 8)
                                
                                // All Content - Bookmarked
                                Text("\(stat.bookmarkedCount)")
                                    .foregroundColor(stat.bookmarkedCount > 0 ? .orange : .gray)
                                    .frame(width: 90, alignment: .trailing)
                                    .padding(.trailing, 16)
                                
                                // Filtered Content - Total
                                Text("\(stat.filteredTotalCount)")
                                    .foregroundColor(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                                    .padding(.trailing, 8)
                                
                                // Filtered Content - Unread
                                Text("\(stat.filteredUnreadCount)")
                                    .foregroundColor(stat.filteredUnreadCount > 0 ? .blue : .gray)
                                    .frame(width: 100, alignment: .trailing)
                                    .padding(.trailing, 8)
                                
                                // Filtered Content - Bookmarked
                                Text("\(stat.filteredBookmarkedCount)")
                                    .foregroundColor(stat.filteredBookmarkedCount > 0 ? .orange : .gray)
                                    .frame(width: 120, alignment: .trailing)
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
                        
                        Divider()
                        
                        // Totals row
                        HStack(spacing: 0) {
                            // "Totals" label
                            Text("TOTALS")
                                .font(.system(.headline, design: .monospaced))
                                .bold()
                                .frame(width: 180, alignment: .leading)
                                .padding(.trailing, 12)
                            
                            // All Content - Total
                            Text("\(viewModel.totalAllContent.total)")
                                .font(.headline)
                                .bold()
                                .frame(width: 60, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // All Content - Unread
                            Text("\(viewModel.totalAllContent.unread)")
                                .font(.headline)
                                .bold()
                                .foregroundColor(viewModel.totalAllContent.unread > 0 ? .blue : .gray)
                                .frame(width: 70, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // All Content - Bookmarked
                            Text("\(viewModel.totalAllContent.bookmarked)")
                                .font(.headline)
                                .bold()
                                .foregroundColor(viewModel.totalAllContent.bookmarked > 0 ? .orange : .gray)
                                .frame(width: 90, alignment: .trailing)
                                .padding(.trailing, 16)
                            
                            // Filtered Content - Total
                            Text("\(viewModel.totalFilteredContent.total)")
                                .font(.headline)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // Filtered Content - Unread
                            Text("\(viewModel.totalFilteredContent.unread)")
                                .font(.headline)
                                .bold()
                                .foregroundColor(viewModel.totalFilteredContent.unread > 0 ? .blue : .gray)
                                .frame(width: 100, alignment: .trailing)
                                .padding(.trailing, 8)
                            
                            // Filtered Content - Bookmarked
                            Text("\(viewModel.totalFilteredContent.bookmarked)")
                                .font(.headline)
                                .bold()
                                .foregroundColor(viewModel.totalFilteredContent.bookmarked > 0 ? .orange : .gray)
                                .frame(width: 120, alignment: .trailing)
                                .padding(.trailing, 16)
                            
                            // Empty action column space
                            Text("")
                                .frame(width: 80, alignment: .center)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray5))
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
