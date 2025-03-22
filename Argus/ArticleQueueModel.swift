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

    // Check if a notification exists with this ID
    func checkForExistingNotification(id: UUID, context: ModelContext) async -> Bool {
        let descriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { notification in
                notification.id == id
            }
        )

        let count = (try? context.fetchCount(descriptor)) ?? 0
        return count > 0
    }

    // Get notification ID if it exists from a queue item
    func getNotificationID(forURL jsonURL: String, context: ModelContext) async throws -> UUID? {
        let descriptor = FetchDescriptor<ArticleQueueItem>(
            predicate: #Predicate { $0.jsonURL == jsonURL }
        )

        return try context.fetch(descriptor).first?.notificationID
    }
}

// Queue helper for managing ArticleQueueItems
class ArticleQueueManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // Add a new article to the queue if it doesn't already exist and hasn't been processed yet
    func addArticle(jsonURL: String) async throws -> Bool {
        // 1) First check if the article is already in NotificationData or SeenArticle
        let alreadyProcessed = await SyncManager.shared.isArticleAlreadyProcessed(
            jsonURL: jsonURL,
            context: modelContext
        )

        if alreadyProcessed {
            AppLogger.app.debug("Skipping addArticle: article is already in NotificationData or SeenArticle")
            return false
        }

        // 2) Then check if the article is already in the queue
        let descriptor = FetchDescriptor<ArticleQueueItem>(
            predicate: #Predicate { $0.jsonURL == jsonURL }
        )

        if let _ = try? modelContext.fetch(descriptor).first {
            // Item already exists in queue, ignore it
            return false
        } else {
            // 3) Create a new queue item if it doesn't exist anywhere
            let newItem = ArticleQueueItem(jsonURL: jsonURL)
            modelContext.insert(newItem)
            try modelContext.save()
            return true
        }
    }

    // Add a new article to the queue with notification ID if it doesn't already exist and hasn't been processed yet
    func addArticleWithNotification(jsonURL: String, notificationID: UUID) async throws -> Bool {
        // 1) First check if the article is already in NotificationData or SeenArticle
        let alreadyProcessed = await SyncManager.shared.isArticleAlreadyProcessed(
            jsonURL: jsonURL,
            context: modelContext
        )

        if alreadyProcessed {
            AppLogger.app.debug("Skipping addArticleWithNotification: article is already in NotificationData or SeenArticle")
            return false
        }

        // 2) Then check if the article is already in the queue
        let descriptor = FetchDescriptor<ArticleQueueItem>(
            predicate: #Predicate { $0.jsonURL == jsonURL }
        )

        if let _ = try? modelContext.fetch(descriptor).first {
            // Item already exists in queue, ignore it
            return false
        } else {
            // 3) Create a new queue item if it doesn't exist anywhere
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
