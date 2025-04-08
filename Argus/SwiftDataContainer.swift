import CloudKit
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

    // Container configuration
    enum ContainerType {
        case cloudKit // With CloudKit integration
        case localPersistent // Local persistent storage only
        case fallback // Fallback mode after error
    }

    // Current container type
    private(set) var containerType: ContainerType

    // CloudKit container identifier
    private let cloudKitContainerIdentifier = "iCloud.com.andrews.Argus.Argus"

    // Status tracking
    private(set) var lastError: Error?
    private(set) var cloudKitError: Error?

    // Initialization status
    var status: String {
        switch containerType {
        case .cloudKit:
            return "Using CloudKit integration"
        case .localPersistent:
            return "Using local persistent storage"
        case .fallback:
            if let error = lastError {
                return "Using fallback after error: \(error.localizedDescription)"
            } else {
                return "Using fallback storage"
            }
        }
    }

    // Database location
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private var testStorageURL: URL {
        return documentsDirectory.appendingPathComponent("ArgusTestDB.store")
    }

    private init() {
        // Initialize all stored properties first
        containerType = .fallback // Default until we succeed
        cloudKitError = nil
        lastError = nil

        // Create a schema with ALL required models for migration
        let schema = Schema([
            // Legacy models needed for migration
            NotificationData.self,
            SeenArticle.self,

            // New SwiftData models
            ArticleModel.self,
            SeenArticleModel.self,
            TopicModel.self,
        ])

        // Storage path
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbPath = documentsDir.appendingPathComponent("ArgusTestDB.store")

        // First attempt: Try CloudKit integration
        ModernizationLogger.logTransitionStart("Creating SwiftData container with CloudKit", component: .cloudKit)

        do {
            // Create configuration with CloudKit integration
            // Use a simple ModelConfiguration with URL/schema
            // SwiftData should detect the CloudKit container from the app's entitlements
            ModernizationLogger.log(.debug, component: .cloudKit,
                                    message: "Setting up CloudKit container for identifier: \(cloudKitContainerIdentifier)")
            let cloudKitConfig = ModelConfiguration(schema: schema)

            container = try ModelContainer(for: schema, configurations: [cloudKitConfig])
            containerType = .cloudKit

            ModernizationLogger.logTransitionCompletion(
                "CloudKit container creation",
                component: .cloudKit,
                success: true,
                detail: "Successfully created container with CloudKit integration"
            )

            print("CloudKit-enabled SwiftData container successfully created")
        } catch {
            // Log CloudKit error details
            ModernizationLogger.logCloudKitError(
                operation: "Creating CloudKit container",
                error: error,
                detail: "Falling back to local persistent storage"
            )

            print("Failed to create CloudKit container: \(error)")
            cloudKitError = error

            // Second attempt: Fall back to local persistent storage
            ModernizationLogger.logTransitionStart("Creating fallback persistent container", component: .cloudKit)

            // Use persistent storage with a dedicated test database name
            print("Creating persistent SwiftData container at: \(dbPath.path)")
            let localConfig = ModelConfiguration(url: dbPath)

            do {
                container = try ModelContainer(for: schema, configurations: [localConfig])
                containerType = .localPersistent

                ModernizationLogger.logTransitionCompletion(
                    "Fallback container creation",
                    component: .cloudKit,
                    success: true,
                    detail: "Successfully created local persistent container as fallback"
                )

                print("Local persistent SwiftData container successfully created")
            } catch {
                // Log the fallback error
                ModernizationLogger.log(
                    .critical,
                    component: .cloudKit,
                    message: "CRITICAL: Failed to create both CloudKit and local persistent containers: \(error.localizedDescription)"
                )

                print("Failed to create persistent container: \(error)")
                lastError = error
                containerType = .fallback

                // Create a container in the temp directory as a last resort
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ArgusEmergencyFallback.store")

                ModernizationLogger.logFallback(
                    from: "Normal storage paths",
                    to: "Temporary directory fallback",
                    reason: "Both CloudKit and persistent storage failed",
                    component: .cloudKit
                )

                do {
                    let emergencyConfig = ModelConfiguration(url: tempURL)
                    container = try ModelContainer(for: schema, configurations: [emergencyConfig])

                    ModernizationLogger.log(
                        .warning,
                        component: .cloudKit,
                        message: "Created emergency fallback container in temporary directory"
                    )
                } catch {
                    // At this point, we have no choice but to crash, as we've tried all options
                    ModernizationLogger.log(
                        .critical,
                        component: .cloudKit,
                        message: "FATAL: All container creation attempts failed - app cannot function: \(error.localizedDescription)"
                    )

                    fatalError("All container creation attempts failed - app cannot function: \(error)")
                }
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

        // First specifically target our test database file
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let testDBURL = documentsDirectory.appendingPathComponent("ArgusTestDB.store")
        let testDBExtensions = ["", "-wal", "-shm", ".sqlite-wal", ".sqlite-shm"]

        for ext in testDBExtensions {
            let fileURL = testDBURL.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    print("Removed test database file: \(fileURL.path)")
                    deletedFiles.append(fileURL.lastPathComponent)
                } catch {
                    print("Failed to remove test database file \(fileURL.lastPathComponent): \(error)")
                    errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Look for typical SwiftData store files with various naming patterns
        let storeNames = [
            "default.store",
            "ArgusSwiftData.store",
            "SwiftData.sqlite",
            "ArticleModel.store",
            "Argus.store",
            "ArgusTestDB.store",
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
                        item.lastPathComponent.contains("Argus.sqlite") ||
                        item.lastPathComponent.contains("ArgusTestDB")
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
    @State private var showCloudKitInfo: Bool = false

    // Performance metrics
    @State private var lastOperationDuration: TimeInterval = 0
    @State private var lastOperationDate: Date? = nil
    @State private var lastOperationArticleCount: Int = 0
    @State private var showPerformanceMetrics = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Container Status")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            let container = SwiftDataContainer.shared
                            let statusColor: Color = container.containerType == .cloudKit ? .blue :
                                container.containerType == .localPersistent ? .green : .orange

                            Circle()
                                .fill(statusColor)
                                .frame(width: 12, height: 12)
                            Text(container.status)
                                .font(.headline)
                                .foregroundColor(statusColor)
                        }

                        // Storage location
                        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let dbPath = documentsDirectory.appendingPathComponent("ArgusTestDB.store").path
                        Text("Storage location: \(dbPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // CloudKit container if applicable
                        if SwiftDataContainer.shared.containerType == .cloudKit {
                            HStack {
                                Image(systemName: "icloud")
                                    .foregroundColor(.blue)
                                Text("iCloud.com.andrews.Argus.Argus")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .padding(.top, 2)
                        }

                        // Show error info button if there was a CloudKit error
                        if SwiftDataContainer.shared.cloudKitError != nil {
                            Button(action: { showCloudKitInfo.toggle() }) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text("CloudKit Error Info")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
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

                if showCloudKitInfo, let error = SwiftDataContainer.shared.cloudKitError {
                    Section(header: Text("CloudKit Error Details")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Error Type: \(type(of: error))")
                                .font(.caption)
                                .bold()

                            Text("Description: \(error.localizedDescription)")
                                .font(.caption)

                            if let ckError = error as? CKError {
                                Text("CloudKit Error Code: \(ckError.errorCode)")
                                    .font(.caption)

                                if let errorDescription = ckError.errorUserInfo[NSLocalizedDescriptionKey] as? String {
                                    Text("Error Description: \(errorDescription)")
                                        .font(.caption)
                                }

                                if let recoveryAction = ckError.errorUserInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
                                    Text("Recovery Suggestion: \(recoveryAction)")
                                        .font(.caption)
                                }
                            }

                            // Check account status
                            Button("Check iCloud Account Status") {
                                checkCloudKitAccountStatus()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                        }
                        .foregroundColor(.orange)
                    }
                }

                Section(header: Text("Test Status")) {
                    Text(testStatus)
                }

                if showPerformanceMetrics && lastOperationDate != nil {
                    Section(header: Text("Performance Metrics")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last operation: \(lastOperationDate?.formatted(date: .omitted, time: .standard) ?? "N/A")")
                            Text("Duration: \(String(format: "%.3f", lastOperationDuration))s")
                            if lastOperationArticleCount > 0 {
                                Text("Articles created: \(lastOperationArticleCount)")
                                Text("Time per article: \(String(format: "%.3f", lastOperationDuration / Double(lastOperationArticleCount)))s")
                                Text("Theoretical time for 100 articles: \(String(format: "%.1f", (lastOperationDuration / Double(lastOperationArticleCount)) * 100))s")
                                Text("Theoretical time for 500 articles: \(String(format: "%.1f", (lastOperationDuration / Double(lastOperationArticleCount)) * 500))s")
                            }
                        }
                        .font(.footnote)
                    }
                }

                Section(header: Text("Test Actions")) {
                    Button("Create Test Article") {
                        isLoading = true
                        Task {
                            let startTime = Date()
                            await createTestData()
                            let duration = Date().timeIntervalSince(startTime)
                            lastOperationDuration = duration
                            lastOperationDate = Date()
                            lastOperationArticleCount = 1
                            showPerformanceMetrics = true
                            isLoading = false
                        }
                    }
                    .disabled(isLoading)

                    Button("Create Random Batch (1-10 Articles)") {
                        isLoading = true
                        Task {
                            await createBatchTestData()
                            isLoading = false
                        }
                    }
                    .disabled(isLoading)

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
            testStatus = "Created test article successfully with ID: \(article.id)"

            // Refresh the data
            await loadData()

        } catch {
            testStatus = "Error creating test data: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createBatchTestData() async {
        let startTime = Date()
        let articlesCount = Int.random(in: 1 ... 10)
        let topicsCount = min(3, Int.random(in: 1 ... articlesCount))

        // Create a dedicated background context for database operations
        let backgroundContext = SwiftDataContainer.shared.newContext()

        testStatus = "Creating batch of \(articlesCount) articles..."

        // Use Task to ensure we're not on the main thread
        await Task.detached {
            // Log operation start with diagnostics
            print("📊 Starting batch creation of \(articlesCount) articles with \(topicsCount) topics")

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
                print("📊 Saved \(topicsCount) topics in \(String(format: "%.3f", topicSaveDuration))s")
            } catch {
                print("📊 Failed to save topics: \(error)")

                // Update UI on main thread
                await MainActor.run {
                    self.testStatus = "Failed to save topics: \(error.localizedDescription)"
                    self.lastOperationDuration = Date().timeIntervalSince(startTime)
                    self.lastOperationDate = Date()
                    self.lastOperationArticleCount = 0
                    self.showPerformanceMetrics = true
                }
                return
            }

            // 2. Create random articles with varied content
            var articles: [ArticleModel] = []

            // Create articles in smaller batches (5 at a time) with intermediate saves
            let batchSize = 5
            for batchIndex in 0 ..< (articlesCount + batchSize - 1) / batchSize {
                let startIndex = batchIndex * batchSize
                let endIndex = min(startIndex + batchSize, articlesCount)
                print("📊 Creating articles batch \(startIndex)-\(endIndex - 1)")

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
                    print("📊 Saved batch \(batchIndex + 1) in \(String(format: "%.3f", batchSaveDuration))s (total batch time: \(String(format: "%.3f", totalBatchDuration))s)")
                } catch {
                    print("📊 Failed to save batch \(batchIndex + 1): \(error)")

                    // Update UI on main thread with what we managed to create before the error
                    let articlesCreatedSoFar = articles.count
                    await MainActor.run {
                        self.testStatus = "Failed saving batch \(batchIndex + 1): \(error.localizedDescription)"
                        self.lastOperationDuration = Date().timeIntervalSince(startTime)
                        self.lastOperationDate = Date()
                        self.lastOperationArticleCount = articlesCreatedSoFar
                        self.showPerformanceMetrics = true
                    }

                    // Refresh UI with what was saved
                    await MainActor.run { [self] in
                        self.articles = []
                        self.topics = []
                    }
                    // Call loadData after the MainActor update
                    await loadData()
                    return
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            let perArticleTime = duration / Double(articlesCount)

            // Log detailed performance metrics
            print("📊 Batch created \(articlesCount) articles with \(topicsCount) topics in \(String(format: "%.3f", duration))s")
            print("📊 Average time per article: \(String(format: "%.3f", perArticleTime))s")
            print("📊 Theoretical time for 100 articles: \(String(format: "%.3f", perArticleTime * 100))s")
            print("📊 Theoretical time for 500 articles: \(String(format: "%.3f", perArticleTime * 500))s")

            // First update UI properties on main thread
            await MainActor.run { [self] in
                self.testStatus = "Created \(articlesCount) articles with \(topicsCount) topics in \(String(format: "%.3f", duration))s"
                self.lastOperationDuration = duration
                self.lastOperationDate = Date()
                self.lastOperationArticleCount = articlesCount
                self.showPerformanceMetrics = true
            }

            // Then call loadData separately after MainActor work is complete
            await loadData()
        }.value
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

    // Helper function to check CloudKit account status
    private func checkCloudKitAccountStatus() {
        isLoading = true
        diagnosticInfo = "Checking iCloud account status..."

        // Use CKContainer to check the account status
        CKContainer.default().accountStatus { status, error in
            DispatchQueue.main.async {
                self.isLoading = false

                var statusInfo = "iCloud Account Status Check:\n"

                if let error = error {
                    statusInfo += "Error: \(error.localizedDescription)\n"
                    ModernizationLogger.logCloudKitError(
                        operation: "Checking account status",
                        error: error
                    )
                }

                // Report account status
                statusInfo += "Account Status: "
                switch status {
                case .available:
                    statusInfo += "Available ✅\n"
                    statusInfo += "The user is logged into iCloud and can use CloudKit."
                case .restricted:
                    statusInfo += "Restricted ⚠️\n"
                    statusInfo += "The user's iCloud account is restricted (e.g., parental controls)."
                case .noAccount:
                    statusInfo += "No Account ❌\n"
                    statusInfo += "The user is not logged into iCloud. No iCloud account is configured."
                case .couldNotDetermine:
                    statusInfo += "Could Not Determine ❓\n"
                    statusInfo += "The status could not be determined. Please check internet connectivity."
                case .temporarilyUnavailable:
                    statusInfo += "Temporarily Unavailable ⏳\n"
                    statusInfo += "iCloud is temporarily unavailable, possibly due to maintenance."
                @unknown default:
                    statusInfo += "Unknown Status\n"
                    statusInfo += "Unknown status code: \(status.rawValue)"
                }

                // Log the status
                ModernizationLogger.log(
                    .info,
                    component: .cloudKit,
                    message: "iCloud account status: \(statusInfo)"
                )

                self.diagnosticInfo = statusInfo
            }
        }
    }

    @MainActor
    private func clearTestData() async {
        let startTime = Date()
        let logPrefix = "📊 SwiftData Clear:"

        func logTimestamp(_ message: String) {
            let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
            print("\(logPrefix) [\(elapsed)s] \(message)")
            // Also update UI for immediate feedback
            testStatus = message
        }

        logTimestamp("Starting deletion process")

        do {
            // Log initial counts
            let initialArticles = try modelContext.fetch(FetchDescriptor<ArticleModel>()).count
            let initialTopics = try modelContext.fetch(FetchDescriptor<TopicModel>()).count
            let initialSeen = try modelContext.fetch(FetchDescriptor<SeenArticleModel>()).count

            logTimestamp("Initial counts - Articles: \(initialArticles), Topics: \(initialTopics), Seen: \(initialSeen)")

            // Create a fresh deletion context
            logTimestamp("Creating isolation context for deletion")
            let deletionContext = SwiftDataContainer.shared.newContext()

            // 1. Log and nullify relationships to break circular references
            logTimestamp("Fetching articles to nullify relationships")
            let articlesForNullifying = try deletionContext.fetch(FetchDescriptor<ArticleModel>())
            logTimestamp("Found \(articlesForNullifying.count) articles with potential relationships")

            var relationshipCount = 0
            for (index, article) in articlesForNullifying.enumerated() {
                if let topics = article.topics, !topics.isEmpty {
                    relationshipCount += topics.count
                    logTimestamp("Article \(index) has \(topics.count) topic relationships")
                }
                article.topics = []

                // Log every 10 articles to avoid console spam
                if index % 10 == 0 && index > 0 {
                    logTimestamp("Nullified relationships for \(index)/\(articlesForNullifying.count) articles")
                }
            }

            logTimestamp("Nullified \(relationshipCount) total relationships across \(articlesForNullifying.count) articles")

            // Save to commit relationship changes
            logTimestamp("Saving relationship nullification changes")
            try deletionContext.save()
            logTimestamp("Successfully saved relationship nullification")

            // 2. Delete seen articles
            logTimestamp("Fetching seen articles for deletion")
            let seenDescriptor = FetchDescriptor<SeenArticleModel>()
            let allSeen = try deletionContext.fetch(seenDescriptor)
            logTimestamp("Found \(allSeen.count) seen articles to delete")

            // Delete in batches with timing info
            for batch in stride(from: 0, to: allSeen.count, by: 10) {
                let end = min(batch + 10, allSeen.count)
                logTimestamp("Deleting seen articles batch \(batch)-\(end - 1) of \(allSeen.count)")

                for i in batch ..< end {
                    deletionContext.delete(allSeen[i])
                }

                let batchStartTime = Date()
                try deletionContext.save()
                let batchDuration = Date().timeIntervalSince(batchStartTime)
                logTimestamp("Saved seen deletion batch in \(String(format: "%.3f", batchDuration))s")
            }

            // 3. Delete topics
            logTimestamp("Fetching topics for deletion")
            let topicsDescriptor = FetchDescriptor<TopicModel>()
            let allTopics = try deletionContext.fetch(topicsDescriptor)
            logTimestamp("Found \(allTopics.count) topics to delete")

            for batch in stride(from: 0, to: allTopics.count, by: 5) {
                let end = min(batch + 5, allTopics.count)
                logTimestamp("Deleting topics batch \(batch)-\(end - 1) of \(allTopics.count)")

                for i in batch ..< end {
                    // Check if topic still has articles even after nullification
                    if let articles = allTopics[i].articles, !articles.isEmpty {
                        logTimestamp("⚠️ WARNING: Topic still has \(articles.count) articles before deletion")
                    }

                    deletionContext.delete(allTopics[i])
                }

                let batchStartTime = Date()
                try deletionContext.save()
                let batchDuration = Date().timeIntervalSince(batchStartTime)
                logTimestamp("Saved topic deletion batch in \(String(format: "%.3f", batchDuration))s")
            }

            // 4. Delete any remaining articles
            logTimestamp("Checking for remaining articles")
            let articlesDescriptor = FetchDescriptor<ArticleModel>()
            let allArticles = try deletionContext.fetch(articlesDescriptor)
            logTimestamp("Found \(allArticles.count) remaining articles to delete")

            for batch in stride(from: 0, to: allArticles.count, by: 10) {
                let end = min(batch + 10, allArticles.count)
                logTimestamp("Deleting articles batch \(batch)-\(end - 1) of \(allArticles.count)")

                for i in batch ..< end {
                    deletionContext.delete(allArticles[i])
                }

                let batchStartTime = Date()
                try deletionContext.save()
                let batchDuration = Date().timeIntervalSince(batchStartTime)
                logTimestamp("Saved article deletion batch in \(String(format: "%.3f", batchDuration))s")
            }

            // Final verification and UI update
            let finalArticlesCheck = try modelContext.fetch(FetchDescriptor<ArticleModel>())
            let finalTopicsCheck = try modelContext.fetch(FetchDescriptor<TopicModel>())
            let finalSeenCheck = try modelContext.fetch(FetchDescriptor<SeenArticleModel>())

            let totalDuration = Date().timeIntervalSince(startTime)
            let finalMessage = "Deletion complete in \(String(format: "%.3f", totalDuration))s. Remaining: \(finalArticlesCheck.count) articles, \(finalTopicsCheck.count) topics, \(finalSeenCheck.count) seen records"
            logTimestamp(finalMessage)

            // Refresh the UI
            articles = []
            topics = []
            testStatus = finalMessage

        } catch {
            let errorDuration = Date().timeIntervalSince(startTime)
            let errorMessage = "Error after \(String(format: "%.3f", errorDuration))s: \(error.localizedDescription)"
            logTimestamp("❌ \(errorMessage)")
            testStatus = errorMessage
        }
    }
}

/// Helper to create a preview
#Preview {
    SwiftDataContainerView {
        SwiftDataTestView()
    }
}
