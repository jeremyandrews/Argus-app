import Foundation
import SwiftUI
import Combine

/// Global coordinator that prevents duplicate content downloads by coordinating all sync operations
/// Prevents race conditions between manual and automatic syncs
@MainActor
final class GlobalSyncCoordinator: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = GlobalSyncCoordinator()
    
    // MARK: - Published Properties
    
    @Published private(set) var isSyncInProgress = false
    @Published private(set) var currentSyncType: SyncType?
    @Published private(set) var syncStatistics = SyncStatistics()
    
    // MARK: - Private Properties
    
    private var pendingSyncs: [SyncRequest] = []
    private var activeSyncTask: Task<SyncResult, Error>?
    private var syncRequestId: Int = 0
    
    // MARK: - Dependencies
    
    private let articleService: ArticleServiceProtocol
    private let logger = AppLogger.sync
    
    // MARK: - Types
    
    enum SyncType: Equatable {
        case manual(topic: String?)
        case automatic(context: String)
        case background
        case foregroundReturn
        
        var description: String {
            switch self {
            case .manual(let topic):
                return "Manual (\(topic ?? "All"))"
            case .automatic(let context):
                return "Automatic (\(context))"
            case .background:
                return "Background"
            case .foregroundReturn:
                return "Foreground Return"
            }
        }
        
        func isDuplicate(of other: SyncType, topic: String?) -> Bool {
            switch (self, other) {
            case (.manual(let topic1), .manual(let topic2)):
                return topic1 == topic2
            case (.automatic(let context1), .automatic(let context2)):
                return context1 == context2
            case (.background, .background):
                return true
            case (.foregroundReturn, .foregroundReturn):
                return true
            default:
                return false
            }
        }
    }
    
    struct SyncRequest {
        let id: Int
        let type: SyncType
        let topic: String?
        let limit: Int?
        let progressHandler: ((String) -> Void)?
        let timestamp: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300 // 5 minutes
        }
    }
    
    struct SyncResult {
        let newArticles: Int
        let duplicatesDetected: Int
        let duplicatesRemoved: Int
        let duration: TimeInterval
        let type: SyncType
    }
    
    struct SyncStatistics {
        var totalSyncs: Int = 0
        var totalNewArticles: Int = 0
        var totalDuplicatesDetected: Int = 0
        var totalDuplicatesRemoved: Int = 0
        var preventedRaceConditions: Int = 0
        var lastSyncTime: Date?
        var averageSyncDuration: TimeInterval = 0
        
        mutating func recordSync(_ result: SyncResult, preventedRace: Bool = false) {
            totalSyncs += 1
            totalNewArticles += result.newArticles
            totalDuplicatesDetected += result.duplicatesDetected
            totalDuplicatesRemoved += result.duplicatesRemoved
            if preventedRace { preventedRaceConditions += 1 }
            lastSyncTime = Date()
            
            // Update average duration
            averageSyncDuration = (averageSyncDuration * Double(totalSyncs - 1) + result.duration) / Double(totalSyncs)
        }
        
        var duplicateRate: Double {
            guard totalNewArticles + totalDuplicatesDetected > 0 else { return 0 }
            return Double(totalDuplicatesDetected) / Double(totalNewArticles + totalDuplicatesDetected)
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        self.articleService = ArticleService.shared
    }
    
    // MARK: - Public Interface
    
    /// Requests a sync operation with automatic deduplication and race condition prevention
    /// - Parameters:
    ///   - type: The type of sync being requested
    ///   - topic: Optional topic to sync (nil for all topics)
    ///   - limit: Maximum number of articles to sync
    ///   - progressHandler: Optional progress callback
    /// - Returns: Number of new articles added
    func requestSync(
        type: SyncType,
        topic: String? = nil,
        limit: Int? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        
        logger.debug("Sync requested: \(type.description)")
        
        // Check for duplicate or conflicting sync
        if let activeTask = activeSyncTask,
           let currentType = currentSyncType {
            
            // If it's the exact same request, return the existing result
            if currentType.isDuplicate(of: type, topic: topic) {
                logger.debug("Duplicate sync request detected - returning existing result")
                let result = try await activeTask.value
                return result.newArticles
            }
            
            // If it's a different sync, queue it or merge if possible
            let canMerge = canMergeRequests(current: currentType, requested: type)
            
            if canMerge {
                logger.debug("Merging sync request with active sync")
                let result = try await activeTask.value
                syncStatistics.preventedRaceConditions += 1
                return result.newArticles
            } else {
                logger.debug("Queueing sync request - active sync in progress")
                return try await queueSyncRequest(
                    type: type,
                    topic: topic,
                    limit: limit,
                    progressHandler: progressHandler
                )
            }
        }
        
        // No active sync - execute immediately
        return try await performSync(
            type: type,
            topic: topic,
            limit: limit,
            progressHandler: progressHandler
        )
    }
    
    /// Gets current sync statistics for monitoring and diagnostics
    func getSyncStatistics() -> SyncStatistics {
        return syncStatistics
    }
    
    /// Resets sync statistics
    func resetStatistics() {
        syncStatistics = SyncStatistics()
        logger.debug("Sync statistics reset")
    }
    
    /// Forces cleanup of duplicate articles
    @discardableResult
    func forceDuplicateCleanup() async throws -> Int {
        guard !isSyncInProgress else {
            logger.warning("Cannot perform duplicate cleanup during active sync")
            throw SyncCoordinatorError.syncInProgress
        }
        
        logger.debug("Starting forced duplicate cleanup")
        let removedCount = try await articleService.removeDuplicateArticles()
        
        // Update statistics
        syncStatistics.totalDuplicatesRemoved += removedCount
        
        logger.debug("Forced duplicate cleanup completed - removed \(removedCount) duplicates")
        return removedCount
    }
    
    // MARK: - Private Methods
    
    private func performSync(
        type: SyncType,
        topic: String? = nil,
        limit: Int? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        
        let startTime = Date()
        
        // Set sync state
        isSyncInProgress = true
        currentSyncType = type
        
        // Create cancellable task
        let syncTask = Task<SyncResult, Error> {
            return try await executeSyncOperation(
                type: type,
                topic: topic,
                limit: limit,
                progressHandler: progressHandler,
                startTime: startTime
            )
        }
        
        activeSyncTask = syncTask
        
        defer {
            // Clean up state
            isSyncInProgress = false
            currentSyncType = nil
            activeSyncTask = nil
            
            // Clean up expired pending syncs
            cleanupExpiredPendingSyncs()
        }
        
        do {
            let result = try await syncTask.value
            
            // Record statistics
            syncStatistics.recordSync(result)
            
            logger.info("Sync completed successfully: \(type.description) - \(result.newArticles) new articles, \(result.duplicatesDetected) duplicates detected, \(result.duplicatesRemoved) duplicates removed")
            
            return result.newArticles
            
        } catch {
            logger.error("Sync failed: \(type.description) - \(error)")
            throw error
        }
    }
    
    private func executeSyncOperation(
        type: SyncType,
        topic: String?,
        limit: Int?,
        progressHandler: ((String) -> Void)?,
        startTime: Date
    ) async throws -> SyncResult {
        
        var newArticles = 0
        var duplicatesDetected = 0
        var duplicatesRemoved = 0
        
        switch type {
        case .manual, .automatic, .foregroundReturn:
            // Use enhanced sync with duplicate detection
            progressHandler?("Starting sync...")
            
            // Perform the sync with duplicate detection
            let syncResult = try await performSyncWithDuplicateDetection(
                topic: topic,
                limit: limit,
                progressHandler: progressHandler
            )
            
            newArticles = syncResult.newArticles
            duplicatesDetected = syncResult.duplicatesDetected
            duplicatesRemoved = syncResult.duplicatesRemoved
            
        case .background:
            // Use background sync
            progressHandler?("Starting background sync...")
            
            let result = try await articleService.performBackgroundSync(
                progressHandler: progressHandler
            )
            
            newArticles = result.addedCount
            
            // Run cleanup after background sync
            duplicatesRemoved = try await articleService.removeDuplicateArticles()
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return SyncResult(
            newArticles: newArticles,
            duplicatesDetected: duplicatesDetected,
            duplicatesRemoved: duplicatesRemoved,
            duration: duration,
            type: type
        )
    }
    
    private func performSyncWithDuplicateDetection(
        topic: String?,
        limit: Int?,
        progressHandler: ((String) -> Void)?
    ) async throws -> (newArticles: Int, duplicatesDetected: Int, duplicatesRemoved: Int) {
        
        // Fetch articles from server
        progressHandler?("Fetching articles from server...")
        
        let remoteArticles = try await APIClient.shared.fetchArticles(
            topic: topic,
            progressHandler: progressHandler
        )
        
        // Pre-process duplicate detection
        progressHandler?("Checking for duplicates...")
        
        var duplicatesDetected = 0
        let uniqueArticles = deduplicateArticlesBatch(remoteArticles, duplicatesFound: &duplicatesDetected)
        
        if duplicatesDetected > 0 {
            logger.debug("Detected \(duplicatesDetected) duplicate articles in server response")
        }
        
        // Process unique articles
        progressHandler?("Processing articles...")
        
        let newArticles = try await articleService.processArticleData(
            uniqueArticles,
            progressHandler: progressHandler
        )
        
        // Post-process cleanup
        progressHandler?("Cleaning up any remaining duplicates...")
        
        let duplicatesRemoved = try await articleService.removeDuplicateArticles()
        
        if duplicatesRemoved > 0 {
            logger.debug("Removed \(duplicatesRemoved) duplicate articles from database")
        }
        
        return (
            newArticles: newArticles,
            duplicatesDetected: duplicatesDetected,
            duplicatesRemoved: duplicatesRemoved
        )
    }
    
    private func deduplicateArticlesBatch(_ articles: [ArticleJSON], duplicatesFound: inout Int) -> [ArticleJSON] {
        var seen: Set<String> = []
        var unique: [ArticleJSON] = []
        
        for article in articles {
            let key = article.jsonURL
            if !key.isEmpty && !seen.contains(key) {
                seen.insert(key)
                unique.append(article)
            } else {
                duplicatesFound += 1
            }
        }
        
        return unique
    }
    
    private func queueSyncRequest(
        type: SyncType,
        topic: String?,
        limit: Int?,
        progressHandler: ((String) -> Void)?
    ) async throws -> Int {
        
        // Generate unique request ID
        syncRequestId += 1
        let requestId = syncRequestId
        
        let request = SyncRequest(
            id: requestId,
            type: type,
            topic: topic,
            limit: limit,
            progressHandler: progressHandler,
            timestamp: Date()
        )
        
        // Add to pending queue
        pendingSyncs.append(request)
        
        logger.debug("Queued sync request \(requestId): \(type.description)")
        
        // Wait for current sync to complete
        if let activeTask = activeSyncTask {
            do {
                _ = try await activeTask.value
            } catch {
                // Active sync failed, but we still want to process our queued request
                logger.warning("Active sync failed, but processing queued request anyway: \(error)")
            }
        }
        
        // Check if our request is still in the queue (may have been processed or expired)
        guard let queuedRequest = pendingSyncs.first(where: { $0.id == requestId }),
              !queuedRequest.isExpired else {
            logger.warning("Queued sync request \(requestId) expired or was processed")
            throw SyncCoordinatorError.requestExpired
        }
        
        // Remove from queue and execute
        pendingSyncs.removeAll { $0.id == requestId }
        
        return try await performSync(
            type: queuedRequest.type,
            topic: queuedRequest.topic,
            limit: queuedRequest.limit,
            progressHandler: queuedRequest.progressHandler
        )
    }
    
    private func canMergeRequests(current: SyncType, requested: SyncType) -> Bool {
        // Manual syncs can often be merged with automatic syncs
        switch (current, requested) {
        case (.automatic, .manual):
            return true
        case (.manual, .automatic):
            return true
        case (.background, .automatic):
            return true
        case (.automatic, .background):
            return true
        default:
            return false
        }
    }
    
    private func cleanupExpiredPendingSyncs() {
        let initialCount = pendingSyncs.count
        pendingSyncs.removeAll { $0.isExpired }
        let removedCount = initialCount - pendingSyncs.count
        
        if removedCount > 0 {
            logger.debug("Cleaned up \(removedCount) expired pending sync requests")
        }
    }
}

// MARK: - Error Types

enum SyncCoordinatorError: Error, LocalizedError {
    case syncInProgress
    case requestExpired
    case coordinatorUnavailable
    
    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            return "Sync operation already in progress"
        case .requestExpired:
            return "Sync request expired while waiting"
        case .coordinatorUnavailable:
            return "Sync coordinator is unavailable"
        }
    }
}

// MARK: - Convenience Extensions

extension GlobalSyncCoordinator {
    
    /// Convenience method for manual sync requests
    func requestManualSync(
        topic: String? = nil,
        limit: Int? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        return try await requestSync(
            type: .manual(topic: topic),
            topic: topic,
            limit: limit,
            progressHandler: progressHandler
        )
    }
    
    /// Convenience method for automatic sync requests
    func requestAutomaticSync(
        context: String,
        topic: String? = nil,
        limit: Int? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        return try await requestSync(
            type: .automatic(context: context),
            topic: topic,
            limit: limit,
            progressHandler: progressHandler
        )
    }
    
    /// Convenience method for background sync requests
    func requestBackgroundSync(
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        return try await requestSync(
            type: .background,
            topic: nil,
            limit: nil,
            progressHandler: progressHandler
        )
    }
    
    /// Get formatted statistics report for debugging
    func getStatisticsReport() -> String {
        let stats = syncStatistics
        
        return """
        📊 Global Sync Coordinator Statistics
        
        🔄 Total Syncs: \(stats.totalSyncs)
        📄 New Articles: \(stats.totalNewArticles)
        🔍 Duplicates Detected: \(stats.totalDuplicatesDetected)
        🗑️ Duplicates Removed: \(stats.totalDuplicatesRemoved)
        🚫 Race Conditions Prevented: \(stats.preventedRaceConditions)
        
        ⏱️ Average Sync Duration: \(String(format: "%.2f", stats.averageSyncDuration))s
        📈 Duplicate Rate: \(String(format: "%.2f", stats.duplicateRate * 100))%
        🕐 Last Sync: \(stats.lastSyncTime?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
        
        🔧 Current Status:
        - Sync In Progress: \(isSyncInProgress ? "Yes" : "No")
        - Current Sync Type: \(currentSyncType?.description ?? "None")
        - Pending Requests: \(pendingSyncs.count)
        """
    }
}
