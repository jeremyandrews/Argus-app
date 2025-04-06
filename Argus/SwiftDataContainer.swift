import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// A dedicated container for SwiftData models used in the modernization plan
/// This keeps our new models separate from the existing app infrastructure
class SwiftDataContainer {
    // A singleton instance for easier access
    static let shared = SwiftDataContainer()

    // The model container for our new models
    let container: ModelContainer

    private init() {
        // Set up the schema with our new models
        let schema = Schema([
            ArticleModel.self,
            SeenArticleModel.self,
            TopicModel.self,
        ])

        // Configure the model container
        do {
            // Create a simple configuration with default settings
            let config = ModelConfiguration(isStoredInMemoryOnly: false)

            // Pass the schema and configuration to the container
            container = try ModelContainer(for: schema, configurations: [config])

            print("SwiftData container initialized successfully for new models")
        } catch {
            fatalError("Failed to create ModelContainer for new models: \(error)")
        }
    }

    /// Creates a new ModelContext for use in background operations
    func newContext() -> ModelContext {
        return ModelContext(container)
    }

    /// The main context for main thread operations
    @MainActor
    func mainContext() -> ModelContext {
        return ModelContext(container)
    }
}

/// A wrapper view that provides the SwiftData container for our new models
/// This allows us to test the new models without affecting the rest of the app
struct SwiftDataContainerView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .modelContainer(SwiftDataContainer.shared.container)
    }
}

/// A simple test view to verify our SwiftData setup
struct SwiftDataTestView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var articles: [ArticleModel] = []
    @State private var topics: [TopicModel] = []
    @State private var testStatus: String = "Not tested"
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Test Status")) {
                    Text(testStatus)
                }

                Section(header: Text("Test Actions")) {
                    Button("Create Test Data") {
                        isLoading = true
                        Task {
                            await createTestData()
                            isLoading = false
                        }
                    }

                    Button("Load Data") {
                        isLoading = true
                        Task {
                            await loadData()
                            isLoading = false
                        }
                    }

                    Button("Clear Test Data") {
                        isLoading = true
                        Task {
                            await clearTestData()
                            isLoading = false
                        }
                    }
                }

                if isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                Section(header: Text("Articles (\(articles.count))")) {
                    ForEach(articles) { article in
                        VStack(alignment: .leading) {
                            Text(article.title)
                                .font(.headline)
                            Text(article.articleTitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Topics (\(topics.count))")) {
                    ForEach(topics) { topic in
                        Text(topic.name)
                    }
                }
            }
            .navigationTitle("SwiftData Test")
            .refreshable {
                await loadData()
            }
        }
    }

    @MainActor
    private func createTestData() async {
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
                jsonURL: "https://test.example.com/articles/test\(Int.random(in: 1000 ... 9999)).json",
                title: "Test Article \(Int.random(in: 1 ... 100))",
                body: "This is a test article body text.",
                articleTitle: "Full Test Article Title",
                affected: "Test Users",
                publishDate: Date(),
                topic: "Test Topic"
            )

            // Associate the article with the topic
            article.topics = [topic]

            // Save the models
            modelContext.insert(topic)
            modelContext.insert(article)

            // Create a test SeenArticle record
            let seenArticle = SeenArticleModel(
                id: article.id,
                jsonURL: article.jsonURL
            )
            modelContext.insert(seenArticle)

            try modelContext.save()
            testStatus = "Created test data successfully"

            // Refresh the data
            await loadData()

        } catch {
            testStatus = "Error creating test data: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadData() async {
        do {
            let articlesDescriptor = FetchDescriptor<ArticleModel>()
            articles = try modelContext.fetch(articlesDescriptor)

            let topicsDescriptor = FetchDescriptor<TopicModel>()
            topics = try modelContext.fetch(topicsDescriptor)

            let seenDescriptor = FetchDescriptor<SeenArticleModel>()
            let seenCount = try modelContext.fetch(seenDescriptor).count

            testStatus = "Loaded \(articles.count) articles, \(topics.count) topics, and \(seenCount) seen records"
        } catch {
            testStatus = "Error loading data: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func clearTestData() async {
        do {
            // Delete all test articles
            let articlesDescriptor = FetchDescriptor<ArticleModel>()
            let allArticles = try modelContext.fetch(articlesDescriptor)

            for article in allArticles {
                modelContext.delete(article)
            }

            // Delete all test topics
            let topicsDescriptor = FetchDescriptor<TopicModel>()
            let allTopics = try modelContext.fetch(topicsDescriptor)

            for topic in allTopics {
                modelContext.delete(topic)
            }

            // Delete all seen articles
            let seenDescriptor = FetchDescriptor<SeenArticleModel>()
            let allSeen = try modelContext.fetch(seenDescriptor)

            for seen in allSeen {
                modelContext.delete(seen)
            }

            try modelContext.save()
            testStatus = "Cleared all test data"

            // Refresh the data
            articles = []
            topics = []

        } catch {
            testStatus = "Error clearing test data: \(error.localizedDescription)"
        }
    }
}

/// Helper to create a preview
#Preview {
    SwiftDataContainerView {
        SwiftDataTestView()
    }
}
