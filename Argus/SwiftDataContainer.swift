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

    // Status tracking
    private(set) var lastError: Error?
    private(set) var isUsingInMemoryFallback = false

    // Initialization status
    var status: String {
        if let error = lastError {
            return "Error: \(error.localizedDescription)" + (isUsingInMemoryFallback ? " (Using in-memory fallback)" : "")
        } else if isUsingInMemoryFallback {
            return "Using in-memory storage (temporary mode)"
        } else {
            return "Using persistent storage"
        }
    }

    private init() {
        // Force in-memory storage for now
        // This avoids CloudKit-related errors with required fields and unique constraints
        // When future iPad syncing is implemented, you will need to:
        // 1. Modify ArticleDataModels.swift to make attributes optional/with defaults
        // 2. Remove unique constraints from model definitions
        // 3. Change this configuration to use CloudKit

        print("Creating in-memory SwiftData container to avoid CloudKit integration issues")
        isUsingInMemoryFallback = true

        // Create a simple schema
        let schema = Schema([
            ArticleModel.self,
            SeenArticleModel.self,
            TopicModel.self,
        ])

        do {
            // Always use in-memory storage
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            print("In-memory SwiftData container successfully created")
        } catch {
            print("Failed to create even a basic in-memory container: \(error)")
            lastError = error

            // Last resort - empty container
            print("Creating minimal container as last resort")
            do {
                let minimalSchema = Schema([])
                container = try ModelContainer(for: minimalSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                print("Created empty fallback container")
            } catch {
                fatalError("Cannot create ANY ModelContainer - app cannot function: \(error)")
            }
        }
    }

    /// Makes a best effort to delete any persistent store files
    func resetStore() -> String {
        var deletedFiles: [String] = []
        var errors: [String] = []

        // Try multiple locations where SwiftData might store its files
        let possibleLocations = [
            // Default app support directory
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            // Document directory
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            // Library directory
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
            // Caches directory
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        // Look for typical SwiftData store files with various naming patterns
        let storeNames = [
            "default.store",
            "ArgusSwiftData.store",
            "SwiftData.sqlite",
            "ArticleModel.store",
            "Argus.store",
        ]
        let extensions = ["", "-wal", "-shm", ".sqlite-wal", ".sqlite-shm"]

        for location in possibleLocations {
            print("Searching for SwiftData files in: \(location.path)")

            for name in storeNames {
                for ext in extensions {
                    let fileURL = location.appendingPathComponent(name + ext)

                    // Try to remove if exists
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        do {
                            try FileManager.default.removeItem(at: fileURL)
                            print("Removed SwiftData file: \(fileURL.path)")
                            deletedFiles.append(fileURL.lastPathComponent)
                        } catch {
                            print("Failed to remove \(fileURL.lastPathComponent): \(error)")
                            errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Also try to find any SwiftData directories that might exist
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
                for item in contents {
                    if item.lastPathComponent.contains("SwiftData") ||
                        item.lastPathComponent.contains("ModelContainer") ||
                        item.lastPathComponent.contains("Argus.sqlite")
                    {
                        do {
                            try FileManager.default.removeItem(at: item)
                            print("Removed SwiftData directory/file: \(item.path)")
                            deletedFiles.append(item.lastPathComponent)
                        } catch {
                            print("Failed to remove \(item.lastPathComponent): \(error)")
                            errors.append("\(item.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                print("Failed to list directory contents at \(location.path): \(error)")
            }
        }

        // Also clear UserDefaults related to migration
        UserDefaults.standard.removeObject(forKey: "migrationProgress")

        // Build result summary
        var result = "Store reset attempted - please restart the app for changes to take effect\n\n"

        if !deletedFiles.isEmpty {
            result += "Deleted \(deletedFiles.count) files:\n"
            result += deletedFiles.joined(separator: "\n")
            result += "\n\n"
        } else {
            result += "No SwiftData files found to delete.\n\n"
        }

        if !errors.isEmpty {
            result += "Encountered \(errors.count) errors:\n"
            result += errors.joined(separator: "\n")
        }

        print(result)
        return result
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
    @State private var showResetConfirmation = false
    @State private var diagnosticInfo: String = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Container Status")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(SwiftDataContainer.shared.isUsingInMemoryFallback ? Color.orange : Color.green)
                                .frame(width: 12, height: 12)
                            Text(SwiftDataContainer.shared.status)
                                .font(.headline)
                                .foregroundColor(SwiftDataContainer.shared.isUsingInMemoryFallback ? .orange : .green)
                        }

                        Text("Mode: \(SwiftDataContainer.shared.isUsingInMemoryFallback ? "In-Memory (temporary)" : "Persistent")")
                            .font(.caption)
                            .foregroundColor(SwiftDataContainer.shared.isUsingInMemoryFallback ? .orange : .green)

                        if SwiftDataContainer.shared.isUsingInMemoryFallback {
                            Text("⚠️ In-memory mode does not persist data between app launches and cannot be used for migration!")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.top, 2)
                        }
                    }

                    Button("Reset SwiftData Store", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.white)
                    .background(Color.red)
                    .cornerRadius(8)
                    .padding(.vertical, 4)
                    .confirmationDialog(
                        "Reset SwiftData Store?",
                        isPresented: $showResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset & Exit App", role: .destructive) {
                            // Reset the store and suggest an app restart
                            let resetResult = SwiftDataContainer.shared.resetStore()
                            testStatus = "Store reset complete - please restart app now"
                            diagnosticInfo = resetResult
                        }
                    } message: {
                        Text("This will delete all SwiftData store files. You must restart the app for changes to take effect. This action cannot be undone.")
                    }
                }

                if !diagnosticInfo.isEmpty {
                    Section(header: Text("Diagnostic Info")) {
                        Text(diagnosticInfo)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

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
                    .disabled(isLoading || SwiftDataContainer.shared.isUsingInMemoryFallback)

                    Button("Load Data") {
                        isLoading = true
                        Task {
                            await loadData()
                            isLoading = false
                        }
                    }
                    .disabled(isLoading)

                    Button("Clear Test Data") {
                        isLoading = true
                        Task {
                            await clearTestData()
                            isLoading = false
                        }
                    }
                    .disabled(isLoading)
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
