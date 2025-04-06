import Foundation
import SwiftData
import SwiftUI

/// A service to verify SwiftData persistence with the new ArticleModel, SeenArticleModel, and TopicModel classes
@MainActor
class TestArticleService: ObservableObject {
    private let modelContext: ModelContext

    @Published var testStatus: String = "Not tested"
    @Published var errorMessage: String? = nil

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        AppLogger.database.debug("TestArticleService initialized")
    }

    /// Creates a test article to verify persistence
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

    /// Retrieves all test articles to verify querying
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

    init() {
        // Create the service with the model context
        _testService = StateObject(wrappedValue: TestArticleService(modelContext: ModelContext(ArgusApp.sharedModelContainer)))
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

                Section {
                    Button("Create Test Article") {
                        runTest {
                            let success = await testService.createTestArticle()
                            return "Create Test Article: \(success ? "✅ Success" : "❌ Failed")"
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
        .modelContainer(ArgusApp.sharedModelContainer)
}
