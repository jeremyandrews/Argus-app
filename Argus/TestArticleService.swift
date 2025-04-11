import Foundation
import SwiftData
import SwiftUI

/// A service to verify SwiftData persistence with the new ArticleModel, SeenArticleModel, and TopicModel classes
class TestArticleService: ObservableObject {
    private let modelContext: ModelContext
    private let modelContainer: ModelContainer

    @Published var testStatus: String = "Not tested"
    @Published var errorMessage: String? = nil

    // Performance metrics
    @Published var lastOperationDuration: TimeInterval = 0
    @Published var lastOperationDate: Date? = nil
    @Published var lastOperationArticleCount: Int = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        modelContainer = SwiftDataContainer.shared.container
        AppLogger.database.debug("TestArticleService initialized")
    }

    /// Creates a test article to verify persistence
    @MainActor
    func createTestArticle() async -> Bool {
        do {
            // Create a test topic
            let topic = TopicModel(
                name: "Test Topic",
                priority: .normal,
                notificationsEnabled: true
            )

            // Create a test article
            let article = ArticleModel(
                id: UUID(),
                jsonURL: "https://test.example.com/articles/test.json",
                title: "Test Article Title",
                body: "This is a test article body text.",
                articleTitle: "Full Test Article Title",
                affected: "Test Users",
                publishDate: Date(),
                topic: "Test Topic"
            )

            // Associate the article with the topic
            article.topics = [topic]

            // Save the article to SwiftData
            modelContext.insert(topic)
            modelContext.insert(article)

            // Create a test SeenArticle
            let seenArticle = SeenArticleModel(
                id: article.id,
                jsonURL: article.jsonURL
            )
            modelContext.insert(seenArticle)

            try modelContext.save()

            AppLogger.database.debug("Test articles created successfully")
            testStatus = "Test article created successfully with ID: \(article.id)"
            return true

        } catch {
            AppLogger.database.error("Failed to create test article: \(error)")
            testStatus = "Test failed"
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a batch of random test articles to better simulate real syncing
    func createBatchTestArticles() async -> (Int, TimeInterval) {
        let startTime = Date()
        let articlesCount = Int.random(in: 1 ... 10)
        let topicsCount = min(3, Int.random(in: 1 ... articlesCount))

        do {
            // Create a dedicated background context for database operations
            let backgroundContext = ModelContext(modelContainer)

            // Use Task to ensure we're not on the main thread
            return await Task.detached {
                // Log operation start with diagnostics
                AppLogger.database.debug("📊 Starting batch creation of \(articlesCount) articles with \(topicsCount) topics")

                // 1. Create random topics first
                let topics = (0 ..< topicsCount).map { i in
                    TopicModel(
                        name: "Test Topic \(i + 1)",
                        priority: Bool.random() ? .high : .normal,
                        notificationsEnabled: Bool.random()
                    )
                }

                // Insert all topics
                for topic in topics {
                    backgroundContext.insert(topic)
                }

                // Save topics first
                do {
                    let topicSaveStart = Date()
                    try backgroundContext.save()
                    let topicSaveDuration = Date().timeIntervalSince(topicSaveStart)
                    AppLogger.database.debug("📊 Saved \(topicsCount) topics in \(String(format: "%.3f", topicSaveDuration))s")
                } catch {
                    AppLogger.database.error("📊 Failed to save topics: \(error)")

                    // Update UI on main thread
                    await MainActor.run {
                        self.testStatus = "Failed to save topics"
                        self.errorMessage = error.localizedDescription
                        self.lastOperationDuration = Date().timeIntervalSince(startTime)
                        self.lastOperationDate = Date()
                        self.lastOperationArticleCount = 0
                    }
                    return (0, Date().timeIntervalSince(startTime))
                }

                // 2. Create random articles with varied content
                var articles: [ArticleModel] = []

                // Create articles in smaller batches (5 at a time) with intermediate saves
                let batchSize = 5
                for batchIndex in 0 ..< (articlesCount + batchSize - 1) / batchSize {
                    let startIndex = batchIndex * batchSize
                    let endIndex = min(startIndex + batchSize, articlesCount)
                    AppLogger.database.debug("📊 Creating articles batch \(startIndex)-\(endIndex - 1)")

                    let batchStartTime = Date()

                    for i in startIndex ..< endIndex {
                        // Create article with random content and varied properties
                        let article = ArticleModel(
                            id: UUID(),
                            jsonURL: "https://test.example.com/articles/batch-\(UUID().uuidString).json",
                            title: "Test Article \(i + 1)",
                            body: "This is test article \(i + 1) with random content length: " +
                                String(repeating: "Content ", count: Int.random(in: 5 ... 20)),
                            articleTitle: "Full Test Article Title \(i + 1)",
                            affected: "Test Users Group \(i % 3 + 1)",
                            publishDate: Date().addingTimeInterval(-Double(i * 3600)), // Varied publish dates
                            topic: topics[i % topicsCount].name
                        )

                        // Randomly assign 1-3 topics to each article
                        let topicCount = min(topicsCount, Int.random(in: 1 ... 3))
                        let selectedTopics = Array(topics.shuffled().prefix(topicCount))
                        article.topics = selectedTopics

                        backgroundContext.insert(article)
                        articles.append(article)
                    }

                    // Create SeenArticle records for half the articles in this batch (random selection)
                    for article in articles.suffix(endIndex - startIndex).shuffled().prefix((endIndex - startIndex) / 2) {
                        let seenArticle = SeenArticleModel(
                            id: article.id,
                            jsonURL: article.jsonURL
                        )
                        backgroundContext.insert(seenArticle)
                    }

                    // Save this batch
                    do {
                        let batchSaveStart = Date()
                        try backgroundContext.save()
                        let batchSaveDuration = Date().timeIntervalSince(batchSaveStart)
                        let totalBatchDuration = Date().timeIntervalSince(batchStartTime)
                        AppLogger.database.debug("📊 Saved batch \(batchIndex + 1) in \(String(format: "%.3f", batchSaveDuration))s (total batch time: \(String(format: "%.3f", totalBatchDuration))s)")
                    } catch {
                        AppLogger.database.error("📊 Failed to save batch \(batchIndex + 1): \(error)")

                        // Update UI on main thread
                        let articlesCreatedSoFar = articles.count
                        await MainActor.run {
                            self.testStatus = "Failed to save batch \(batchIndex + 1)"
                            self.errorMessage = error.localizedDescription
                            self.lastOperationDuration = Date().timeIntervalSince(startTime)
                            self.lastOperationDate = Date()
                            self.lastOperationArticleCount = articlesCreatedSoFar
                        }
                        return (articlesCreatedSoFar, Date().timeIntervalSince(startTime))
                    }
                }

                let duration = Date().timeIntervalSince(startTime)
                let perArticleTime = duration / Double(articlesCount)

                // Log detailed performance metrics
                AppLogger.database.debug("📊 Batch created \(articlesCount) articles with \(topicsCount) topics in \(String(format: "%.3f", duration))s")
                AppLogger.database.debug("📊 Average time per article: \(String(format: "%.3f", perArticleTime))s")
                AppLogger.database.debug("📊 Theoretical time for 100 articles: \(String(format: "%.3f", perArticleTime * 100))s")
                AppLogger.database.debug("📊 Theoretical time for 500 articles: \(String(format: "%.3f", perArticleTime * 500))s")

                // Update UI on main thread
                await MainActor.run {
                    self.testStatus = "Created \(articlesCount) articles with \(topicsCount) topics in \(String(format: "%.3f", duration))s (\(String(format: "%.3f", perArticleTime))s per article)"
                    self.lastOperationDuration = duration
                    self.lastOperationDate = Date()
                    self.lastOperationArticleCount = articlesCount
                }

                return (articlesCount, duration)
            }.value
        }
        // Task.detached doesn't throw errors itself, they're handled within the task
    }

    /// Retrieves all test articles to verify querying
    /// - Note: This method is isolated to the MainActor since it returns non-Sendable ArticleModel objects
    @MainActor
    func fetchAllArticles() async -> [ArticleModel] {
        do {
            let descriptor = FetchDescriptor<ArticleModel>()
            let articles = try modelContext.fetch(descriptor)

            AppLogger.database.debug("Fetched \(articles.count) articles from SwiftData")
            testStatus = "Retrieved \(articles.count) articles"
            return articles

        } catch {
            AppLogger.database.error("Failed to fetch articles: \(error)")
            testStatus = "Fetch failed"
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Retrieves all test topics to verify querying
    /// - Note: This method is isolated to the MainActor since it returns non-Sendable TopicModel objects
    @MainActor
    func fetchAllTopics() async -> [TopicModel] {
        do {
            let descriptor = FetchDescriptor<TopicModel>()
            let topics = try modelContext.fetch(descriptor)

            AppLogger.database.debug("Fetched \(topics.count) topics from SwiftData")
            testStatus = "Retrieved \(topics.count) topics"
            return topics

        } catch {
            AppLogger.database.error("Failed to fetch topics: \(error)")
            testStatus = "Fetch failed"
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Cleans up test data
    /// - Note: This method is isolated to the MainActor since it uses modelContext operations
    @MainActor
    func cleanupTestData() async -> Bool {
        do {
            // Delete all test articles
            let articlesDescriptor = FetchDescriptor<ArticleModel>(
                predicate: #Predicate { article in
                    article.jsonURL.contains("test.example.com")
                }
            )
            let articles = try modelContext.fetch(articlesDescriptor)

            for article in articles {
                modelContext.delete(article)
            }

            // Delete all test topics
            let topicsDescriptor = FetchDescriptor<TopicModel>(
                predicate: #Predicate { topic in
                    topic.name.contains("Test Topic")
                }
            )
            let topics = try modelContext.fetch(topicsDescriptor)

            for topic in topics {
                modelContext.delete(topic)
            }

            // Delete all test seen articles
            let seenArticlesDescriptor = FetchDescriptor<SeenArticleModel>(
                predicate: #Predicate { seenArticle in
                    seenArticle.jsonURL.contains("test.example.com")
                }
            )
            let seenArticles = try modelContext.fetch(seenArticlesDescriptor)

            for seenArticle in seenArticles {
                modelContext.delete(seenArticle)
            }

            try modelContext.save()

            AppLogger.database.debug("Test data cleanup successful")
            testStatus = "Test data cleaned up successfully"
            return true

        } catch {
            AppLogger.database.error("Failed to clean up test data: \(error)")
            testStatus = "Cleanup failed"
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// A simple view for testing the SwiftData implementation
struct TestArticleView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var testService: TestArticleService

    @State private var testResults: [String] = []
    @State private var isLoading = false
    @State private var showPerformanceMetrics = false

    init() {
        // Create the service with the model context
        _testService = StateObject(wrappedValue: TestArticleService(modelContext: ModelContext(SwiftDataContainer.shared.container)))
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("SwiftData Test Results")) {
                    if isLoading {
                        ProgressView()
                            .padding()
                    } else {
                        ForEach(testResults, id: \.self) { result in
                            Text(result)
                        }
                    }
                }

                if showPerformanceMetrics && testService.lastOperationDate != nil {
                    Section(header: Text("Performance Metrics")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last operation: \(testService.lastOperationDate?.formatted(date: .omitted, time: .standard) ?? "N/A")")
                            Text("Duration: \(String(format: "%.3f", testService.lastOperationDuration))s")
                            if testService.lastOperationArticleCount > 0 {
                                Text("Articles created: \(testService.lastOperationArticleCount)")
                                Text("Time per article: \(String(format: "%.3f", testService.lastOperationDuration / Double(testService.lastOperationArticleCount)))s")
                                Text("Theoretical time for 100 articles: \(String(format: "%.1f", (testService.lastOperationDuration / Double(testService.lastOperationArticleCount)) * 100))s")
                                Text("Theoretical time for 500 articles: \(String(format: "%.1f", (testService.lastOperationDuration / Double(testService.lastOperationArticleCount)) * 500))s")
                            }
                        }
                        .font(.footnote)
                    }
                }

                Section {
                    Button("Create Test Article") {
                        runTest {
                            let success = await testService.createTestArticle()
                            return "Create Test Article: \(success ? "✅ Success" : "❌ Failed")"
                        }
                    }

                    Button("Create Random Batch (1-10 Articles)") {
                        runTest {
                            let (count, duration) = await testService.createBatchTestArticles()
                            self.showPerformanceMetrics = true
                            return "Created \(count) articles in \(String(format: "%.3f", duration))s (\(String(format: "%.3f", count > 0 ? duration / Double(count) : 0))s per article)"
                        }
                    }

                    Button("Fetch Articles") {
                        runTest {
                            let articles = await testService.fetchAllArticles()
                            return "Fetch Articles: Found \(articles.count) articles"
                        }
                    }

                    Button("Fetch Topics") {
                        runTest {
                            let topics = await testService.fetchAllTopics()
                            return "Fetch Topics: Found \(topics.count) topics"
                        }
                    }

                    Button("Clean Up Test Data") {
                        runTest {
                            let success = await testService.cleanupTestData()
                            return "Clean Up Test Data: \(success ? "✅ Success" : "❌ Failed")"
                        }
                    }
                }

                if let error = testService.errorMessage {
                    Section(header: Text("Error")) {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("SwiftData Test")
        }
    }

    private func runTest(_ operation: @escaping () async -> String) {
        isLoading = true

        Task {
            let result = await operation()
            testResults.insert(result, at: 0)
            isLoading = false
        }
    }
}

#Preview {
    TestArticleView()
        .modelContainer(SwiftDataContainer.shared.container)
}
