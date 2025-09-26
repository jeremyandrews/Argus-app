import Foundation
import SwiftUI
import Combine
import Network
import OSLog
#if os(iOS)
import UIKit
#endif

/// BATTERY OPTIMIZED AutoSyncCoordinator - Minimal resource usage
/// This replaces the complex 1000+ line version with a simple, efficient implementation
@MainActor
final class AutoSyncCoordinator: ObservableObject {
    // MARK: - Singleton
    
    static let shared = AutoSyncCoordinator()
    
    // MARK: - Published State
    
    @Published var isAutoSyncing = false
    @Published var lastAutoSyncTime: Date?
    @Published var autoSyncEnabled = true
    @Published var nextScheduledSync: Date?
    @Published var syncFrequencyMinutes = 20  // Modest battery optimization: 20 minutes instead of 10
    
    // MARK: - Configuration (Battery Optimized)
    
    private let initialSyncDelay: TimeInterval = 3.0      // Conservative: 3 seconds
    private let minSyncInterval: TimeInterval = 900     // Conservative: 15 minutes minimum
    private let foregroundReturnThreshold: TimeInterval = 900 // Conservative: 15 minutes in background
    
    // MARK: - Minimal State Management
    
    private var periodicSyncTimer: Timer?
    private var initialSyncScheduled = false
    private var backgroundTime: Date?
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 2
    
    // MARK: - Dependencies
    
    private let logger = AppLogger.sync
    
    // MARK: - Cancellables
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    private init() {
        // Load persisted state
        loadPersistedState()
        
        // Set up minimal lifecycle observers
        setupLifecycleObservers()
    }
    
    // MARK: - Public API
    
    /// Schedules the initial sync after app launch
    func scheduleInitialSync() async {
        guard !initialSyncScheduled else { return }
        initialSyncScheduled = true
        
        if autoSyncEnabled {
            logger.info("Battery optimized auto-sync will start in \(Int(self.initialSyncDelay))s")
            
            // Use a simple async task to avoid blocking
            Task {
                try? await Task.sleep(nanoseconds: UInt64(initialSyncDelay * 1_000_000_000))
                await performAutoSyncIfNeeded(context: .appLaunch)
                await MainActor.run {
                    startPeriodicSync()
                }
            }
        }
    }
    
    /// Enables or disables auto-sync functionality
    func setAutoSyncEnabled(_ enabled: Bool) {
        guard autoSyncEnabled != enabled else { return }
        
        autoSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSyncEnabled")
        
        if enabled {
            logger.info("Battery optimized auto-sync enabled")
            startPeriodicSync()
        } else {
            logger.info("Auto-sync disabled")
            stopPeriodicSync()
        }
    }
    
    /// Updates the sync frequency (minimum 30 minutes for battery efficiency)
    func updateSyncFrequency(_ minutes: Int) {
        let batteryOptimizedMinutes = max(minutes, 30) // Minimum 30 minutes
        guard batteryOptimizedMinutes != syncFrequencyMinutes else { return }
        
        syncFrequencyMinutes = batteryOptimizedMinutes
        UserDefaults.standard.set(batteryOptimizedMinutes, forKey: "autoSyncFrequencyMinutes")
        logger.info("Updated sync frequency to \(batteryOptimizedMinutes) minutes (battery optimized)")
        
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
    
    /// Manual sync trigger (alias for UI compatibility)
    func performManualSync() async {
        await triggerManualSync()
    }
    
    // MARK: - Private Implementation
    
    /// Loads persisted state from UserDefaults
    private func loadPersistedState() {
        autoSyncEnabled = UserDefaults.standard.object(forKey: "autoSyncEnabled") as? Bool ?? true
        lastAutoSyncTime = UserDefaults.standard.object(forKey: "lastAutoSyncTime") as? Date
        let savedMinutes = UserDefaults.standard.integer(forKey: "autoSyncFrequencyMinutes")
        syncFrequencyMinutes = savedMinutes > 0 ? max(savedMinutes, 30) : 60 // Battery optimized default
        
        if !autoSyncEnabled {
            logger.info("Auto-sync is disabled")
        }
    }
    
    /// Sets up minimal app lifecycle observers
    private func setupLifecycleObservers() {
        // App entering foreground - only essential observer
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handleForegroundReturn()
                }
            }
            .store(in: &cancellables)
        
        // App going to background - only essential observer
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.recordBackgroundTime()
            }
            .store(in: &cancellables)
    }
    
    /// Starts periodic sync timer with battery-optimized intervals
    private func startPeriodicSync() {
        guard autoSyncEnabled else { 
            logger.debug("Auto-sync disabled - not starting timer")
            return 
        }
        
        stopPeriodicSync() // Stop existing timer
        
        let interval = TimeInterval(syncFrequencyMinutes * 60) // Convert to seconds
        nextScheduledSync = Date().addingTimeInterval(interval)
        
        logger.info("Battery optimized sync timer starting - interval: \(self.syncFrequencyMinutes) minutes")
        
        // Use a more robust timer approach to avoid deadlocks
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self, timer.isValid else {
                timer.invalidate()
                return
            }
            
            // Perform sync in background to avoid blocking main thread
            Task.detached { @MainActor in
                await self.performPeriodicSyncIfNeeded()
            }
        }
        
        // Ensure timer is added to run loop properly
        if let timer = periodicSyncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    /// Stops periodic sync timer
    private func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        nextScheduledSync = nil
    }
    
    /// Performs periodic sync with battery-aware conditions
    private func performPeriodicSyncIfNeeded() async {
        guard autoSyncEnabled else { return }
        
        // Update next scheduled sync time
        let interval = TimeInterval(syncFrequencyMinutes * 60)
        nextScheduledSync = Date().addingTimeInterval(interval)
        
        // Check minimum time since last sync (battery optimization)
        if let lastSync = lastAutoSyncTime {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < minSyncInterval {
                logger.debug("Sync throttled for battery - only \(Int(timeSinceLastSync/60))min since last sync")
                return
            }
        }
        
        // Battery-aware checks
        guard await shouldAllowSyncForBattery() else {
            logger.debug("Sync deferred for battery optimization")
            return
        }
        
        // Simple backoff for failures
        if consecutiveFailures >= maxConsecutiveFailures {
            let timeSinceLastFailure = lastAutoSyncTime.map { Date().timeIntervalSince($0) } ?? 0
            if timeSinceLastFailure < TimeInterval(consecutiveFailures * 1800) { // 30 min per failure
                logger.debug("Sync deferred - progressive backoff active")
                return
            }
        }
        
        await performAutoSyncIfNeeded(context: .periodic)
    }
    
    /// Handles app returning from background (battery optimized)
    private func handleForegroundReturn() async {
        guard let backgroundTime = backgroundTime else { return }
        
        let backgroundDuration = Date().timeIntervalSince(backgroundTime)
        logger.debug("App returned from background after \(Int(backgroundDuration/60)) minutes")
        
        // Only sync if backgrounded for more than the threshold (battery optimization)
        let shouldSync = backgroundDuration >= foregroundReturnThreshold
        
        if shouldSync {
            logger.info("Triggering sync after \(Int(backgroundDuration/60)) minutes in background")
            await performAutoSyncIfNeeded(context: .foregroundReturn)
        } else {
            logger.debug("Skipping sync - background duration too short for battery efficiency")
        }
        
        self.backgroundTime = nil
    }
    
    /// Records when app goes to background
    private func recordBackgroundTime() {
        backgroundTime = Date()
        logger.debug("Recorded background time")
    }
    
    /// Simplified sync execution with minimal overhead
    private func performAutoSyncIfNeeded(context: AutoSyncContext) async {
        guard autoSyncEnabled else { 
            logger.debug("Auto-sync disabled - skipping sync request")
            return 
        }
        
        // Simple state management
        isAutoSyncing = true
        defer { isAutoSyncing = false }
        
        logger.debug("Starting battery-optimized sync - context: \(context.rawValue)")
        
        do {
            // Simple network check
            guard await isNetworkAvailable() else {
                logger.debug("Auto-sync skipped - no network")
                return
            }
            
            // Use GlobalSyncCoordinator for the actual sync
            let addedCount = try await GlobalSyncCoordinator.shared.requestAutomaticSync(
                context: context.rawValue
            ) { _ in
                // No progress logging to reduce overhead
            }
            
            // Update state after successful sync
            lastAutoSyncTime = Date()
            UserDefaults.standard.set(lastAutoSyncTime, forKey: "lastAutoSyncTime")
            consecutiveFailures = 0
            
            logger.info("Battery-optimized sync completed - added: \(addedCount) articles")
            
            // Schedule next background sync (simplified)
            BackgroundTaskManager.shared.scheduleBackgroundRefresh()
            
            // Notify UI if articles were added
            if addedCount > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Notification.Name.articleProcessingCompleted,
                        object: nil
                    )
                }
            }
            
        } catch {
            consecutiveFailures += 1
            logger.error("Battery-optimized sync failed (failure #\(self.consecutiveFailures)): \(error)")
        }
    }
    
    /// Simple network availability check - non-blocking
    private func isNetworkAvailable() async -> Bool {
        // For battery optimization, assume network is available to avoid blocking
        // The actual sync will fail gracefully if network is not available
        return true
    }
    
    /// Battery-aware sync permission check
    private func shouldAllowSyncForBattery() async -> Bool {
        // Simple check - only defer if Low Power Mode is enabled
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            logger.debug("Sync deferred - Low Power Mode enabled")
            return false
        }
        
        return true
    }
    
    /// Cleanup resources when coordinator is deallocated
    deinit {
        cancellables.removeAll()
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
            return saved > 0 ? max(saved, 30) : 60 // Battery optimized: minimum 30min, default 60min
        }
        set { set(max(newValue, 30), forKey: "autoSyncFrequencyMinutes") } // Enforce 30min minimum
    }
    
    var autoSyncOnCellular: Bool {
        get { object(forKey: "autoSyncOnCellular") as? Bool ?? false } // Default to false for battery
        set { set(newValue, forKey: "autoSyncOnCellular") }
    }
}
