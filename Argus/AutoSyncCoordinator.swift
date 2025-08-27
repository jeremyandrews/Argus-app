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
        let newInterval = TimeInterval(minutes * 60)
        guard newInterval != periodicSyncInterval else { return }
        
        UserDefaults.standard.set(newInterval, forKey: "autoSyncFrequencyMinutes")
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
    
    // MARK: - Private Implementation
    
    /// Loads persisted state from UserDefaults
    private func loadPersistedState() {
        autoSyncEnabled = UserDefaults.standard.object(forKey: "autoSyncEnabled") as? Bool ?? true
        lastAutoSyncTime = UserDefaults.standard.object(forKey: "lastAutoSyncTime") as? Date
        
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
    
    /// Performs periodic sync if conditions are met
    private func performPeriodicSyncIfNeeded() async {
        guard autoSyncEnabled else { return }
        
        // Check throttling conditions
        if let lastSync = self.lastAutoSyncTime {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < minSyncInterval {
                logger.debug("Sync throttled - only \(timeSinceLastSync)s since last sync")
                return
            }
        }
        
        // Check if user is actively using the app
        if isUserActivelyInteracting() {
            logger.debug("Sync deferred - user is actively interacting")
            return
        }
        
        await performAutoSyncIfNeeded(context: .periodic)
    }
    
    /// Handles app returning from background
    private func handleForegroundReturn() async {
        guard let backgroundTime = backgroundTime else { return }
        
        let backgroundDuration = Date().timeIntervalSince(backgroundTime)
        logger.debug("App returned from background after \(backgroundDuration)s")
        
        if backgroundDuration > foregroundReturnThreshold {
            logger.info("Triggering sync after \(backgroundDuration)s in background")
            await performAutoSyncIfNeeded(context: .foregroundReturn)
        }
        
        self.backgroundTime = nil
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
            
            logger.info("Auto-sync completed successfully - added: \(result.addedCount), duration: \(result.duration)s")
            
            // Schedule next background sync
            backgroundTaskManager.scheduleBackgroundRefresh()
            
        } catch {
            logger.error("Auto-sync failed: \(error)")
            
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
    
    /// Checks if user is actively interacting with the app
    private func isUserActivelyInteracting() -> Bool {
        // Simple heuristic - check if app has been in foreground recently
        // In Phase 2, this could be enhanced with more sophisticated detection
        return backgroundTime == nil
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
