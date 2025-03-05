import Foundation
import SwiftData

@Model
class ArticleQueueItem {
    // Core properties
    @Attribute(.unique) var jsonURL: String // Unique identifier for the article
    @Attribute var createdAt: Date

    // Optional reference to associated notification
    @Attribute var notificationID: UUID?

    init(
        jsonURL: String,
        createdAt: Date = Date(),
        notificationID: UUID? = nil
    ) {
        self.jsonURL = jsonURL
        self.createdAt = createdAt
        self.notificationID = notificationID
    }
}

// Queue helper for managing ArticleQueueItems
class ArticleQueueManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // Add a new article to the queue if it doesn't already exist
    func addArticle(jsonURL: String) async throws -> Bool {
        // Check if the article is already in the queue
        let descriptor = FetchDescriptor<ArticleQueueItem>(
            predicate: #Predicate { $0.jsonURL == jsonURL }
        )

        if let _ = try? modelContext.fetch(descriptor).first {
            // Item already exists, ignore it
            return false
        } else {
            // Create a new queue item
            let newItem = ArticleQueueItem(jsonURL: jsonURL)
            modelContext.insert(newItem)
            try modelContext.save()
            return true
        }
    }

    // Add a new article to the queue with notification ID if it doesn't already exist
    func addArticleWithNotification(jsonURL: String, notificationID: UUID) async throws -> Bool {
        // Check if the article is already in the queue
        let descriptor = FetchDescriptor<ArticleQueueItem>(
            predicate: #Predicate { $0.jsonURL == jsonURL }
        )

        if let _ = try? modelContext.fetch(descriptor).first {
            // Item already exists, ignore it
            return false
        } else {
            // Create a new queue item
            let newItem = ArticleQueueItem(
                jsonURL: jsonURL,
                notificationID: notificationID
            )
            modelContext.insert(newItem)
            try modelContext.save()
            return true
        }
    }

    // Get the next item to process (FIFO order)
    func nextItem() async throws -> ArticleQueueItem? {
        var descriptor = FetchDescriptor<ArticleQueueItem>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    // Get multiple items to process (FIFO order)
    func getItemsToProcess(limit: Int) async throws -> [ArticleQueueItem] {
        var descriptor = FetchDescriptor<ArticleQueueItem>(
            sortBy: [SortDescriptor(\.createdAt)]
        )

        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor)
    }

    // Remove an item from the queue after processing
    func removeItem(_ item: ArticleQueueItem) throws {
        modelContext.delete(item)
        try modelContext.save()
    }

    // Get count of items in the queue
    func queueCount() async throws -> Int {
        let descriptor = FetchDescriptor<ArticleQueueItem>()
        return try modelContext.fetchCount(descriptor)
    }
}

// Extension for convenience function
extension ModelContext {
    func queueManager() -> ArticleQueueManager {
        return ArticleQueueManager(modelContext: self)
    }
}
