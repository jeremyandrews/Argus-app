import BackgroundTasks
import Foundation
import Network
import SwiftData
import UIKit

// Custom notification names
extension Notification.Name {
    static let articleProcessingCompleted = Notification.Name("ArticleProcessingCompleted")
    static let syncStatusChanged = Notification.Name("SyncStatusChanged")
}

// Error type for timeout operations
struct TimeoutError: Error, LocalizedError {
    var errorDescription: String? {
        return "Operation timed out"
    }
}

// Array chunking is already defined in AppDelegate.swift

// Extension to process ArticleJSON from ArticleModels.swift
extension SyncManager {
    // Helper method that adapts the API JSON format to our ArticleJSON model
    func syncProcessArticleJSON(_ json: [String: Any]) -> ArticleJSON? {
        guard let title = json["tiny_title"] as? String,
              let body = json["tiny_summary"] as? String
        else {
            AppLogger.sync.error("Missing required fields in article JSON")
            return nil
        }

        let jsonURL = json["json_url"] as? String ?? ""
        let url = json["url"] as? String ?? json["article_url"] as? String ?? ""
        let domain = extractDomain(from: url)

        // Extract date if available
        var pubDate: Date?
        if let pubDateString = json["pub_date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            pubDate = formatter.date(from: pubDateString)

            if pubDate == nil {
                // Try alternative date formats
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                pubDate = fallbackFormatter.date(from: pubDateString)
            }
        }

        // Directly cast quality values from the JSON
        let sourcesQuality = json["sources_quality"] as? Int
        let argumentQuality = json["argument_quality"] as? Int
        let quality: Int? = (json["quality"] as? Double).map { Int($0) }

        // Create the article JSON object
        return ArticleJSON(
            title: title,
            body: body,
            jsonURL: jsonURL,
            url: url,
            topic: json["topic"] as? String,
            articleTitle: json["article_title"] as? String ?? "",
            affected: json["affected"] as? String ?? "",
            domain: domain,
            pubDate: pubDate,
            sourcesQuality: sourcesQuality,
            argumentQuality: argumentQuality,
            sourceType: json["source_type"] as? String,
            sourceAnalysis: json["source_analysis"] as? String,
            quality: quality,
            summary: json["summary"] as? String,
            criticalAnalysis: json["critical_analysis"] as? String,
            logicalFallacies: json["logical_fallacies"] as? String,
            relationToTopic: json["relation_to_topic"] as? String,
            additionalInsights: json["additional_insights"] as? String,
            engineStats: extractEngineStats(from: json),
            similarArticles: extractSimilarArticles(from: json)
        )
    }

    // Helper method to extract the domain from a URL
    private func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else {
            return nil
        }

        return url.host?.replacingOccurrences(of: "www.", with: "")
    }
}

@available(*, deprecated, message: "Use MigrationAdapter instead")
class SyncManager {
    // MARK: - Deprecation Warning
    
    /// Log a deprecation warning for the method that's being called
    private func logDeprecationWarning(method: String) {
        AppLogger.sync.warning("⚠️ DEPRECATED: \(method) is deprecated and will be removed in a future update. Use MigrationAdapter or BackgroundTaskManager instead.")
    }
    // Thread-safe lock for sync operations using an actor
    private actor SyncLockManager {
        private var isSyncing = false

        func tryLock() -> Bool {
            guard !isSyncing else { return false }
            isSyncing = true
            return true
        }

        func releaseLock() {
            isSyncing = false
        }
    }

    private let syncLockManager = SyncLockManager()

    // Try to acquire the sync lock in a thread-safe way
    private func trySyncLock() async -> Bool {
        return await syncLockManager.tryLock()
    }

    // Release the sync lock in a thread-safe way
    private func releaseSyncLock() async {
        await syncLockManager.releaseLock()
    }

    // Notify the UI about sync status changes
    private func notifySyncStatusChanged(_ isSyncing: Bool, error: Error? = nil) async {
        await MainActor.run {
            var userInfo: [String: Any] = ["isSyncing": isSyncing]
            if let error = error {
                userInfo["error"] = error
            }

            NotificationCenter.default.post(
                name: .syncStatusChanged,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // Async-safe versions of the processing lock methods
    private actor ProcessingLockActor {
        private var isProcessing = false
        private var itemsBeingProcessed = Set<String>()

        func acquireLock() -> Bool {
            guard !isProcessing else { return false }
            isProcessing = true
            return true
        }

        func releaseLock() {
            isProcessing = false
        }

        func registerItem(_ url: String) -> Bool {
            guard !itemsBeingProcessed.contains(url) else {
                return false
            }

            itemsBeingProcessed.insert(url)
            return true
        }

        func unregisterItem(_ url: String) {
            itemsBeingProcessed.remove(url)
        }
    }

    private static let processingLockActor = ProcessingLockActor()

    // Async-safe version of acquireProcessingLock
    private static func acquireProcessingLockAsync() async -> Bool {
        return await processingLockActor.acquireLock()
    }

    // Async-safe version of releaseProcessingLock
    private static func releaseProcessingLockAsync() async {
        await processingLockActor.releaseLock()
    }

    // Async-safe version of registerItemAsBeingProcessed
    private static func registerItemAsBeingProcessedAsync(_ url: String) async -> Bool {
        return await processingLockActor.registerItem(url)
    }

    // Async-safe version of unregisterItemAsProcessed
    private static func unregisterItemAsProcessedAsync(_ url: String) async {
        await processingLockActor.unregisterItem(url)
    }

    // Generic timeout function for async operations
    func withTimeout<T>(of seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: Result<T, Error>.self) { group in
            // Add the actual work
            group.addTask {
                do {
                    return try .success(await operation())
                } catch {
                    return .failure(error)
                }
            }

            // Add a timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .failure(TimeoutError())
            }

            // Return the first task to complete, cancelling the other
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CancellationError()
            }

            // Cancel any remaining tasks
            group.cancelAll()

            // Process the result
            switch result {
            case let .success(value):
                return value
            case let .failure(error):
                throw error
            }
        }
    }

    static let shared = SyncManager()

    // Background task identifier
    private let backgroundSyncIdentifier = "com.arguspulse.articlesync"
    private let backgroundFetchIdentifier = "com.arguspulse.articlefetch"

    // Throttling parameters
    private var syncInProgress = false
    private let manualSyncThrottle: TimeInterval = 30
    private var lastManualSyncTime = Date.distantPast

    // Notification names for app state changes
    private let notificationCenter = NotificationCenter.default

    // Network type enum
    private enum NetworkType {
        case wifi
        case cellular
        case other
        case unknown
    }

    // Initializes the SyncManager singleton and registers for app lifecycle notifications.
    // Sets up observers for foreground, background, and active state transitions
    // to ensure sync operations happen at appropriate times.
    private init() {
        // Register for app lifecycle notifications on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // App will enter foreground
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )

            // App did enter background
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )

            // App did become active
            self.notificationCenter.addObserver(
                self,
                selector: #selector(self.appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }
    }

    // Cleans up by removing all notification observers when the SyncManager is deallocated.
    deinit {
        notificationCenter.removeObserver(self)
    }

    // Handles app returning to foreground by triggering a sync operation after a short delay.
    // The delay ensures that network connectivity is established before attempting to sync.
    // Only proceeds with sync if the network conditions meet user preferences.
    @objc private func appWillEnterForeground() {
        // Schedule a sync after a short delay to ensure network is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task {
                let networkReady = await self.shouldAllowSync()
                if networkReady {
                    AppLogger.sync.debug("Network is ready - triggering foreground sync")
                    await self.sendRecentArticlesToServer()
                } else {
                    AppLogger.sync.error("Network not ready for sync")
                }
            }
        }
    }

    // Responds to the app becoming active by scheduling queue processing with a delay.
    // The delay ensures UI responsiveness during app launch/resume by deferring background work.
    @objc private func appDidBecomeActive() {
        AppLogger.sync.debug("App did become active")
        // Run maintenance task with a delay to ensure UI is highly responsive
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.startMaintenance()
        }
    }

    // Initiates database maintenance with lowest priority.
    // Ensures UI remains responsive by using background priority for the task.
    // Schedules further background tasks if needed.
    func startMaintenance() {
        Task.detached(priority: .utility) {
            let networkAllowed = await self.shouldAllowSync()
            if !networkAllowed {
                AppLogger.sync.debug("Maintenance skipped - network conditions not suitable")
                return
            }
            AppLogger.sync.debug("Starting maintenance in background")
            await self.performScheduledMaintenance()
            await MainActor.run {
                self.scheduleBackgroundFetch()
            }
        }
    }

    // Prepares for app entering background state by scheduling background tasks.
    // Ensures both sync and fetch operations will continue even when app is not active.
    @objc private func appDidEnterBackground() {
        AppLogger.sync.debug("App did enter background - scheduling background tasks")
        scheduleBackgroundSync()
        scheduleBackgroundFetch()
    }

    // Performs a one-time check of the current network connectivity type.
    // Returns an enum value indicating wifi, cellular, or other connectivity status.
    // Uses continuation to make the NWPathMonitor callback-based API compatible with async/await.
    private func getCurrentNetworkType() async -> NetworkType {
        return await withCheckedContinuation { continuation in
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { path in
                defer {
                    pathMonitor.cancel()
                }

                if path.usesInterfaceType(.wifi) {
                    continuation.resume(returning: .wifi)
                } else if path.usesInterfaceType(.cellular) {
                    continuation.resume(returning: .cellular)
                } else if path.status == .satisfied {
                    continuation.resume(returning: .other)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
            pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    // Determines if sync should be allowed based on current network conditions and user preferences.
    // Returns true if on WiFi or if cellular sync is explicitly allowed by user settings.
    // Used as a gatekeeper before initiating any network operations.
    private func shouldAllowSync() async -> Bool {
        let networkType = await getCurrentNetworkType()
        switch networkType {
        case .wifi:
            return true
        case .cellular, .other, .unknown:
            return UserDefaults.standard.bool(forKey: "allowCellularSync")
        }
    }

    // MARK: - Article Existence Checking (DatabaseCoordinator delegation)

    // Use the DatabaseCoordinator for all existence checking
    // This implementation delegates to the centralized, optimized methods

    /// Find an existing article by various criteria (delegated to DatabaseCoordinator)
    /// - Parameters:
    ///   - jsonURL: The JSON URL to check
    ///   - articleID: Optional article UUID
    ///   - articleURL: Optional article URL
    /// - Returns: The article if found, nil otherwise
    func findExistingArticle(jsonURL: String, articleID: UUID? = nil, articleURL: String? = nil, context _: ModelContext? = nil) async -> NotificationData? {
        // Create a debug identifier for tracing this specific check
        let checkID = UUID().uuidString.prefix(8)
        AppLogger.sync.debug("🔎 [\(checkID)] EXISTENCE CHECK START for \(String(jsonURL.suffix(40)))")

        if let articleID = articleID {
            AppLogger.sync.debug("🔎 [\(checkID)] Checking ID: \(articleID.uuidString)")
        }

        // Delegate to the DatabaseCoordinator
        let article = await DatabaseCoordinator.shared.findArticle(jsonURL: jsonURL, id: articleID, articleURL: articleURL)

        if let article = article {
            AppLogger.sync.debug("🔎 [\(checkID)] Article found: \(article.id)")
            return article
        } else {
            AppLogger.sync.debug("🔎 [\(checkID)] NO MATCHES FOUND - article does not exist")
            return nil
        }
    }

    /// Check if an article exists (delegated to DatabaseCoordinator)
    /// - Parameters:
    ///   - jsonURL: The JSON URL to check
    ///   - articleID: Optional article UUID
    ///   - articleURL: Optional article URL
    /// - Returns: True if the article exists
    func standardizedArticleExistsCheck(jsonURL: String, articleID: UUID? = nil, articleURL: String? = nil, context _: ModelContext? = nil) async -> Bool {
        // Delegate to DatabaseCoordinator
        return await DatabaseCoordinator.shared.articleExists(jsonURL: jsonURL, id: articleID, articleURL: articleURL)
    }

    /// Batch check for multiple articles (delegated to DatabaseCoordinator)
    /// - Parameters:
    ///   - jsonURLs: Array of JSON URLs to check
    ///   - ids: Optional array of UUIDs to check
    /// - Returns: Sets of existing URLs and IDs
    func standardizedBatchArticleExistsCheck(jsonURLs: [String], ids: [UUID]? = nil, context _: ModelContext? = nil) async -> (jsonURLs: Set<String>, ids: Set<UUID>) {
        // Delegate to DatabaseCoordinator
        return await DatabaseCoordinator.shared.batchArticleExistsCheck(jsonURLs: jsonURLs, ids: ids)
    }

    /// Check if an article has already been processed (delegated to DatabaseCoordinator)
    /// - Parameter jsonURL: The JSON URL to check
    /// - Returns: True if the article exists
    func isArticleAlreadyProcessed(jsonURL: String, context _: ModelContext? = nil) async -> Bool {
        // Extract UUID from the URL filename if possible
        let fileName = jsonURL.split(separator: "/").last ?? ""
        var extractedID: UUID? = nil

        if let uuidRange = fileName.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) {
            let uuidString = String(fileName[uuidRange])
            extractedID = UUID(uuidString: uuidString)
        }

        // Delegate to DatabaseCoordinator
        return await DatabaseCoordinator.shared.articleExists(jsonURL: jsonURL, id: extractedID)
    }

    /// Get existing articles by JSON URLs (delegated to DatabaseCoordinator)
    /// - Parameter jsonURLs: Array of JSON URLs to check
    /// - Returns: Set of existing JSON URLs
    private func getExistingArticles(jsonURLs: [String], context _: ModelContext? = nil) async throws -> Set<String> {
        // Delegate to DatabaseCoordinator
        let (existingURLs, _) = await DatabaseCoordinator.shared.batchArticleExistsCheck(jsonURLs: jsonURLs)
        return existingURLs
    }

    // MARK: - Global Processing Registry

    // Static flag to prevent multiple queue processors from running simultaneously
    private static var isProcessing = false

    // Try to acquire the global processing lock - returns true if acquired, false if already locked
    private static func acquireProcessingLock() -> Bool {
        processingLock.lock()
        defer { processingLock.unlock() }

        if isProcessing {
            return false
        }

        isProcessing = true
        return true
    }

    // Release the global processing lock
    private static func releaseProcessingLock() {
        processingLock.lock()
        defer { processingLock.unlock() }
        isProcessing = false
    }

    // Global registry of items currently being processed to prevent simultaneous processing
    private static var itemsBeingProcessed = Set<String>()
    private static let processingLock = NSLock()

    // Register an item as being processed - returns true if successful, false if already being processed
    private static func registerItemAsBeingProcessed(_ url: String) -> Bool {
        processingLock.lock()
        defer { processingLock.unlock() }

        if itemsBeingProcessed.contains(url) {
            AppLogger.sync.debug("🚨 DUPLICATE PREVENTION: Item already being processed: \(url)")
            return false
        }

        itemsBeingProcessed.insert(url)
        AppLogger.sync.debug("✅ Registered item as being processed: \(url)")
        return true
    }

    // Unregister an item from being processed
    private static func unregisterItemAsProcessed(_ url: String) {
        processingLock.lock()
        defer { processingLock.unlock() }

        itemsBeingProcessed.remove(url)
        AppLogger.sync.debug("✅ Unregistered item as processed: \(url)")
    }

    // MARK: - Direct Article Processing

    // DIRECT SERVER TO DATABASE PIPELINE
    // Processes articles directly without intermediate steps
    // Now with update capability for existing articles
    @available(*, deprecated, message: "Use MigrationAdapter.directProcessArticle instead")
    func directProcessArticle(jsonURL: String) async -> Bool {
        logDeprecationWarning(method: "directProcessArticle")
        
        // Forward call to MigrationAdapter instead
        return await MigrationAdapter.shared.directProcessArticle(jsonURL: jsonURL)
    }

    // Delegates database maintenance to MigrationAdapter
    @available(*, deprecated, message: "Use MigrationAdapter.performScheduledMaintenance instead")
    func performScheduledMaintenance(timeLimit: TimeInterval? = nil) async {
        logDeprecationWarning(method: "performScheduledMaintenance")
        
        // Forward call to MigrationAdapter
        await MigrationAdapter.shared.performScheduledMaintenance(timeLimit: timeLimit)
    }

    // Public compatibility methods that now just perform maintenance
    func processQueueBackground(timeLimit: TimeInterval) async {
        await performScheduledMaintenance(timeLimit: timeLimit)
    }

    func processQueue() async {
        await performScheduledMaintenance()
    }

    // Registers the app's background tasks with the system
    @available(*, deprecated, message: "Use BackgroundTaskManager.registerBackgroundTasks instead")
    func registerBackgroundTasks() {
        logDeprecationWarning(method: "registerBackgroundTasks")
        
        // Forward call to MigrationAdapter
        MigrationAdapter.shared.registerBackgroundTasks()
    }

    // Schedules a background app refresh task
    @available(*, deprecated, message: "Use BackgroundTaskManager.scheduleBackgroundRefresh instead")
    func scheduleBackgroundFetch() {
        logDeprecationWarning(method: "scheduleBackgroundFetch")
        
        // Forward call to MigrationAdapter
        MigrationAdapter.shared.scheduleBackgroundFetch()
    }

    // Schedules a background processing task
    @available(*, deprecated, message: "Use BackgroundTaskManager.scheduleBackgroundProcessing instead")
    func scheduleBackgroundSync() {
        logDeprecationWarning(method: "scheduleBackgroundSync")
        
        // Forward call to MigrationAdapter
        MigrationAdapter.shared.scheduleBackgroundSync()
    }

    // Requests expedited background processing
    @available(*, deprecated, message: "Use BackgroundTaskManager.scheduleBackgroundRefresh instead")
    func requestExpediteBackgroundProcessing() {
        logDeprecationWarning(method: "requestExpediteBackgroundProcessing")
        
        // Forward call to BackgroundTaskManager since MigrationAdapter doesn't have this method
        BackgroundTaskManager.shared.scheduleBackgroundRefresh()
    }

    // MARK: - Deterministic UUID Generation

    // Generate a deterministic UUID from a string to ensure consistency
    // This ensures the same URL will always map to the same UUID
    private func deterministicUUID(from string: String) -> UUID {
        // Create a stable UUID based on the full string content
        // Using a more robust approach to create unique IDs for different URLs

        // Create a string hash using a better distribution algorithm
        var hasher = Hasher()
        hasher.combine(string)
        let hash = hasher.finalize()

        // Convert hash to a string and concatenate with a prefix of the original string
        let hashString = String(hash, radix: 16, uppercase: false)

        // Extract the unique part of the URL (after the last slash)
        let uniquePart: String
        if let lastSlashIndex = string.lastIndex(of: "/") {
            let afterSlash = string[string.index(after: lastSlashIndex)...]
            uniquePart = String(afterSlash.prefix(8))
        } else {
            uniquePart = String(string.suffix(8))
        }

        // Combine the hash with the unique part to ensure differentiation
        let combinedString = "\(hashString)-\(uniquePart)"

        // Check if we can create a UUID (we don't actually need the value)
        if UUID(uuidString: "00000000-0000-0000-0000-000000000000") != nil {
            var uuidBytes = [UInt8](repeating: 0, count: 16)

            // Use a combination of hash and direct string representation
            // to ensure uniqueness even for similar strings
            for (index, char) in combinedString.utf8.enumerated() {
                if index < 16 {
                    uuidBytes[index] = char
                } else {
                    // XOR with existing bytes for remaining characters
                    uuidBytes[index % 16] = uuidBytes[index % 16] ^ char
                }
            }

            // Ensure this is a valid v4 UUID
            uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40 // version 4
            uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80 // variant 1

            return NSUUID(uuidBytes: uuidBytes) as UUID
        } else {
            // Fallback using hash if for some reason the above fails
            let hashBytes: [UInt8] = [
                UInt8((hash >> 56) & 0xFF),
                UInt8((hash >> 48) & 0xFF),
                UInt8((hash >> 40) & 0xFF),
                UInt8((hash >> 32) & 0xFF),
                UInt8((hash >> 24) & 0xFF),
                UInt8((hash >> 16) & 0xFF),
                UInt8((hash >> 8) & 0xFF),
                UInt8(hash & 0xFF),
                // Fill remaining bytes with hash of original string length and first/last chars
                UInt8(string.count & 0xFF),
                UInt8((string.count >> 8) & 0xFF),
                UInt8(string.first?.asciiValue ?? 0),
                UInt8(string.last?.asciiValue ?? 0),
                0, 0, 0, 0,
            ]

            var finalBytes = hashBytes
            // Ensure this is a valid v4 UUID
            finalBytes[6] = (finalBytes[6] & 0x0F) | 0x40 // version 4
            finalBytes[8] = (finalBytes[8] & 0x3F) | 0x80 // variant 1

            // Hash the remaining bytes to ensure all 16 bytes are filled
            for i in 12 ..< 16 {
                finalBytes[i] = UInt8((hash >> ((i - 12) * 8)) & 0xFF)
            }

            return NSUUID(uuidBytes: finalBytes) as UUID
        }
    }

    // MARK: - Database Transaction Lock

    // Use a shared, static flag to serialize all database transactions
    // This ensures no parallel transactions can occur that might create duplicates
    private static var transactionLock = NSLock()
    private static var transactedURLs = Set<String>()
    private static var processingURLs = Set<String>()
    private static var processingIDs = Set<String>()

    // Acquire transaction lock before doing critical database operations
    // Returns true if lock was acquired, false if this URL is already being processed
    private static func acquireTransactionLock(forURL url: String) -> Bool {
        transactionLock.lock()
        defer {
            if !transactedURLs.contains(url) {
                transactedURLs.insert(url)
            }
            transactionLock.unlock()
        }

        // If URL is already being processed by another thread, don't process it again
        return !transactedURLs.contains(url)
    }

    // Release transaction lock after critical database operations
    private static func releaseTransactionLock(forURL url: String) {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        transactedURLs.remove(url)
    }

    // Check if a URL is being processed and mark it as being processed if not
    private func markURLAsProcessing(_ url: String) -> Bool {
        // Thread-safe check and insert
        Self.processingLock.lock()
        defer { Self.processingLock.unlock() }

        // If URL is already being processed, return false
        if Self.processingURLs.contains(url) {
            AppLogger.sync.debug("Skipping URL that's currently being processed: \(url)")
            return false
        }

        // Otherwise mark it as being processed and return true
        Self.processingURLs.insert(url)
        return true
    }

    // Check if an ID is being processed and mark it as being processed if not
    private func markIDAsProcessing(_ id: UUID) -> Bool {
        let idString = id.uuidString

        Self.processingLock.lock()
        defer { Self.processingLock.unlock() }

        if Self.processingIDs.contains(idString) {
            AppLogger.sync.debug("Skipping ID that's currently being processed: \(id)")
            return false
        }

        Self.processingIDs.insert(idString)
        return true
    }

    // Mark a URL as no longer being processed
    private func markURLAsFinished(_ url: String) {
        Self.processingLock.lock()
        defer { Self.processingLock.unlock() }
        Self.processingURLs.remove(url)
    }

    // Mark an ID as no longer being processed
    private func markIDAsFinished(_ id: UUID) {
        Self.processingLock.lock()
        defer { Self.processingLock.unlock() }
        Self.processingIDs.remove(id.uuidString)
    }

    // MARK: - ID Deduplication Cache

    // A cache to keep track of recently processed notification IDs
    // This is a final safeguard against duplicate inserts even across different instances
    private static var recentlyProcessedIDs = NSCache<NSString, NSDate>()
    private static let idCacheExpirationInterval: TimeInterval = 600 // 10 minutes

    // Check if an ID was recently processed and mark it as processed if not
    private func checkAndMarkIDAsProcessed(id: UUID) -> Bool {
        let idString = id.uuidString as NSString
        let now = Date()

        // Synchronized access to prevent race conditions
        objc_sync_enter(Self.recentlyProcessedIDs)
        defer { objc_sync_exit(Self.recentlyProcessedIDs) }

        // Check if this ID was processed recently
        if let processedDate = Self.recentlyProcessedIDs.object(forKey: idString) {
            // If the entry is recent enough, it's a duplicate
            if now.timeIntervalSince(processedDate as Date) < Self.idCacheExpirationInterval {
                AppLogger.sync.debug("Duplicate ID detected via in-memory cache: \(id)")
                return true
            }
        }

        // Not a duplicate (or expired entry), mark as processed
        Self.recentlyProcessedIDs.setObject(now as NSDate, forKey: idString)
        return false
    }

    // MARK: - Sync Methods

    // Initiates a user-requested manual sync operation with throttling protection.
    // Prevents excessive sync operations by enforcing a minimum time between manual syncs.
    // Returns a boolean indicating whether the sync was started or skipped due to throttling.
    @available(*, deprecated, message: "Use MigrationAdapter.manualSync instead")
    func manualSync() async -> Bool {
        logDeprecationWarning(method: "manualSync")
        
        // Forward to MigrationAdapter for future compatibility
        return await MigrationAdapter.shared.manualSync()
    }

    // Syncs recent article history with the server
    @available(*, deprecated, message: "Use MigrationAdapter.manualSync instead")
    func sendRecentArticlesToServer() async {
        logDeprecationWarning(method: "sendRecentArticlesToServer")
        
        // Forward to MigrationAdapter.manualSync instead since sendRecentArticlesToServer doesn't exist
        _ = await MigrationAdapter.shared.manualSync()
    }

    // Helper to check if an ID is already used in the database
    private func isIDAlreadyUsed(_ id: UUID, context: ModelContext) async -> Bool {
        var idFetchDescriptor = FetchDescriptor<NotificationData>(
            predicate: #Predicate<NotificationData> { notification in
                notification.id == id
            }
        )
        idFetchDescriptor.fetchLimit = 1

        do {
            let count = try context.fetchCount(idFetchDescriptor)
            if count > 0 {
                return true
            }
        } catch {
            AppLogger.sync.error("Error checking ID existence: \(error)")
            return true // Fail safe: assume it exists if we can't check
        }

        // Also check SeenArticle table
        var idSeenFetchDescriptor = FetchDescriptor<SeenArticle>(
            predicate: #Predicate<SeenArticle> { seen in
                seen.id == id
            }
        )
        idSeenFetchDescriptor.fetchLimit = 1

        do {
            let count = try context.fetchCount(idSeenFetchDescriptor)
            return count > 0
        } catch {
            AppLogger.sync.error("Error checking ID existence in SeenArticle: \(error)")
            return true // Fail safe: assume it exists if we can't check
        }
    }

    // This method has been removed as part of the queue removal process
    // All article processing now happens through the directProcessArticle method

    private func extractEngineStats(from json: [String: Any]) -> String? {
        var engineStatsDict: [String: Any] = [:]

        if let model = json["model"] as? String {
            engineStatsDict["model"] = model
        }

        if let elapsedTime = json["elapsed_time"] as? Double {
            engineStatsDict["elapsed_time"] = elapsedTime
        }

        if let stats = json["stats"] as? String {
            engineStatsDict["stats"] = stats
        }

        if let systemInfo = json["system_info"] as? [String: Any] {
            engineStatsDict["system_info"] = systemInfo
        }

        if engineStatsDict.isEmpty {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: engineStatsDict), encoding: .utf8)
    }

    private func extractSimilarArticles(from json: [String: Any]) -> String? {
        guard let similarArticles = json["similar_articles"] as? [[String: Any]], !similarArticles.isEmpty else {
            return nil
        }

        return try? String(data: JSONSerialization.data(withJSONObject: similarArticles), encoding: .utf8)
    }

    // Retrieves article records from the last 24 hours using DatabaseCoordinator
    // Used to build the list of seen articles to send to the server during sync.
    private func fetchRecentArticles() async -> [SeenArticle] {
        let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        return await DatabaseCoordinator.shared.fetchRecentArticles(since: oneDayAgo)
    }

    // Process articles using the MigrationAdapter
    @available(*, deprecated, message: "Use MigrationAdapter.processArticlesDirectly instead")
    func processArticlesDirectly(urls: [String]) async {
        logDeprecationWarning(method: "processArticlesDirectly")
        
        // Forward call to MigrationAdapter
        await MigrationAdapter.shared.processArticlesDirectly(urls: urls)
    }

    // Process multiple articles in the background
    @available(*, deprecated, message: "Use MigrationAdapter.processArticlesDirectly instead")
    private func processArticlesDetached(urls: [String]) async {
        logDeprecationWarning(method: "processArticlesDetached")
        
        // Forward to MigrationAdapter.processArticlesDirectly since processArticlesInBackground doesn't exist
        await MigrationAdapter.shared.processArticlesDirectly(urls: urls)
    }

    // Process a single article in isolation
    @available(*, deprecated, message: "Use MigrationAdapter.directProcessArticle instead")
    private func processArticleIsolated(jsonURL: String, container: ModelContainer? = nil) async -> (created: Int, updated: Int, failed: Int) {
        logDeprecationWarning(method: "processArticleIsolated")
        
        // Forward to MigrationAdapter.directProcessArticle since processArticleIsolated doesn't exist
        let success = await MigrationAdapter.shared.directProcessArticle(jsonURL: jsonURL)
        // Convert the boolean result to the expected tuple return type
        return success ? (1, 0, 0) : (0, 0, 1)
    }
}
