import Foundation
import SwiftUI
import SwiftData

/// A processing queue manager that handles markdown conversion in batches
/// with proper prioritization to prevent UI freezing
class ProcessingQueueManager {
    // Singleton instance
    static let shared = ProcessingQueueManager()
    
    // Private queue for processing
    private let processingQueue = DispatchQueue(label: "com.argus.markdownProcessing", 
                                               qos: .utility, 
                                               attributes: .concurrent)
    
    // Track articles being processed to prevent duplicates
    private var processingIDs = Set<UUID>()
    private let processingLock = NSLock()
    
    // Batch processing settings
    private var batchProcessingTask: Task<Void, Never>?
    private var pendingArticles = [UUID]()
    private let pendingLock = NSLock()
    private let batchSize = 3
    private let batchDelay: UInt64 = 200_000_000 // 200ms
    
    private init() {}
    
    // Check if an article is currently being processed - thread-safe using MainActor
    @MainActor
    func isBeingProcessed(_ id: UUID) -> Bool {
        return processingIDs.contains(id)
    }
    
    // Add an article to the processing queue - thread-safe using MainActor
    @MainActor
    func scheduleProcessing(for notificationID: UUID) {
        // Don't schedule if already processing
        if processingIDs.contains(notificationID) {
            return
        }
        
        // Add to pending queue
        if !pendingArticles.contains(notificationID) {
            pendingArticles.append(notificationID)
            AppLogger.database.debug("Scheduled article \(notificationID) for markdown processing")
        }
        
        // Start batch processing if needed
        if batchProcessingTask == nil {
            startBatchProcessing()
        }
    }
    
    // Process articles in batches to avoid UI freezes
    @MainActor
    private func startBatchProcessing() {
        batchProcessingTask = Task(priority: .utility) {
            // Add a small delay to accumulate articles
            try? await Task.sleep(nanoseconds: batchDelay)
            
            while !Task.isCancelled {
                // Get a batch of articles to process
                let batch = await getNextBatch()
                if batch.isEmpty {
                    break
                }
                
                // Process each article in the batch
                for id in batch {
                    if Task.isCancelled { break }
                    
                    // Mark as processing and process
                    await markAsProcessing(id)
                    await processArticle(id)
                    await markAsFinished(id)
                    
                    // Small yield to allow UI updates
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }
            
            // Allow a new batch task to be started
            await MainActor.run {
                batchProcessingTask = nil
            }
        }
    }
    
    // Get the next batch of articles to process
    @MainActor
    private func getNextBatch() async -> [UUID] {
        // Get up to batchSize articles
        let batchCount = min(batchSize, pendingArticles.count)
        if batchCount == 0 {
            return []
        }
        
        let batch = Array(pendingArticles.prefix(batchCount))
        pendingArticles.removeFirst(batchCount)
        
        return batch
    }
    
    // Mark an article as being processed
    @MainActor
    private func markAsProcessing(_ id: UUID) async {
        processingIDs.insert(id)
    }
    
    // Mark an article as finished processing
    @MainActor
    private func markAsFinished(_ id: UUID) async {
        processingIDs.remove(id)
    }
    
    // Process a single article - delegates to DatabaseCoordinator for the actual processing
    @MainActor
    private func processArticle(_ id: UUID) async {
        // Post a notification that will be handled by a component with access to the markdown utilities
        NotificationCenter.default.post(
            name: Notification.Name("ProcessMarkdownForArticle"),
            object: nil,
            userInfo: ["articleID": id]
        )
        
        // Log that we've requested processing
        AppLogger.database.debug("Requested markdown processing for article \(id)")
    }
}
