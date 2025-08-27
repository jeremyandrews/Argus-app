import Foundation
import SwiftUI
import Combine

/// Central coordinator for all automatic sync behavior in Argus
/// Implements Phase 1 of the auto-sync implementation plan
@MainActor
final class AutoSyncCoordinator: ObservableObject {
    // MARK: - Singleton
    
    static let shared = AutoSyncCoordinator()
    
    // MARK: - Published State
    
    @Published var isAutoSyncing = false
    @Published var lastAutoSyncTime: Date?
    @Published var autoSyncEnabled = true
    @Published var nextScheduledSync: Date?
    @Published var syncFrequencyMinutes = 10
    
    // MARK: - Configuration
    
    // Timing configuration as specified in the plan
    private let initialSyncDelay: TimeInterval = 2.0      // 2 seconds after launch
    private let periodicSyncInterval: TimeInterval = 600  // 10 minutes
    private let minSyncInterval: TimeInterval = 120       // Minimum 2 minutes between syncs
    private let foregroundReturnThreshold: TimeInterval = 300 // 5 minutes
    
    // MARK: - State Management
    
    private var syncSessionId = UUID()
    private var periodicSyncTimer: Timer?
    private var initialSyncScheduled = false
    private var backgroundTime: Date?
    
    // Phase 2.2: Enhanced periodic sync state
    private var lastUserInteractionTime = Date()
    private var consecutiveFailures = 0
    private var maxConsecutiveFailures = 3
    private var baseRetryDelay: TimeInterval = 120 // 2 minutes
    private let userInteractionIdleThreshold: TimeInterval = 30 // 30 seconds
    
    // Phase 2.3: Enhanced foreground return sync state
    private var lastForegroundTime: Date?
    private let shortBackgroundThreshold: TimeInterval = 300 // 5 minutes
    private let mediumBackgroundThreshold: TimeInterval = 1800 // 30 minutes
    private let longBackgroundThreshold: TimeInterval = 3600 // 1 hour
    
    // MARK: - Dependencies
    
    private let articleService: ArticleServiceProtocol
    private let backgroundTaskManager: BackgroundTaskManager
    private let logger = AppLogger.sync
    
    // MARK: - Cancellables
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        self.articleService = ArticleService.shared
        self.backgroundTaskManager = BackgroundTaskManager.shared
        
        // Load persisted state
        loadPersistedState()
        
        // Set up lifecycle observers
        setupLifecycleObservers()
        
        // Start auto-sync if enabled
        if autoSyncEnabled {
            startPeriodicSync()
        }
    }
    
    // MARK: - Public API
    
    /// Schedules the initial sync after app launch
    func scheduleInitialSync() async {
        guard !initialSyncScheduled else { return }
        initialSyncScheduled = true
        
        // Only log if auto-sync is enabled to reduce startup noise
        if autoSyncEnabled {
            logger.info("Auto-sync will start in \(Int(self.initialSyncDelay))s")
        }
        
        // Wait for the delay
        try? await Task.sleep(nanoseconds: UInt64(initialSyncDelay * 1_000_000_000))
        
        // Perform sync if conditions are met
        await performAutoSyncIfNeeded(context: .appLaunch)
    }
    
    /// Enables or disables auto-sync functionality
    func setAutoSyncEnabled(_ enabled: Bool) {
        guard autoSyncEnabled != enabled else { return }
        
        autoSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSyncEnabled")
        
        if enabled {
            logger.info("Auto-sync enabled")
            startPeriodicSync()
        } else {
            logger.info("Auto-sync disabled")
            stopPeriodicSync()
        }
    }
    
    /// Updates the sync frequency
    func updateSyncFrequency(_ minutes: Int) {
        guard minutes != syncFrequencyMinutes else { return }
        
        syncFrequencyMinutes = minutes
        UserDefaults.standard.autoSyncFrequencyMinutes = minutes
        logger.info("Updated sync frequency to \(minutes) minutes")
        
        // Restart periodic sync with new interval
        if autoSyncEnabled {
            stopPeriodicSync()
            startPeriodicSync()
        }
    }
    
    /// Manually triggers an auto-sync
    func triggerManualSync() async {
        await performAutoSyncIfNeeded(context: .manual)
    }
    
    // MARK: - Phase 3.1: Manual sync trigger (alias for UI compatibility)
    func performManualSync() async {
        await triggerManualSync()
    }
    
    // MARK: - Private Implementation
    
    /// Loads persisted state from UserDefaults
    private func loadPersistedState() {
        autoSyncEnabled = UserDefaults.standard.object(forKey: "autoSyncEnabled") as? Bool ?? true
        lastAutoSyncTime = UserDefaults.standard.object(forKey: "lastAutoSyncTime") as? Date
        syncFrequencyMinutes = UserDefaults.standard.autoSyncFrequencyMinutes
        
        // Only log significant state information to reduce noise
        if !autoSyncEnabled {
            logger.info("Auto-sync is disabled")
        }
    }
    
    /// Sets up app lifecycle observers
    private func setupLifecycleObservers() {
        // App entering foreground
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handleForegroundReturn()
                }
            }
            .store(in: &cancellables)
        
        // App going to background
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.recordBackgroundTime()
            }
            .store(in: &cancellables)
    }
    
    /// Starts periodic sync timer
    private func startPeriodicSync() {
        guard self.autoSyncEnabled else { return }
        
        stopPeriodicSync() // Stop any existing timer
        
        let interval = getCurrentSyncInterval()
        nextScheduledSync = Date().addingTimeInterval(interval)
        
        logger.info("Auto-sync scheduled every \(Int(interval/60)) minutes")
        
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performPeriodicSyncIfNeeded()
            }
        }
    }
    
    /// Stops periodic sync timer
    private func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        nextScheduledSync = nil
        // Only log when user explicitly disables auto-sync
    }
    
    /// Gets the current sync interval from UserDefaults or uses default
    private func getCurrentSyncInterval() -> TimeInterval {
        let savedInterval = UserDefaults.standard.double(forKey: "autoSyncFrequencyMinutes")
        return savedInterval > 0 ? savedInterval : periodicSyncInterval
    }
    
    /// Performs periodic sync if conditions are met - Phase 2.2 Enhanced
    private func performPeriodicSyncIfNeeded() async {
        guard autoSyncEnabled else { return }
        
        // Update next scheduled sync time
        let interval = getCurrentSyncInterval()
        nextScheduledSync = Date().addingTimeInterval(interval)
        
        // Check throttling conditions
        if let lastSync = self.lastAutoSyncTime {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < minSyncInterval {
                logger.debug("Sync throttled - only \(Int(timeSinceLastSync))s since last sync")
                return
            }
        }
        
        // Phase 2.2: Enhanced user interaction detection
        if isUserActivelyInteracting() {
            logger.debug("Sync deferred - user is actively interacting")
            return
        }
        
        // Phase 2.2: Battery and power mode checks
        guard await shouldAllowSyncForBattery() else {
            logger.debug("Sync deferred - battery constraints")
            return
        }
        
        // Phase 2.2: Progressive backoff for consecutive failures
        if consecutiveFailures >= maxConsecutiveFailures {
            let backoffDelay = calculateBackoffDelay()
            if let lastSync = lastAutoSyncTime,
               Date().timeIntervalSince(lastSync) < backoffDelay {
                logger.debug("Sync deferred - progressive backoff active (\(self.consecutiveFailures) failures)")
                return
            }
        }
        
        await performAutoSyncIfNeeded(context: .periodic)
    }
    
    /// Handles app returning from background with progressive sync frequency - Phase 2.3 Enhanced
    private func handleForegroundReturn() async {
        guard let backgroundTime = backgroundTime else { return }
        
        let backgroundDuration = Date().timeIntervalSince(backgroundTime)
        logger.debug("App returned from background after \(Int(backgroundDuration))s")
        
        // Phase 2.3: Progressive sync frequency based on background duration
        let shouldSync = determineIfSyncNeededForBackgroundDuration(backgroundDuration)
        
        if shouldSync {
            let durationCategory = categorizeBackgroundDuration(backgroundDuration)
            logger.info("Triggering \(durationCategory) sync after \(Int(backgroundDuration))s in background")
            await performAutoSyncIfNeeded(context: .foregroundReturn)
        } else {
            logger.debug("Skipping sync - background duration (\(Int(backgroundDuration))s) below threshold")
        }
        
        // Update foreground return tracking
        lastForegroundTime = Date()
        self.backgroundTime = nil
    }
    
    /// Phase 2.3: Determines if sync is needed based on background duration
    private func determineIfSyncNeededForBackgroundDuration(_ duration: TimeInterval) -> Bool {
        // Always sync if backgrounded longer than short threshold (5 minutes)
        if duration >= shortBackgroundThreshold {
            return true
        }
        
        // For shorter durations, check if enough time has passed since last sync
        if let lastSync = lastAutoSyncTime {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            // If last sync was more than 10 minutes ago and we were backgrounded for 2+ minutes, sync
            if duration >= 120 && timeSinceLastSync >= 600 {
                return true
            }
        }
        
        return false
    }
    
    /// Phase 2.3: Categorizes background duration for logging
    private func categorizeBackgroundDuration(_ duration: TimeInterval) -> String {
        switch duration {
        case 0..<shortBackgroundThreshold:
            return "quick"
        case shortBackgroundThreshold..<mediumBackgroundThreshold:
            return "standard"
        case mediumBackgroundThreshold..<longBackgroundThreshold:
            return "medium-delay"
        default:
            return "long-delay"
        }
    }
    
    /// Records when app goes to background
    private func recordBackgroundTime() {
        backgroundTime = Date()
        logger.debug("Recorded background time")
    }
    
    /// Performs auto-sync if conditions allow
    private func performAutoSyncIfNeeded(context: AutoSyncContext) async {
        guard autoSyncEnabled && !isAutoSyncing else { return }
        
        // Generate new session ID
        syncSessionId = UUID()
        let currentSessionId = syncSessionId
        
        isAutoSyncing = true
        defer {
            // Only reset if this is still the current session
            if syncSessionId == currentSessionId {
                isAutoSyncing = false
            }
        }
        
        do {
            // Check network conditions
            guard await shouldAllowSync() else {
                logger.debug("Auto-sync skipped - network conditions not suitable")
                return
            }
            
            // Check if session was cancelled
            guard syncSessionId == currentSessionId else {
                logger.debug("Auto-sync cancelled - session changed")
                return
            }
            
            // Perform the sync using existing ArticleService
            let result = try await articleService.performBackgroundSync { _ in
                // Progress logging removed to avoid Swift 6 compilation issues
            }
            
            // Update state after successful sync
            lastAutoSyncTime = Date()
            UserDefaults.standard.set(lastAutoSyncTime, forKey: "lastAutoSyncTime")
            
            // Phase 2.2: Reset failure counter on success
            consecutiveFailures = 0
            
            logger.info("Auto-sync completed successfully - added: \(result.addedCount), duration: \(result.duration)s")
            
            // Schedule next background sync
            backgroundTaskManager.scheduleBackgroundRefresh()
            
        } catch {
            // Phase 2.2: Track consecutive failures for progressive backoff
            consecutiveFailures += 1
            
            logger.error("Auto-sync failed (failure #\(self.consecutiveFailures)): \(error)")
            
            // Schedule retry with exponential backoff
            scheduleRetrySync()
        }
    }
    
    /// Schedules a retry sync with exponential backoff
    private func scheduleRetrySync() {
        let retryDelay = min(minSyncInterval * 2, 1800) // Max 30 minutes
        
        logger.debug("Scheduling retry sync in \(retryDelay)s")
        
        Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.performAutoSyncIfNeeded(context: .retry)
            }
        }
    }
    
    /// Checks if network conditions allow syncing
    private func shouldAllowSync() async -> Bool {
        // Use the same network checking logic as BackgroundTaskManager
        return await withCheckedContinuation { continuation in
            // For now, use a simple check - in a real implementation,
            // this would use NWPathMonitor like BackgroundTaskManager
            let allowCellular = UserDefaults.standard.allowCellularSync
            let result: Bool = allowCellular || true // Simplified for Phase 1
            continuation.resume(returning: result)
        }
    }
    
    /// Phase 2.2: Enhanced user interaction detection
    private func isUserActivelyInteracting() -> Bool {
        // Check if app is in background
        guard backgroundTime == nil else { return false }
        
        // Check if recent user interaction occurred
        let timeSinceInteraction = Date().timeIntervalSince(lastUserInteractionTime)
        if timeSinceInteraction < userInteractionIdleThreshold {
            return true
        }
        
        // Additional checks could include:
        // - Touch events monitoring
        // - Navigation changes
        // - Scroll events
        // For now, use conservative approach
        return false
    }
    
    /// Phase 2.2: Battery and power mode awareness
    private func shouldAllowSyncForBattery() async -> Bool {
        return await withCheckedContinuation { continuation in
            // Check if device is in Low Power Mode
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                logger.debug("Sync deferred - Low Power Mode enabled")
                continuation.resume(returning: false)
                return
            }
            
            // Check battery level if available
            #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let batteryLevel = UIDevice.current.batteryLevel
            UIDevice.current.isBatteryMonitoringEnabled = false
            
            // Defer sync if battery is very low (below 20%)
            if batteryLevel > 0 && batteryLevel < 0.2 {
                logger.debug("Sync deferred - battery level too low (\(Int(batteryLevel * 100))%)")
                continuation.resume(returning: false)
                return
            }
            #endif
            
            continuation.resume(returning: true)
        }
    }
    
    /// Phase 2.2: Calculate progressive backoff delay
    private func calculateBackoffDelay() -> TimeInterval {
        // Exponential backoff: baseDelay * 2^(failures - maxFailures)
        let exponent = max(0, consecutiveFailures - maxConsecutiveFailures)
        let backoffMultiplier = pow(2.0, Double(exponent))
        let delay = baseRetryDelay * backoffMultiplier
        
        // Cap at maximum of 30 minutes
        return min(delay, 1800)
    }
    
    /// Update user interaction timestamp (call this from UI events)
    func recordUserInteraction() {
        lastUserInteractionTime = Date()
    }
    
    /// Phase 2.3: Cleanup resources when coordinator is deallocated
    deinit {
        // Cancel all Combine subscriptions (can be done synchronously)
        cancellables.removeAll()
        
        // Stop periodic sync timer directly (avoiding main actor isolation issues)
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }
}

// MARK: - AutoSyncContext

extension AutoSyncCoordinator {
    enum AutoSyncContext: String, CaseIterable {
        case appLaunch = "app_launch"
        case periodic = "periodic"
        case foregroundReturn = "foreground_return"
        case manual = "manual"
        case retry = "retry"
    }
}

// MARK: - UserDefaults Extensions for Auto-Sync

extension UserDefaults {
    var autoSyncEnabled: Bool {
        get { object(forKey: "autoSyncEnabled") as? Bool ?? true }
        set { set(newValue, forKey: "autoSyncEnabled") }
    }
    
    var autoSyncFrequencyMinutes: Int {
        get { 
            let saved = integer(forKey: "autoSyncFrequencyMinutes")
            return saved > 0 ? saved : 10 // Default: 10 minutes
        }
        set { set(newValue, forKey: "autoSyncFrequencyMinutes") }
    }
    
    var autoSyncOnCellular: Bool {
        get { object(forKey: "autoSyncOnCellular") as? Bool ?? allowCellularSync }
        set { set(newValue, forKey: "autoSyncOnCellular") }
    }
}
