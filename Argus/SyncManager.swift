import BackgroundTasks
import Foundation
import Network
import SwiftData
import UIKit

class SyncManager {
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

    // MARK: - Standardized Article Existence Checking

    // Standard method for checking if an article exists in the database
    // Checks by jsonURL, ID, and article_url for comprehensive duplicate detection
    // This is the single source of truth for article existence checking
    func standardizedArticleExistsCheck(jsonURL: String, articleID: UUID? = nil, articleURL: String? = nil, context: ModelContext) async -> Bool {
        // Create a debug identifier for tracing this specific check
        let checkID = UUID().uuidString.prefix(8)
        AppLogger.sync.debug("🔎 [\(checkID)] EXISTENCE CHECK START for \(jsonURL.suffix(40))")

        // CRITICAL DEBUGGING: Log IDs
        if let articleID = articleID {
            let idString = articleID.uuidString
            AppLogger.sync.debug("🔎 [\(checkID)] Checking ID: \(idString)")
        }

        // If a fresh context was provided, refresh it to see latest changes
        try? context.save()

        // TRY AGAIN WITH ALL DIRECT QUERIES - with detailed logging

        // Skip empty URL checks
        if !jsonURL.isEmpty {
            // First - most direct and efficient check by jsonURL
            var notificationFetchDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { notification in
                    notification.json_url == jsonURL
                }
            )
            notificationFetchDescriptor.fetchLimit = 1

            let notificationCount = (try? context.fetchCount(notificationFetchDescriptor)) ?? 0
            if notificationCount > 0 {
                AppLogger.sync.debug("🔎 [\(checkID)] Article exists in NotificationData by jsonURL: \(jsonURL)")
                return true
            }

            // Case-insensitive matching removed as server provides consistent URL format
        }

        // If we have an ID, check for that specifically (ID collisions would be critical duplicates)
        if let articleID = articleID {
            // Try exact match first
            var idFetchDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { notification in
                    notification.id == articleID
                }
            )
            idFetchDescriptor.fetchLimit = 1

            let idCount = (try? context.fetchCount(idFetchDescriptor)) ?? 0
            if idCount > 0 {
                AppLogger.sync.debug("🔎 [\(checkID)] Article exists in NotificationData by ID exact match: \(articleID)")
                return true
            }

            // VERY THOROUGH: Get ALL IDs and compare manually to ensure no UUID comparison bugs
            let allDescriptor = FetchDescriptor<NotificationData>()
            if let allNotifications = try? context.fetch(allDescriptor) {
                AppLogger.sync.debug("🔎 [\(checkID)] Checking against \(allNotifications.count) total notifications")

                for notification in allNotifications {
                    if notification.id == articleID {
                        AppLogger.sync.debug("🔎 [\(checkID)] MANUAL ID MATCH FOUND: \(notification.id) == \(articleID)")
                        return true
                    }
                }
            }
        }

        // If we have an article URL, check for that too
        if let articleURL = articleURL, !articleURL.isEmpty {
            var urlFetchDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { notification in
                    notification.article_url == articleURL
                }
            )
            urlFetchDescriptor.fetchLimit = 1

            let urlCount = (try? context.fetchCount(urlFetchDescriptor)) ?? 0
            if urlCount > 0 {
                AppLogger.sync.debug("🔎 [\(checkID)] Article exists in NotificationData by article_url: \(articleURL)")
                return true
            }
        }

        // Finally, check SeenArticle as a fallback (only if we have a non-empty URL)
        if !jsonURL.isEmpty {
            var seenFetchDescriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seen in
                    seen.json_url == jsonURL
                }
            )
            seenFetchDescriptor.fetchLimit = 1

            let seenCount = (try? context.fetchCount(seenFetchDescriptor)) ?? 0
            if seenCount > 0 {
                AppLogger.sync.debug("🔎 [\(checkID)] Article exists in SeenArticle by jsonURL: \(jsonURL)")
                return true
            }

            // Case-insensitive matching removed as server provides consistent URL format
        }

        // Check for matching UUID in SeenArticle if we have one
        if let articleID = articleID {
            var idSeenFetchDescriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seen in
                    seen.id == articleID
                }
            )
            idSeenFetchDescriptor.fetchLimit = 1

            let idSeenCount = (try? context.fetchCount(idSeenFetchDescriptor)) ?? 0
            if idSeenCount > 0 {
                AppLogger.sync.debug("🔎 [\(checkID)] Article exists in SeenArticle by ID: \(articleID)")
                return true
            }

            // Manual check of all SeenArticle entries for thoroughness
            let allSeenDescriptor = FetchDescriptor<SeenArticle>()
            if let allSeen = try? context.fetch(allSeenDescriptor) {
                for seen in allSeen {
                    if seen.id == articleID {
                        AppLogger.sync.debug("🔎 [\(checkID)] MANUAL ID MATCH FOUND IN SEEN: \(seen.id) == \(articleID)")
                        return true
                    }
                }
            }
        }

        AppLogger.sync.debug("🔎 [\(checkID)] NO MATCHES FOUND - article does not exist")
        return false
    }

    // Batch check for article existence - more efficient for multiple articles
    // Also checks for ID uniqueness to prevent duplicate IDs in the database
    func standardizedBatchArticleExistsCheck(jsonURLs: [String], ids: [UUID]? = nil, context: ModelContext) async -> (jsonURLs: Set<String>, ids: Set<UUID>) {
        var existingURLs = Set<String>()
        var existingIDs = Set<UUID>()

        // Early exit if there's nothing to check
        if jsonURLs.isEmpty {
            return (existingURLs, existingIDs)
        }

        // Perform efficient batch queries using 'contains' predicate
        do {
            // Check for already processed articles by URL
            let notificationDescriptor = FetchDescriptor<NotificationData>(
                predicate: #Predicate<NotificationData> { notification in
                    jsonURLs.contains(notification.json_url)
                }
            )

            let seenDescriptor = FetchDescriptor<SeenArticle>(
                predicate: #Predicate<SeenArticle> { seen in
                    jsonURLs.contains(seen.json_url)
                }
            )

            // Execute both queries for URL checks
            let existingNotifications = try context.fetch(notificationDescriptor)
            for notification in existingNotifications {
                existingURLs.insert(notification.json_url)
                existingIDs.insert(notification.id) // Also track IDs from these results
            }

            let existingSeenArticles = try context.fetch(seenDescriptor)
            for seen in existingSeenArticles {
                existingURLs.insert(seen.json_url)
                existingIDs.insert(seen.id)
            }

            // If we have IDs to check, do a separate query for those
            if let ids = ids, !ids.isEmpty {
                let idNotificationDescriptor = FetchDescriptor<NotificationData>(
                    predicate: #Predicate<NotificationData> { notification in
                        ids.contains(notification.id)
                    }
                )

                let idSeenDescriptor = FetchDescriptor<SeenArticle>(
                    predicate: #Predicate<SeenArticle> { seen in
                        ids.contains(seen.id)
                    }
                )

                // Execute both queries for ID checks
                let existingNotificationsByID = try context.fetch(idNotificationDescriptor)
                for notification in existingNotificationsByID {
                    existingIDs.insert(notification.id)
                    existingURLs.insert(notification.json_url) // Also track URLs from these results
                    AppLogger.sync.debug("Found existing article by ID: \(notification.id)")
                }

                let existingSeenArticlesByID = try context.fetch(idSeenDescriptor)
                for seen in existingSeenArticlesByID {
                    existingIDs.insert(seen.id)
                    existingURLs.insert(seen.json_url)
                }
            }

            if !existingURLs.isEmpty || !existingIDs.isEmpty {
                AppLogger.sync.debug("Found \(existingURLs.count) existing articles by URL and \(existingIDs.count) by ID in batch check")
            }
        } catch {
            AppLogger.sync.error("Error during batch article existence check: \(error)")
        }

        return (existingURLs, existingIDs)
    }

    // Compatibility method for existing code
    // Uses the standardized implementation to ensure consistent behavior
    func isArticleAlreadyProcessed(jsonURL: String, context: ModelContext) async -> Bool {
        return await standardizedArticleExistsCheck(jsonURL: jsonURL, context: context)
    }

    // Compatibility method for existing code
    // Uses the standardized implementation to ensure consistent behavior
    private func getExistingArticles(jsonURLs: [String], context: ModelContext) async throws -> Set<String> {
        let (existingURLs, _) = await standardizedBatchArticleExistsCheck(jsonURLs: jsonURLs, context: context)
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

        // Acquire the model container directly from the main thread
        let container = await MainActor.run { ArgusApp.sharedModelContainer }
        let context = ModelContext(container)

        // ENHANCED DEBUG: Add transaction isolation to existence check
        // First lock to prevent other processes from checking same article
        context.autosaveEnabled = false

        // Check if this article already exists - with additional logging
        let alreadyExists = await standardizedArticleExistsCheck(
            jsonURL: jsonURL,
            context: context
        )

        AppLogger.sync.debug("🔍 Existence check result for \(jsonURL): \(alreadyExists ? "EXISTS" : "NEW")")

        if alreadyExists {
            AppLogger.sync.debug("🚨 Article already exists in database, skipping: \(jsonURL)")
            return false
        }

        // CRITICAL: Add SEP entry to race-free tracking
        // This registers this article as "being processed" before we continue
        // to prevent any other concurrent processes from processing it
        guard Self.registerItemAsBeingProcessed(jsonURL) else {
            AppLogger.sync.debug("⚠️ Another process is already processing this article, exiting: \(jsonURL)")
            return false
        }

        // Make sure we unregister when we're done or fail
        defer {
            Self.unregisterItemAsProcessed(jsonURL)
        }

        // Extract UUID from the URL filename
        let notificationID: UUID

        // Extract from filename if possible
        let fileName = jsonURL.split(separator: "/").last ?? ""

        if let uuidRange = fileName.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) {
            let uuidString = String(fileName[uuidRange])
            if let uuid = UUID(uuidString: uuidString) {
                notificationID = uuid
                AppLogger.sync.debug("🔑 Using filename UUID: \(uuid)")
            } else {
                AppLogger.sync.debug("⚠️ Could not parse UUID from filename, skipping article")
                return false
            }
        } else {
            AppLogger.sync.debug("⚠️ No UUID found in filename, skipping article")
            return false
        }

        // Verify this ID doesn't already exist
        let idExists = await isIDAlreadyUsed(notificationID, context: context)
        if idExists {
            AppLogger.sync.debug("🚨 ID already exists in database, skipping: \(notificationID)")
            return false
        }

        // Process the article directly
        do {
            // Fetch the article JSON
            guard let url = URL(string: jsonURL) else {
                AppLogger.sync.error("❌ Invalid URL: \(jsonURL)")
                return false
            }

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)

            let (data, _) = try await session.data(from: url)

            // Parse the JSON
            guard let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.sync.error("❌ Invalid JSON data in response")
                return false
            }

            // Ensure the json_url is set
            var enrichedJson = rawJson
            if enrichedJson["json_url"] == nil {
                enrichedJson["json_url"] = jsonURL
            }

            // Process into article format
            guard let articleJSON = processArticleJSON(enrichedJson) else {
                AppLogger.sync.error("❌ Failed to process article JSON")
                return false
            }

            // Extract metadata
            let engineStatsJSON = extractEngineStats(from: enrichedJson)
            let similarArticlesJSON = extractSimilarArticles(from: enrichedJson)

            // Create the article
            let date = Date()

            AppLogger.sync.debug("📝 Creating article with ID: \(notificationID)")

            // Run in a transaction to ensure atomicity
            try context.transaction {
                let notification = NotificationData(
                    id: notificationID,
                    date: date,
                    title: articleJSON.title,
                    body: articleJSON.body,
                    json_url: articleJSON.jsonURL,
                    article_url: articleJSON.url,
                    topic: articleJSON.topic,
                    article_title: articleJSON.articleTitle,
                    affected: articleJSON.affected,
                    domain: articleJSON.domain,
                    pub_date: articleJSON.pubDate ?? date,
                    isViewed: false,
                    isBookmarked: false,
                    isArchived: false,
                    sources_quality: articleJSON.sourcesQuality,
                    argument_quality: articleJSON.argumentQuality,
                    source_type: articleJSON.sourceType,
                    source_analysis: articleJSON.sourceAnalysis,
                    quality: articleJSON.quality,
                    summary: articleJSON.summary,
                    critical_analysis: articleJSON.criticalAnalysis,
                    logical_fallacies: articleJSON.logicalFallacies,
                    relation_to_topic: articleJSON.relationToTopic,
                    additional_insights: articleJSON.additionalInsights,
                    engine_stats: engineStatsJSON,
                    similar_articles: similarArticlesJSON
                )

                let seenArticle = SeenArticle(
                    id: notificationID,
                    json_url: articleJSON.jsonURL,
                    date: date
                )

                // Insert into database
                context.insert(notification)
                context.insert(seenArticle)

                // Pre-generate text attributes
                _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
                _ = getAttributedString(for: .body, from: notification, createIfMissing: true)
            }

            // Save changes
            try context.save()

            // Update the badge count
            await MainActor.run {
                NotificationUtils.updateAppBadgeCount()
            }

            AppLogger.sync.debug("✅ Article successfully saved with ID: \(notificationID)")
            return true
        } catch {
            AppLogger.sync.error("❌ Error processing article: \(error.localizedDescription)")
            return false
        }
    }

    // Run a scheduled database maintenance task
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

        // Perform maintenance operations here if needed
        // Currently just updating metrics

        // Update maintenance metrics
        UserDefaults.standard.set(0, forKey: "articleMaintenanceMetric")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastMaintenanceTime")

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
    private static var processingLock = NSLock()

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
        // Simple guard against concurrent execution
        guard !syncInProgress else {
            AppLogger.sync.debug("Sync already in progress, skipping")
            return
        }

        // Check network conditions before proceeding
        guard await shouldAllowSync() else {
            AppLogger.sync.debug("Sync skipped due to network conditions and user preferences")
            return
        }

        // Set flag to prevent concurrent execution
        syncInProgress = true
        defer {
            syncInProgress = false
            // Update last sync time only for throttling manual actions
            lastManualSyncTime = Date()
        }

        AppLogger.sync.debug("Starting server sync...")

        do {
            let recentArticles = await fetchRecentArticles()
            let jsonUrls = recentArticles.map { $0.json_url }

            // APIClient handles timeouts internally
            let url = URL(string: "https://api.arguspulse.com/articles/sync")!
            let payload = ["seen_articles": jsonUrls]

            do {
                let data = try await APIClient.shared.performAuthenticatedRequest(to: url, body: payload)
                let serverResponse = try JSONDecoder().decode([String: [String]].self, from: data)

                if let unseenUrls = serverResponse["unseen_articles"], !unseenUrls.isEmpty {
                    AppLogger.sync.debug("Server returned \(unseenUrls.count) unseen articles - processing directly")
                    await processArticlesDirectly(urls: unseenUrls)

                    // Start maintenance after processing
                    startMaintenance()
                } else {
                    AppLogger.sync.debug("Server says there are no unseen articles.")
                }
            } catch let error as URLError where error.code == .timedOut {
                AppLogger.sync.error("Sync operation timed out")
            }
        } catch {
            AppLogger.sync.error("Failed to sync articles: \(error)")
        }

        // Always schedule next background sync
        await MainActor.run {
            self.scheduleBackgroundSync()
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

    // Retrieves article records from the last 24 hours.
    // Used to build the list of seen articles to send to the server during sync.
    // Executes on the main actor to access the shared model container.
    private func fetchRecentArticles() async -> [SeenArticle] {
        await MainActor.run {
            let oneDayAgo = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
            let context = ArgusApp.sharedModelContainer.mainContext
            return (try? context.fetch(FetchDescriptor<SeenArticle>(
                predicate: #Predicate { $0.date >= oneDayAgo }
            ))) ?? []
        }
    }

    // Process articles directly, bypassing the queue entirely
    // This is the single source of truth for article processing
    func processArticlesDirectly(urls: [String]) async {
        AppLogger.sync.debug("🔄 Processing \(urls.count) articles directly (bypassing queue)")

        // Global lock to ensure we're not processing during other ops
        guard Self.acquireProcessingLock() else {
            AppLogger.sync.debug("⚠️ Global processing already in progress, delaying batch processing")
            return
        }

        // Always release the global lock when done
        defer {
            Self.releaseProcessingLock()
        }

        // CRITICAL: Register all URLs as being processed right at the start
        // to prevent any race conditions with other processes
        var urlsToProcess = [String]()
        for url in urls {
            if Self.registerItemAsBeingProcessed(url) {
                urlsToProcess.append(url)
            } else {
                AppLogger.sync.debug("🔒 URL already being processed elsewhere, skipping: \(url)")
            }
        }

        // If we couldn't register any URLs, exit early
        if urlsToProcess.isEmpty {
            AppLogger.sync.debug("No URLs available to process - all are being processed elsewhere")
            return
        }

        // Make sure we unregister all URLs when done
        defer {
            for url in urlsToProcess {
                Self.unregisterItemAsProcessed(url)
            }
        }

        let container = await MainActor.run { ArgusApp.sharedModelContainer }

        // Create our own context for thread safety
        let backgroundContext = ModelContext(container)
        backgroundContext.autosaveEnabled = false

        // Run an existence check with explicit logging for debugging
        AppLogger.sync.debug("🔍 BATCH EXISTENCE CHECK: Running check for \(urlsToProcess.count) URLs")
        let (existingURLs, existingIDs) = await standardizedBatchArticleExistsCheck(
            jsonURLs: urlsToProcess,
            context: backgroundContext
        )

        if !existingURLs.isEmpty {
            AppLogger.sync.debug("🔍 BATCH EXISTENCE CHECK: Found \(existingURLs.count) existing URLs")
            for url in existingURLs {
                AppLogger.sync.debug("🔍 BATCH EXISTENCE CHECK: Existing URL: \(url)")
            }
        }

        if !existingIDs.isEmpty {
            AppLogger.sync.debug("🔍 BATCH EXISTENCE CHECK: Found \(existingIDs.count) existing IDs")
            for id in existingIDs {
                AppLogger.sync.debug("🔍 BATCH EXISTENCE CHECK: Existing ID: \(id)")
            }
        }

        // Filter out any URLs that already exist in the database
        let newUrls = urlsToProcess.filter { !existingURLs.contains($0) }

        if newUrls.isEmpty {
            AppLogger.sync.debug("🚫 No new articles to process - all URLs already in database")
            return
        }

        // Process one article at a time to avoid transaction conflicts
        var successCount = 0
        var failureCount = 0

        AppLogger.sync.debug("🔄 Direct processing \(newUrls.count) new articles")

        for jsonURL in newUrls {
            // CRITICAL POINT: We're already holding the global lock,
            // so DON'T call directProcessArticle which would try to acquire the same lock again
            // Instead, do direct processing here with a different context

            // Create a fresh context for this article
            let articleContext = ModelContext(container)
            articleContext.autosaveEnabled = false

            // Extract UUID from the URL filename for additional debugging
            let fileName = jsonURL.split(separator: "/").last ?? ""
            var notificationID: UUID?

            if let uuidRange = fileName.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) {
                let uuidString = String(fileName[uuidRange])
                if let uuid = UUID(uuidString: uuidString) {
                    notificationID = uuid
                    AppLogger.sync.debug("🔍 Processing article with UUID from filename: \(uuid)")
                }
            }

            if notificationID == nil {
                AppLogger.sync.debug("⚠️ No UUID found in filename, skipping article: \(jsonURL)")
                failureCount += 1
                continue
            }

            // Double-check this ID and URL don't already exist
            let idExists = await isIDAlreadyUsed(notificationID!, context: articleContext)
            let urlExists = await standardizedArticleExistsCheck(jsonURL: jsonURL, context: articleContext)

            if idExists || urlExists {
                AppLogger.sync.debug("🚨 Article ID or URL already exists, skipping: \(jsonURL)")
                failureCount += 1
                continue
            }

            // Process the article
            do {
                // Fetch the article JSON
                guard let url = URL(string: jsonURL) else {
                    AppLogger.sync.error("❌ Invalid URL: \(jsonURL)")
                    failureCount += 1
                    continue
                }

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 15
                config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config)

                let (data, _) = try await session.data(from: url)

                // Parse the JSON
                guard let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    AppLogger.sync.error("❌ Invalid JSON data in response")
                    failureCount += 1
                    continue
                }

                // Ensure the json_url is set
                var enrichedJson = rawJson
                if enrichedJson["json_url"] == nil {
                    enrichedJson["json_url"] = jsonURL
                }

                // Process into article format
                guard let articleJSON = processArticleJSON(enrichedJson) else {
                    AppLogger.sync.error("❌ Failed to process article JSON")
                    failureCount += 1
                    continue
                }

                // Extract metadata
                let engineStatsJSON = extractEngineStats(from: enrichedJson)
                let similarArticlesJSON = extractSimilarArticles(from: enrichedJson)

                // Create the article
                let date = Date()

                AppLogger.sync.debug("📝 Creating article with ID: \(notificationID!)")

                // Run in a transaction to ensure atomicity
                try articleContext.transaction {
                    let notification = NotificationData(
                        id: notificationID!,
                        date: date,
                        title: articleJSON.title,
                        body: articleJSON.body,
                        json_url: articleJSON.jsonURL,
                        article_url: articleJSON.url,
                        topic: articleJSON.topic,
                        article_title: articleJSON.articleTitle,
                        affected: articleJSON.affected,
                        domain: articleJSON.domain,
                        pub_date: articleJSON.pubDate ?? date,
                        isViewed: false,
                        isBookmarked: false,
                        isArchived: false,
                        sources_quality: articleJSON.sourcesQuality,
                        argument_quality: articleJSON.argumentQuality,
                        source_type: articleJSON.sourceType,
                        source_analysis: articleJSON.sourceAnalysis,
                        quality: articleJSON.quality,
                        summary: articleJSON.summary,
                        critical_analysis: articleJSON.criticalAnalysis,
                        logical_fallacies: articleJSON.logicalFallacies,
                        relation_to_topic: articleJSON.relationToTopic,
                        additional_insights: articleJSON.additionalInsights,
                        engine_stats: engineStatsJSON,
                        similar_articles: similarArticlesJSON
                    )

                    let seenArticle = SeenArticle(
                        id: notificationID!,
                        json_url: articleJSON.jsonURL,
                        date: date
                    )

                    // Insert into database
                    articleContext.insert(notification)
                    articleContext.insert(seenArticle)

                    // Pre-generate text attributes
                    _ = getAttributedString(for: .title, from: notification, createIfMissing: true)
                    _ = getAttributedString(for: .body, from: notification, createIfMissing: true)
                }

                // Save changes
                try articleContext.save()

                // Update the badge count
                await MainActor.run {
                    NotificationUtils.updateAppBadgeCount()
                }

                AppLogger.sync.debug("✅ Article successfully saved with ID: \(notificationID!)")
                successCount += 1
            } catch {
                AppLogger.sync.error("❌ Error processing article: \(error.localizedDescription)")
                failureCount += 1
            }
            // Note: Success or failure is already handled in the try/catch block above
        }

        // Log summary
        AppLogger.sync.debug("🔄 Direct processing completed: added \(successCount), failed \(failureCount), skipped \(existingURLs.count)")
    }
}
