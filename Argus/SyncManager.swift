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

class SyncManager {
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
    func directProcessArticle(jsonURL: String) async -> Bool {
        // Global lock to ensure only one process can handle articles at a time
        guard Self.acquireProcessingLock() else {
            AppLogger.sync.debug("⚠️ Article processing already in progress, skipping: \(jsonURL)")
            return false
        }

        // Always release the lock when we're done
        defer {
            Self.releaseProcessingLock()
        }

        AppLogger.sync.debug("🔒 DIRECT PROCESSING: \(jsonURL)")

        // Use the DatabaseCoordinator to process the article
        return await DatabaseCoordinator.shared.processArticle(jsonURL: jsonURL)
    }

    // Delegates database maintenance to the DatabaseCoordinator
    // This is used by background refresh tasks
    func performScheduledMaintenance(timeLimit _: TimeInterval? = nil) async {
        guard Self.acquireProcessingLock() else {
            AppLogger.sync.debug("⚠️ Database maintenance already in progress, skipping")
            return
        }

        defer {
            Self.releaseProcessingLock()
        }

        AppLogger.sync.debug("===== DATABASE MAINTENANCE STARTING =====")
        let startTime = Date()

        // Delegate maintenance to DatabaseCoordinator
        await DatabaseCoordinator.shared.performMaintenance()

        let timeUsed = Date().timeIntervalSince(startTime)
        AppLogger.sync.debug("Maintenance completed in \(String(format: "%.2f", timeUsed))s")
        AppLogger.sync.debug("===== DATABASE MAINTENANCE FINISHED =====")
    }

    // Public compatibility methods that now just perform maintenance
    func processQueueBackground(timeLimit: TimeInterval) async {
        await performScheduledMaintenance(timeLimit: timeLimit)
    }

    func processQueue() async {
        await performScheduledMaintenance()
    }

    // Registers the app's background tasks with the system for queue processing and server sync.
    // Sets up handlers for both BGAppRefreshTask (article fetch) and BGProcessingTask (sync).
    // Includes proper task cancellation handling and scheduling of follow-up tasks.
    // Schedules initial background tasks after registration.
    func registerBackgroundTasks() {
        // Register article fetch task (for processing queue)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundFetchIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }

            // Create a cancellable task
            let processingTask = Task {
                // First check if the current network state meets the user's requirements
                let networkAllowed = await self.shouldAllowSync()

                if networkAllowed {
                    // Use maintenance with a conservative time limit
                    // BGAppRefreshTask doesn't have a timeRemaining property in this iOS version
                    await self.performScheduledMaintenance(timeLimit: 25) // 25 seconds is a safe limit
                    appRefreshTask.setTaskCompleted(success: true)
                } else {
                    AppLogger.sync.debug("Background fetch skipped - cellular not allowed by user")
                    appRefreshTask.setTaskCompleted(success: false)
                }
            }

            // Handle task expiration cleanly
            appRefreshTask.expirationHandler = {
                processingTask.cancel()
                AppLogger.sync.debug("Background fetch task expired and was cancelled by the system")
            }

            // Schedule the next fetch after this completes
            Task {
                // Wait for the task to complete without throwing errors
                _ = await processingTask.value

                await MainActor.run {
                    self.scheduleBackgroundFetch()
                }
            }
        }

        // Register the sync task (for syncing with server)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }

            // Create a cancellable task
            let syncTask = Task {
                // Check network conditions before proceeding
                let networkAllowed = await self.shouldAllowSync()

                if networkAllowed {
                    await self.sendRecentArticlesToServer()
                    processingTask.setTaskCompleted(success: true)
                } else {
                    AppLogger.sync.debug("Background sync skipped - cellular not allowed by user")
                    processingTask.setTaskCompleted(success: false)
                }
            }

            // Handle task expiration cleanly
            processingTask.expirationHandler = {
                syncTask.cancel()
                AppLogger.sync.debug("Background sync task expired and was cancelled by the system")
            }

            // Schedule the next sync after this completes
            Task {
                // Wait for the task to complete without throwing errors
                _ = await syncTask.value

                await MainActor.run {
                    self.scheduleBackgroundSync()
                }
            }
        }

        // Schedule initial tasks - let the system determine when to run them
        scheduleBackgroundFetch()
        scheduleBackgroundSync()
        AppLogger.sync.debug("Background tasks registered: fetch and sync")
    }

    // Schedules a background app refresh task for processing the article queue.
    // Dynamically adjusts scheduling delay based on recency of app usage.
    // Uses BGAppRefreshTaskRequest which has limited configuration options but can run
    // in more restrictive conditions than processing tasks.
    func scheduleBackgroundFetch() {
        // For app refresh tasks, we need to use BGAppRefreshTaskRequest
        let request = BGAppRefreshTaskRequest(identifier: backgroundFetchIdentifier)

        // BGAppRefreshTaskRequest doesn't have network connectivity or power requirements settings
        // We can only set the earliest begin date for this type of request

        // Adjust the delay based on app usage patterns - longer delay if user just used app
        let lastActiveTime = UserDefaults.standard.double(forKey: "lastAppActiveTimestamp")
        let currentTime = Date().timeIntervalSince1970
        let minutesSinceActive = (currentTime - lastActiveTime) / 60

        // More dynamic scheduling - if recently used, delay more
        let delayMinutes = minutesSinceActive < 30 ? 15 : 5
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * Double(delayMinutes))

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background fetch scheduled in approximately \(delayMinutes) minutes")
        } catch {
            AppLogger.sync.error("Could not schedule background fetch: \(error)")
        }
    }

    // Schedules a background processing task for syncing with the server.
    // Dynamically sets power requirements based on queue size and time since last processing.
    // Ensures sync will happen eventually even if optimal conditions aren't met after 24 hours.
    // Requires network connectivity but adapts power requirements based on needs.
    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: backgroundSyncIdentifier)
        request.requiresNetworkConnectivity = true

        // Check cached system metrics for power requirements
        let pendingCount = UserDefaults.standard.integer(forKey: "articleMaintenanceMetric")
        let lastMetricUpdate = UserDefaults.standard.double(forKey: "metricLastUpdate")
        let currentTime = Date().timeIntervalSince1970

        // Only use metrics for power requirements if the data is recent (last 6 hours)
        if currentTime - lastMetricUpdate < 6 * 60 * 60 {
            // Require power for heavy processing needs
            request.requiresExternalPower = pendingCount > 10
        } else {
            // If we don't have recent data, be conservative
            request.requiresExternalPower = false
        }

        // Add a timeout mechanism - if maintenance hasn't run in 24 hours,
        // schedule it to run regardless of power state
        let lastMaintenanceTime = UserDefaults.standard.double(forKey: "lastMaintenanceTime")
        if currentTime - lastMaintenanceTime > 24 * 60 * 60 {
            request.requiresExternalPower = false
        }

        // Schedule with appropriate timing
        request.earliestBeginDate = Date(timeIntervalSinceNow: pendingCount > 10 ? 900 : 1800) // 15 or 30 mins

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background sync scheduled with power requirement: \(request.requiresExternalPower)")
        } catch {
            AppLogger.sync.error("Could not schedule background sync: \(error)")
        }
    }

    // Requests expedited background processing when needed.
    // Creates a minimal-requirements background task request to run as soon as possible.
    // Used when the system needs to process queue items with higher priority.
    func requestExpediteBackgroundProcessing() {
        // Request expedited processing only if truly needed
        let request = BGProcessingTaskRequest(identifier: backgroundFetchIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Consider user cellular preferences
        let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")

        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // Minimum 1 minute
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Expedited processing scheduled (cellular allowed: \(allowCellular))")
        } catch {
            AppLogger.sync.error("Could not schedule expedited processing: \(error)")
        }
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
    func manualSync() async -> Bool {
        // Only throttle explicit user actions
        let now = Date()
        guard now.timeIntervalSince(lastManualSyncTime) > manualSyncThrottle else {
            AppLogger.sync.debug("Manual sync requested too soon")
            return false
        }

        lastManualSyncTime = now
        await sendRecentArticlesToServer()
        return true
    }

    // Syncs recent article history with the server and retrieves unseen articles.
    // Uses a flag to prevent concurrent execution of multiple sync operations.
    // Checks network conditions before proceeding.
    // Sends recently seen article URLs to the server and processes any unseen articles returned.
    // Schedules the next background sync regardless of operation outcome.
    func sendRecentArticlesToServer() async {
        // Use a background task to prevent UI blocking
        Task.detached(priority: .utility) {
            // Try to acquire the sync lock, skip if already syncing
            if await !self.trySyncLock() {
                AppLogger.sync.debug("Sync already in progress, skipping")
                return
            }

            // Store sync start time for throttling
            let syncStartTime = Date()

            // Notify UI that sync has started
            await self.notifySyncStatusChanged(true)

            // Check if we should sync based on network conditions
            if await !self.shouldAllowSync() {
                AppLogger.sync.debug("Sync skipped due to network conditions")
                await self.notifySyncStatusChanged(false)

                // Clean up and return
                await self.releaseSyncLock()
                await MainActor.run {
                    self.lastManualSyncTime = syncStartTime
                }
                return
            }

            AppLogger.sync.debug("Starting server sync...")

            do {
                // Fetch recent article history
                let recentArticles = await self.fetchRecentArticles()
                let jsonUrls = recentArticles.map { $0.json_url }

                // Prepare the API request
                let url = URL(string: "https://api.arguspulse.com/articles/sync")!
                let payload = ["seen_articles": jsonUrls]

                // Create a task for the actual network request
                let syncTask = Task {
                    do {
                        // Perform the authenticated request
                        let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)

                        // Make sure we weren't cancelled during the request
                        try Task.checkCancellation()

                        // Parse the response
                        let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)

                        // Process any unseen articles the server returned
                        if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty {
                            AppLogger.sync.debug("Server returned \(unseenUrls.count) unseen articles")

                            // Process articles in background
                            await self.processArticlesDetached(urls: unseenUrls)

                            // Schedule maintenance but don't wait for it
                            self.startMaintenance()
                        } else {
                            AppLogger.sync.debug("No unseen articles to process")
                        }

                        // Sync completed successfully
                        await self.notifySyncStatusChanged(false)

                    } catch let error as URLError where error.code == .timedOut {
                        AppLogger.sync.error("Sync request timed out: \(error)")
                        await self.notifySyncStatusChanged(false, error: error)
                    } catch {
                        AppLogger.sync.error("Sync request failed: \(error)")
                        await self.notifySyncStatusChanged(false, error: error)
                    }
                }

                // Add a timeout to ensure we can recover from hangs
                try await self.withTimeout(of: 60) {
                    await syncTask.value
                }

            } catch is CancellationError {
                AppLogger.sync.debug("Sync operation was cancelled")
                await self.notifySyncStatusChanged(false)
            } catch is TimeoutError {
                AppLogger.sync.error("Sync operation timed out")
                await self.notifySyncStatusChanged(false, error: TimeoutError())
            } catch {
                AppLogger.sync.error("Sync operation failed: \(error)")
                await self.notifySyncStatusChanged(false, error: error)
            }

            // Always schedule next background sync before releasing lock
            await MainActor.run {
                self.scheduleBackgroundSync()
            }

            // Always release the lock and update last sync time
            await self.releaseSyncLock()
            await MainActor.run {
                self.lastManualSyncTime = syncStartTime
            }
        }
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

    // Process articles using the DatabaseCoordinator
    func processArticlesDirectly(urls: [String]) async {
        AppLogger.sync.debug("Processing \(urls.count) articles using DatabaseCoordinator")
        let result = await DatabaseCoordinator.shared.processArticles(jsonURLs: urls)
        AppLogger.sync.debug("Articles processed: \(result.success) succeeded, \(result.failure) failed, \(result.skipped) skipped")
    }

    // Process multiple articles in the background using DatabaseCoordinator's batch processing
    private func processArticlesDetached(urls: [String]) async {
        Task.detached(priority: .background) {
            AppLogger.sync.debug("🔄 Processing \(urls.count) articles directly in background task")

            // Global lock to ensure we're not processing during other operations
            guard await Self.acquireProcessingLockAsync() else {
                AppLogger.sync.debug("⚠️ Global processing already in progress, delaying batch processing")
                return
            }

            // Always release the global lock when done
            defer {
                Task { await Self.releaseProcessingLockAsync() }
            }

            // Register all URLs as being processed - this handles duplicate detection
            let registeredUrls = await withTaskGroup(of: (String, Bool).self, returning: [String].self) { group in
                for url in urls {
                    group.addTask {
                        let success = await Self.registerItemAsBeingProcessedAsync(url)
                        return (url, success)
                    }
                }

                var registeredUrls = [String]()
                for await (url, success) in group {
                    if success {
                        registeredUrls.append(url)
                    } else {
                        AppLogger.sync.debug("🔒 URL already being processed elsewhere, skipping: \(url)")
                    }
                }
                return registeredUrls
            }

            // Make sure we unregister all URLs when done
            defer {
                Task {
                    for url in registeredUrls {
                        await Self.unregisterItemAsProcessedAsync(url)
                    }
                }
            }

            // If we couldn't register any URLs, exit early
            if registeredUrls.isEmpty {
                AppLogger.sync.debug("No URLs available to process - all are being processed elsewhere")
                return
            }

            AppLogger.sync.debug("🔄 Direct batch processing \(registeredUrls.count) articles using DatabaseCoordinator")

            // Delegate the entire batch to DatabaseCoordinator - this significantly reduces
            // the number of database operations and badge count updates
            let result = await DatabaseCoordinator.shared.processArticles(jsonURLs: registeredUrls)

            // Log summary
            AppLogger.sync.debug("🔄 Batch processing completed: added \(result.success), failed \(result.failure), skipped \(result.skipped)")

            // Notify that all processing is complete (DatabaseCoordinator has already updated the badge count)
            await MainActor.run {
                NotificationCenter.default.post(name: .articleProcessingCompleted, object: nil)
            }
        }
    }

    // Process a single article in isolation to prevent UI blocking and conflicts
    // This implementation fully delegates to the DatabaseCoordinator
    private func processArticleIsolated(jsonURL: String, container _: ModelContainer? = nil) async -> (created: Int, updated: Int, failed: Int) {
        AppLogger.sync.debug("🔒 Processing article with DatabaseCoordinator: \(jsonURL)")

        do {
            // Use withTimeout to ensure the process doesn't hang
            return try await withTimeout(of: 30) {
                // Delegate to DatabaseCoordinator for the actual processing
                let success = await DatabaseCoordinator.shared.processArticle(jsonURL: jsonURL)

                if success {
                    // Since the DatabaseCoordinator doesn't tell us if it was a create or update,
                    // we return a generic success. The actual counts will be aggregated elsewhere.
                    return (1, 0, 0)
                } else {
                    return (0, 0, 1)
                }
            }
        } catch is TimeoutError {
            AppLogger.sync.error("🕒 Article processing timed out: \(jsonURL)")
            return (0, 0, 1)
        } catch {
            AppLogger.sync.error("❌ Unexpected error: \(error.localizedDescription)")
            return (0, 0, 1)
        }
    }
}
