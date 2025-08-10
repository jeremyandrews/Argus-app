import SwiftData
import SwiftUI

// MARK: - Scroll Coordination

class ScrollCoordinator: ObservableObject {
    @Published var scrollOffset: CGFloat = 0
    private var isUpdatingFromHeader = false
    private var isUpdatingFromBody = false
    
    func updateFromHeader(_ offset: CGFloat) {
        guard !isUpdatingFromBody else { return }
        isUpdatingFromHeader = true
        scrollOffset = offset
        isUpdatingFromHeader = false
    }
    
    func updateFromBody(_ offset: CGFloat) {
        guard !isUpdatingFromHeader else { return }
        isUpdatingFromBody = true  
        scrollOffset = offset
        isUpdatingFromBody = false
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

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
    @StateObject private var scrollCoordinator = ScrollCoordinator()
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
                // Sticky header that scrolls horizontally but stays at top
                ScrollViewReader { headerProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Header row
                        HStack(spacing: 0) {
                            // Topic column header
                            Text("Topic")
                                .font(.system(.body, design: .monospaced))
                                .bold()
                                .frame(width: 120, alignment: .leading)
                                .padding(.trailing, 8)
                            
                            // All Content - Total
                            Text("Total")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            
                            // All Content - Unread
                            Text("Unread")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            
                            // All Content - Bookmarked
                            Text("Bookmarked")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            
                            Spacer().frame(width: 16)
                            
                            // Filtered Content - Total
                            Text("F-Total")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            
                            // Filtered Content - Unread
                            Text("F-Unread")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            
                            // Filtered Content - Bookmarked
                            Text("F-Bookmarked")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            
                            Spacer().frame(width: 16)
                            
                            // Action column header
                            Text("Action")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .center)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minWidth: 550)
                        .background(GeometryReader { headerGeometry in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, 
                                                 value: CGPoint(x: headerGeometry.frame(in: .named("headerScroll")).minX, y: 0))
                        })
                        .id("headerContent")
                    }
                    .coordinateSpace(name: "headerScroll")
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        scrollCoordinator.updateFromHeader(value.x)
                    }
                    .background(Color(UIColor.systemGray6))
                    .onChange(of: scrollCoordinator.scrollOffset) { _, newValue in
                        withAnimation(.none) {
                            headerProxy.scrollTo("headerContent", anchor: .leading)
                        }
                    }
                }
                
                Divider()
                
                // Scrollable content area
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { bodyProxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                            
                                // Data rows
                                ForEach(viewModel.statistics) { stat in
                                    HStack(spacing: 0) {
                                        // Topic
                                        Text(stat.topic)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 120, alignment: .leading)
                                            .padding(.trailing, 8)
                                        
                                        // All Content - Total
                                        Text("\(stat.totalCount)")
                                            .frame(width: 50, alignment: .trailing)
                                        
                                        // All Content - Unread
                                        Text("\(stat.unreadCount)")
                                            .foregroundColor(stat.unreadCount > 0 ? .blue : .gray)
                                            .frame(width: 60, alignment: .trailing)
                                        
                                        // All Content - Bookmarked
                                        Text("\(stat.bookmarkedCount)")
                                            .foregroundColor(stat.bookmarkedCount > 0 ? .orange : .gray)
                                            .frame(width: 80, alignment: .trailing)
                                        
                                        Spacer().frame(width: 16)
                                        
                                        // Filtered Content - Total
                                        Text("\(stat.filteredTotalCount)")
                                            .foregroundColor(.secondary)
                                            .frame(width: 50, alignment: .trailing)
                                        
                                        // Filtered Content - Unread
                                        Text("\(stat.filteredUnreadCount)")
                                            .foregroundColor(stat.filteredUnreadCount > 0 ? .blue : .gray)
                                            .frame(width: 60, alignment: .trailing)
                                        
                                        // Filtered Content - Bookmarked
                                        Text("\(stat.filteredBookmarkedCount)")
                                            .foregroundColor(stat.filteredBookmarkedCount > 0 ? .orange : .gray)
                                            .frame(width: 80, alignment: .trailing)
                                        
                                        Spacer().frame(width: 16)
                                        
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
                                        .frame(width: 120, alignment: .leading)
                                        .padding(.trailing, 8)
                                    
                                    // All Content - Total
                                    Text("\(viewModel.totalAllContent.total)")
                                        .font(.headline)
                                        .bold()
                                        .frame(width: 50, alignment: .trailing)
                                    
                                    // All Content - Unread
                                    Text("\(viewModel.totalAllContent.unread)")
                                        .font(.headline)
                                        .bold()
                                        .foregroundColor(viewModel.totalAllContent.unread > 0 ? .blue : .gray)
                                        .frame(width: 60, alignment: .trailing)
                                    
                                    // All Content - Bookmarked
                                    Text("\(viewModel.totalAllContent.bookmarked)")
                                        .font(.headline)
                                        .bold()
                                        .foregroundColor(viewModel.totalAllContent.bookmarked > 0 ? .orange : .gray)
                                        .frame(width: 80, alignment: .trailing)
                                    
                                    Spacer().frame(width: 16)
                                    
                                    // Filtered Content - Total
                                    Text("\(viewModel.totalFilteredContent.total)")
                                        .font(.headline)
                                        .bold()
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, alignment: .trailing)
                                    
                                    // Filtered Content - Unread
                                    Text("\(viewModel.totalFilteredContent.unread)")
                                        .font(.headline)
                                        .bold()
                                        .foregroundColor(viewModel.totalFilteredContent.unread > 0 ? .blue : .gray)
                                        .frame(width: 60, alignment: .trailing)
                                    
                                    // Filtered Content - Bookmarked
                                    Text("\(viewModel.totalFilteredContent.bookmarked)")
                                        .font(.headline)
                                        .bold()
                                        .foregroundColor(viewModel.totalFilteredContent.bookmarked > 0 ? .orange : .gray)
                                        .frame(width: 80, alignment: .trailing)
                                    
                                    Spacer().frame(width: 16)
                                    
                                    // Empty action column space
                                    Text("")
                                        .frame(width: 80, alignment: .center)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color(UIColor.systemGray5))
                            }
                            .frame(minWidth: 550)
                            .background(GeometryReader { bodyGeometry in
                                Color.clear.preference(key: ScrollOffsetPreferenceKey.self, 
                                                     value: CGPoint(x: bodyGeometry.frame(in: .named("bodyScroll")).minX, y: 0))
                            })
                            .id("bodyContent")
                        }
                        .coordinateSpace(name: "bodyScroll")
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            scrollCoordinator.updateFromBody(value.x)
                        }
                        .onChange(of: scrollCoordinator.scrollOffset) { _, newValue in
                            withAnimation(.none) {
                                bodyProxy.scrollTo("bodyContent", anchor: .leading)
                            }
                        }
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
