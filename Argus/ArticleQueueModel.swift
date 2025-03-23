import Foundation
import SwiftData

// A simple queue item holding article info.
class ArticleQueueItem {
    let jsonURL: String
    let createdAt: Date
    let notificationID: UUID?

    init(jsonURL: String, createdAt: Date = Date(), notificationID: UUID? = nil) {
        self.jsonURL = jsonURL
        self.createdAt = createdAt
        self.notificationID = notificationID
    }
}

// A memory‑based FIFO queue manager using an actor for thread‐safety.
actor MemoryArticleQueueManager {
    static let shared = MemoryArticleQueueManager()
    private var queue: [ArticleQueueItem] = []

    // Maximum allowed age (in seconds) for a queue item before it is skipped.
    private var maxItemAge: TimeInterval {
        let configured = UserDefaults.standard.double(forKey: "maxQueueItemAge")
        return configured > 0 ? configured : 24 * 60 * 60 // default 24 hours
    }

    // Adds an article without a notification.
    // Checks the database (using a background context) first to see if the article was already processed.
    // If so, it returns false immediately to prevent duplicate queue entries.
    func addArticle(jsonURL: String) async throws -> Bool {
        let alreadyProcessed = await BackgroundContextManager.shared.performAsyncBackgroundTask { context in
            await SyncManager.shared.isArticleAlreadyProcessed(jsonURL: jsonURL, context: context)
        }

        if alreadyProcessed {
            AppLogger.sync.debug("Skipping already processed article (database): \(jsonURL)")
            return false
        }

        // Check if the article is already in the in‑memory queue.
        if queue.contains(where: { $0.jsonURL == jsonURL }) {
            AppLogger.sync.debug("Skipping duplicate article (queue): \(jsonURL)")
            return false
        }

        let newItem = ArticleQueueItem(jsonURL: jsonURL)
        queue.append(newItem)
        return true
    }

    // Adds an article with a notification.
    // Checks the database (using a background context) first to ensure the article hasn't been seen already.
    // If the article is already processed or queued, it returns false.
    func addArticleWithNotification(jsonURL: String, notificationID: UUID) async throws -> Bool {
        let alreadyProcessed = await BackgroundContextManager.shared.performAsyncBackgroundTask { context in
            await SyncManager.shared.isArticleAlreadyProcessed(jsonURL: jsonURL, context: context)
        }

        if alreadyProcessed {
            AppLogger.sync.debug("Skipping already processed article (database): \(jsonURL)")
            return false
        }

        // Also check if the article is already in our in‑memory queue.
        if queue.contains(where: { $0.jsonURL == jsonURL }) {
            AppLogger.sync.debug("Skipping duplicate article (queue): \(jsonURL)")
            return false
        }

        let newItem = ArticleQueueItem(jsonURL: jsonURL, notificationID: notificationID)
        queue.append(newItem)
        return true
    }

    // Returns the next non‑expired item in FIFO order.
    func nextItem() async throws -> ArticleQueueItem? {
        while let first = queue.first {
            if Date().timeIntervalSince(first.createdAt) > maxItemAge {
                _ = queue.removeFirst()
            } else {
                return first
            }
        }
        return nil
    }

    // Returns up to "limit" non‑expired items in FIFO order.
    func getItemsToProcess(limit: Int) async throws -> [ArticleQueueItem] {
        var validItems: [ArticleQueueItem] = []
        var indicesToRemove: [Int] = []
        for (index, item) in queue.enumerated() {
            if Date().timeIntervalSince(item.createdAt) > maxItemAge {
                indicesToRemove.append(index)
            } else if validItems.count < limit {
                validItems.append(item)
            }
        }
        // Remove expired items
        for index in indicesToRemove.reversed() {
            queue.remove(at: index)
        }
        return validItems
    }

    // Removes a specific item from the queue.
    func removeItem(_ item: ArticleQueueItem) {
        if let index = queue.firstIndex(where: { $0.jsonURL == item.jsonURL }) {
            queue.remove(at: index)
        }
    }

    // Returns the count of non‑expired items.
    func queueCount() async throws -> Int {
        queue = queue.filter { Date().timeIntervalSince($0.createdAt) <= maxItemAge }
        return queue.count
    }
}
