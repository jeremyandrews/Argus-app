import SwiftUI
import SwiftData

struct TopicStatistic: Identifiable {
    var id: String { topic }
    let topic: String
    let totalCount: Int
    let unreadCount: Int
    let bookmarkedCount: Int
}

class TopicDiagnosticViewModel: ObservableObject {
    @Published var statistics: [TopicStatistic] = []
    @Published var isLoading = false
    @Published var totalArticleCount = 0
    
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
}

struct TopicDiagnosticView: View {
    @StateObject var viewModel = TopicDiagnosticViewModel()
    
    var body: some View {
        VStack {
            HStack {
                Text("Topic Statistics")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: {
                    Task {
                        await viewModel.refreshStatistics()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
            }
            .padding()
            
            if viewModel.isLoading {
                ProgressView("Gathering statistics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section(header: 
                        HStack {
                            Text("Topic").bold().frame(width: 110, alignment: .leading)
                            Spacer()
                            Text("Total").bold().frame(width: 50, alignment: .trailing)
                            Text("Unread").bold().frame(width: 60, alignment: .trailing)
                            Text("Bookmarked").bold().frame(width: 80, alignment: .trailing)
                        }
                    ) {
                        ForEach(viewModel.statistics) { stat in
                            HStack {
                                Text(stat.topic)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 110, alignment: .leading)
                                Spacer()
                                Text("\(stat.totalCount)")
                                    .frame(width: 50, alignment: .trailing)
                                Text("\(stat.unreadCount)")
                                    .foregroundColor(stat.unreadCount > 0 ? .blue : .gray)
                                    .frame(width: 60, alignment: .trailing)
                                Text("\(stat.bookmarkedCount)")
                                    .foregroundColor(stat.bookmarkedCount > 0 ? .orange : .gray)
                                    .frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                    
                    Section {
                        Text("Total articles: \(viewModel.totalArticleCount)")
                            .font(.headline)
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
    }
}

#Preview {
    NavigationView {
        TopicDiagnosticView()
    }
}
