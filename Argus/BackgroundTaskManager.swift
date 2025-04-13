import BackgroundTasks
import Foundation
import Network
import SwiftData
import UIKit

/// Manages background tasks registration, scheduling, and execution using modern Swift concurrency
final class BackgroundTaskManager {
    // MARK: - Singleton

    static let shared = BackgroundTaskManager()

    // MARK: - Task Identifiers

    // Keep the same identifiers as SyncManager for continuity
    private let backgroundRefreshIdentifier = "com.arguspulse.articlefetch"
    private let backgroundProcessingIdentifier = "com.arguspulse.articlesync"

    // MARK: - State Tracking

    private var isRegistered = false

    // MARK: - Init

    private init() {}

    // MARK: - Registration

    /// Registers all background tasks with the system
    func registerBackgroundTasks() {
        guard !isRegistered else { return }

        // Register refresh task (for quick operations)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let refreshTask = task as? BGAppRefreshTask else { return }
            self.handleRefreshTask(refreshTask)
        }

        // Register processing task (for longer operations)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundProcessingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(processingTask)
        }

        isRegistered = true
        AppLogger.sync.debug("Background tasks registered successfully")

        // Schedule initial tasks
        scheduleBackgroundRefresh()
        scheduleBackgroundProcessing()
    }

    // MARK: - Scheduling

    /// Schedules a background app refresh task (shorter, more frequent)
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)

        // Keep the same scheduling logic as SyncManager for consistency
        let lastActiveTime = UserDefaults.standard.double(forKey: "lastAppActiveTimestamp")
        let currentTime = Date().timeIntervalSince1970
        let minutesSinceActive = (currentTime - lastActiveTime) / 60

        let delayMinutes = minutesSinceActive < 30 ? 15 : 5
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * Double(delayMinutes))

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background refresh scheduled in ~\(delayMinutes) minutes")
        } catch {
            AppLogger.sync.error("Could not schedule background refresh: \(error)")
        }
    }

    /// Schedules a background processing task (longer, less frequent)
    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: backgroundProcessingIdentifier)
        request.requiresNetworkConnectivity = true

        // Maintain the same power requirement logic as SyncManager
        let pendingCount = UserDefaults.standard.integer(forKey: "articleMaintenanceMetric")
        let lastMetricUpdate = UserDefaults.standard.double(forKey: "metricLastUpdate")
        let currentTime = Date().timeIntervalSince1970

        if currentTime - lastMetricUpdate < 6 * 60 * 60 {
            request.requiresExternalPower = pendingCount > 10
        } else {
            request.requiresExternalPower = false
        }

        let lastMaintenanceTime = UserDefaults.standard.double(forKey: "lastMaintenanceTime")
        if currentTime - lastMaintenanceTime > 24 * 60 * 60 {
            request.requiresExternalPower = false
        }

        request.earliestBeginDate = Date(timeIntervalSinceNow: pendingCount > 10 ? 900 : 1800)

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.sync.debug("Background processing scheduled with power requirement: \(request.requiresExternalPower)")
        } catch {
            AppLogger.sync.error("Could not schedule background processing: \(error)")
        }
    }

    // MARK: - Task Handlers

    /// Handles the BGAppRefreshTask execution
    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        // Create a task for execution that can be cancelled
        let refreshOperation = Task {
            // Check network conditions first
            let networkAllowed = await shouldAllowSync()

            if networkAllowed {
                do {
                    // Use the same sync pattern as SyncManager but with modern implementation
                    try await fetchRecentArticlesAndSync(timeLimit: 25)
                    task.setTaskCompleted(success: true)
                } catch {
                    AppLogger.sync.error("Background refresh failed: \(error)")
                    task.setTaskCompleted(success: false)
                }
            } else {
                AppLogger.sync.debug("Background refresh skipped - network not available")
                task.setTaskCompleted(success: false)
            }
        }

        // Set up proper cancellation
        task.expirationHandler = {
            refreshOperation.cancel()
            AppLogger.sync.debug("Background refresh task expired")
        }

        // Schedule the next refresh after this completes
        Task {
            // Wait for operation to complete or fail
            _ = await refreshOperation.result
            await MainActor.run {
                self.scheduleBackgroundRefresh()
            }
        }
    }

    /// Handles the BGProcessingTask execution
    private func handleProcessingTask(_ task: BGProcessingTask) {
        // Create a task for execution that can be cancelled
        let processingOperation = Task {
            // Check network conditions
            let networkAllowed = await shouldAllowSync()

            if networkAllowed {
                do {
                    // Perform full background sync
                    try await fetchRecentArticlesAndSync(timeLimit: 60)

                    // Update last maintenance time
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastMaintenanceTime")

                    task.setTaskCompleted(success: true)
                } catch {
                    AppLogger.sync.error("Background processing failed: \(error)")
                    task.setTaskCompleted(success: false)
                }
            } else {
                AppLogger.sync.debug("Background processing skipped - network not available")
                task.setTaskCompleted(success: false)
            }
        }

        // Set up proper cancellation
        task.expirationHandler = {
            processingOperation.cancel()
            AppLogger.sync.debug("Background processing task expired")
        }

        // Schedule the next processing after this completes
        Task {
            // Wait for operation to complete or fail
            _ = await processingOperation.result
            await MainActor.run {
                self.scheduleBackgroundProcessing()
            }
        }
    }

    // MARK: - Core Sync Implementation

    /// Fetches recent articles and syncs with the server
    /// - Parameter timeLimit: Optional time limit in seconds
    /// - Throws: TimeoutError or any error from the sync process
    private func fetchRecentArticlesAndSync(timeLimit: TimeInterval?) async throws {
        AppLogger.sync.debug("Starting article sync with server")

        // Create task with timeout if specified
        if let timeLimit = timeLimit {
            try await withTimeout(of: timeLimit) {
                try await self.performSync()
            }
        } else {
            try await performSync()
        }
    }

    /// Performs the actual sync process - preserving exact API compatibility
    /// - Throws: Any error from the API or database operations
    private func performSync() async throws {
        // 1. Get recently seen article URLs (modified for Swift 6 sendability)
        let jsonUrls = await fetchRecentArticles()

        // 2. Sync with server using APIClient - maintain same API interaction
        let unseenUrls = try await APIClient.shared.syncArticles(seenArticles: jsonUrls)

        if !unseenUrls.isEmpty {
            AppLogger.sync.debug("Server returned \(unseenUrls.count) unseen articles")

            // 3. Process unseen articles in batches
            await processArticlesInBatches(urls: unseenUrls)
        } else {
            AppLogger.sync.debug("No unseen articles found")
        }

        // 4. Update badge count
        await MainActor.run {
            NotificationUtils.updateAppBadgeCount()
        }
    }

    /// Fetches recent article URLs for syncing - modified for Swift 6 sendability
    private func fetchRecentArticles() async -> [String] {
        let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()

        // Use the new method that returns Sendable String URLs directly
        return await DatabaseCoordinator.shared.fetchRecentArticleURLs(since: oneDayAgo)
    }

    /// Processes articles in batches
    private func processArticlesInBatches(urls: [String]) async {
        // Use the same pattern as SyncManager but with optimized batching
        let batchSize = 10
        let uniqueUrls = Array(Set(urls))
        var processedCount = 0

        for batch in stride(from: 0, to: uniqueUrls.count, by: batchSize) {
            let end = min(batch + batchSize, uniqueUrls.count)
            let batchUrls = Array(uniqueUrls[batch ..< end])

            // Capture and log the result
            let batchResult = await DatabaseCoordinator.shared.processArticles(jsonURLs: batchUrls)
            processedCount += batchResult.success + batchResult.skipped

            AppLogger.sync.debug("Processed batch of \(batchUrls.count) articles. Successes: \(batchResult.success), Failures: \(batchResult.failure), Skipped: \(batchResult.skipped)")

            // Short pause between batches to avoid overwhelming the system
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        AppLogger.sync.debug("Completed processing \(processedCount) articles in \(uniqueUrls.count) batches")
    }

    /// Helper function for timeout operations
    private func withTimeout<T>(of seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
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

    // Custom timeout error
    struct TimeoutError: Error, LocalizedError {
        var errorDescription: String? {
            return "Operation timed out"
        }
    }

    // MARK: - Network Checking

    /// Checks if network conditions allow syncing
    private func shouldAllowSync() async -> Bool {
        // Use the same network check pattern as SyncManager
        return await withCheckedContinuation { continuation in
            let networkMonitor = NWPathMonitor()

            networkMonitor.pathUpdateHandler = { path in
                defer {
                    networkMonitor.cancel()
                }

                if path.usesInterfaceType(.wifi) {
                    continuation.resume(returning: true)
                } else if path.usesInterfaceType(.cellular) {
                    let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")
                    continuation.resume(returning: allowCellular)
                } else if path.status == .satisfied {
                    // Other connection types
                    let allowCellular = UserDefaults.standard.bool(forKey: "allowCellularSync")
                    continuation.resume(returning: allowCellular)
                } else {
                    continuation.resume(returning: false)
                }
            }

            networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}
