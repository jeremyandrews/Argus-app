import Foundation
import SwiftUI
import Combine
import Network
import OSLog
#if os(iOS)
import UIKit
#endif
import Darwin.Mach

// MARK: - Error Handling Types (Phase 4.2)

enum AutoSyncError: Error, Equatable {
    case networkUnavailable
    case serverUnavailable(statusCode: Int?)
    case throttled(retryAfter: TimeInterval?)
    case userDisabled
    case lowBattery
    case backgroundTimeExpired
    case syncInProgress
    case dataCorruption
    case configurationError(String)
    case unknownError(String)
    
    var localizedDescription: String {
        switch self {
        case .networkUnavailable:
            return "Network connection unavailable"
        case .serverUnavailable(let statusCode):
            return "Server unavailable" + (statusCode.map { " (HTTP \($0))" } ?? "")
        case .throttled(let retryAfter):
            return "Rate limited" + (retryAfter.map { " (retry after \($0)s)" } ?? "")
        case .userDisabled:
            return "Auto-sync disabled by user"
        case .lowBattery:
            return "Low battery - sync paused"
        case .backgroundTimeExpired:
            return "Background time expired"
        case .syncInProgress:
            return "Sync already in progress"
        case .dataCorruption:
            return "Data corruption detected"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .unknownError(let message):
            return "Unknown error: \(message)"
        }
    }
    
    fileprivate var errorCategory: ErrorCategory {
        switch self {
        case .networkUnavailable, .serverUnavailable:
            return .recoverable
        case .throttled:
            return .retryable
        case .userDisabled, .lowBattery, .backgroundTimeExpired:
            return .temporary
        case .syncInProgress:
            return .ignorable
        case .dataCorruption, .configurationError:
            return .critical
        case .unknownError:
            return .unknown
        }
    }
    
    fileprivate var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .networkUnavailable:
            return .waitForNetwork
        case .serverUnavailable:
            return .exponentialBackoff(baseDelay: 30.0, maxDelay: 300.0)
        case .throttled(let retryAfter):
            return .waitFixed(retryAfter ?? 60.0)
        case .userDisabled:
            return .disable
        case .lowBattery, .backgroundTimeExpired:
            return .pauseUntilConditionsMet
        case .syncInProgress:
            return .ignore
        case .dataCorruption, .configurationError:
            return .reportAndDisable
        case .unknownError:
            return .exponentialBackoff(baseDelay: 10.0, maxDelay: 120.0)
        }
    }
    
    static func == (lhs: AutoSyncError, rhs: AutoSyncError) -> Bool {
        switch (lhs, rhs) {
        case (.networkUnavailable, .networkUnavailable):
            return true
        case (.serverUnavailable(let code1), .serverUnavailable(let code2)):
            return code1 == code2
        case (.throttled(let time1), .throttled(let time2)):
            return time1 == time2
        case (.userDisabled, .userDisabled),
             (.lowBattery, .lowBattery),
             (.backgroundTimeExpired, .backgroundTimeExpired),
             (.syncInProgress, .syncInProgress),
             (.dataCorruption, .dataCorruption):
            return true
        case (.configurationError(let msg1), .configurationError(let msg2)):
            return msg1 == msg2
        case (.unknownError(let msg1), .unknownError(let msg2)):
            return msg1 == msg2
        default:
            return false
        }
    }
}

private enum ErrorCategory {
    case recoverable    // Can recover automatically (network/server issues)
    case retryable      // Should retry with delays (throttling)
    case temporary      // Wait for conditions to change (battery, user settings)
    case ignorable      // Don't treat as failures (sync in progress)
    case critical       // Serious issues requiring intervention
    case unknown        // Unknown errors requiring investigation
}

private enum RecoveryStrategy {
    case waitForNetwork
    case exponentialBackoff(baseDelay: TimeInterval, maxDelay: TimeInterval)
    case waitFixed(TimeInterval)
    case pauseUntilConditionsMet
    case disable
    case ignore
    case reportAndDisable
}

private struct ErrorReport {
    let error: AutoSyncError
    let timestamp: Date
    let context: String?
    let networkConditions: String
    let systemState: String
    let recoveryAttempts: Int
    
    var debugDescription: String {
        var description = "AutoSync Error Report:\n"
        description += "- Error: \(error.localizedDescription)\n"
        description += "- Category: \(error.errorCategory)\n"
        description += "- Timestamp: \(timestamp)\n"
        description += "- Network: \(networkConditions)\n"
        description += "- System: \(systemState)\n"
        description += "- Recovery Attempts: \(recoveryAttempts)\n"
        if let context = context {
            description += "- Context: \(context)\n"
        }
        return description
    }
}

/// Central coordinator for all automatic sync behavior in Argus
/// Implements Phase 1-4.2 of the auto-sync implementation plan
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
    
    // Phase 4.1: Network Intelligence & Retry Management
    private var failureHistory: [SyncFailure] = []
    private let maxFailureHistorySize = 10
    private var offlineQueuedSync: AutoSyncContext?
    private var networkStateMonitor: NWPathMonitor?
    private var isWaitingForNetwork = false
    
    // Phase 4.2: Error Handling & Recovery
    private var criticalErrors: [AutoSyncError] = []
    private var recoverySuspended = false
    private var lastRecoveryAttempt: Date?
    private var errorReports: [ErrorReport] = []
    private let maxErrorReports = 100
    private let recoveryLogger = Logger(subsystem: "com.argus.sync", category: "AutoSyncRecovery")
    
    // Phase 4.3: Performance Monitoring
    public var performanceMetrics: [PerformanceMetric] = []
    public var resourceSnapshots: [SystemResourceSnapshot] = []
    private let maxPerformanceHistory = 100
    private let maxResourceSnapshots = 50
    private var currentSyncStartTime: Date?
    private var currentSyncStartResources: SystemResourceSnapshot?
    private let performanceLogger = Logger(subsystem: "com.argus.sync", category: "AutoSyncPerformance")
    
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
        
        // Phase 4.1: Setup network monitoring for offline queue
        setupNetworkRecoveryMonitoring()
        
        // Don't start periodic timer immediately - wait for initial sync to complete
        // The periodic timer will be started after the first initial sync
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
        
        // Start the periodic timer after initial sync completes (only if auto-sync is enabled)
        if autoSyncEnabled {
            startPeriodicSync()
        }
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
        guard self.autoSyncEnabled else { 
            logger.debug("Auto-sync disabled - not starting timer")
            return 
        }
        
        // Always stop existing timer first using standard iOS pattern
        stopPeriodicSync()
        
        let interval = getCurrentSyncInterval()
        nextScheduledSync = Date().addingTimeInterval(interval)
        
        logger.info("Auto-sync timer starting - interval: \(Int(interval/60)) minutes")
        
        // Use standard iOS Timer pattern with proper weak self handling
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else {
                self?.logger.debug("Timer callback - self deallocated, invalidating timer")
                timer.invalidate()
                return
            }
            
            // Verify timer is still valid before proceeding
            guard timer.isValid else {
                self.logger.debug("Timer callback - timer no longer valid, skipping sync")
                return
            }
            
            self.logger.debug("Timer callback - triggering periodic sync check")
            Task { @MainActor in
                await self.performPeriodicSyncIfNeeded()
            }
        }
        
        logger.info("Periodic sync timer created successfully - next sync in \\(Int(interval/60)) minutes")
    }
    
    /// Stops periodic sync timer
    private func stopPeriodicSync() {
        if let timer = periodicSyncTimer {
            logger.debug("Stopping periodic sync timer")
            timer.invalidate()
        }
        periodicSyncTimer = nil
        nextScheduledSync = nil
    }
    
    /// Gets the current sync interval from UserDefaults or uses default
    private func getCurrentSyncInterval() -> TimeInterval {
        let savedMinutes = UserDefaults.standard.double(forKey: "autoSyncFrequencyMinutes")
        let minutes = savedMinutes > 0 ? savedMinutes : Double(syncFrequencyMinutes)
        return minutes * 60.0 // Convert minutes to seconds
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
    
    /// Performs auto-sync if conditions allow using the global sync coordinator
    private func performAutoSyncIfNeeded(context: AutoSyncContext) async {
        guard autoSyncEnabled else { 
            logger.debug("Auto-sync disabled - skipping sync request")
            return 
        }
        
        // Generate new session ID for this sync operation
        syncSessionId = UUID()
        let currentSessionId = syncSessionId
        
        // Phase 4.3: Start performance monitoring
        startPerformanceMonitoring()
        
        // Set sync state using standard pattern
        isAutoSyncing = true
        defer {
            // Standard cleanup: Only reset if this is still the current session
            if syncSessionId == currentSessionId {
                isAutoSyncing = false
                logger.debug("Sync operation completed - context: \(context.rawValue)")
            }
        }
        
        logger.debug("Starting sync operation via GlobalSyncCoordinator - context: \(context.rawValue)")
        
        var syncSuccess = false
        var syncError: AutoSyncError?
        var articlesProcessed = 0
        var dataVolumeBytes = 0
        
        do {
            // Check network conditions
            guard await shouldAllowSync() else {
                logger.debug("Auto-sync skipped - network conditions not suitable")
                // Record performance data for skipped sync
                endPerformanceMonitoring(
                    context: context,
                    articlesProcessed: 0,
                    dataVolumeBytes: 0,
                    success: false,
                    error: .networkUnavailable
                )
                return
            }
            
            // Check if session was cancelled
            guard syncSessionId == currentSessionId else {
                logger.debug("Auto-sync cancelled - session changed")
                endPerformanceMonitoring(
                    context: context,
                    articlesProcessed: 0,
                    dataVolumeBytes: 0,
                    success: false,
                    error: .syncInProgress
                )
                return
            }
            
            // Use GlobalSyncCoordinator to prevent race conditions with manual syncs
            let addedCount = try await GlobalSyncCoordinator.shared.requestAutomaticSync(
                context: context.rawValue
            ) { _ in
                // Progress logging removed to avoid Swift 6 compilation issues
            }
            
            // Phase 4.3: Extract performance metrics from sync result
            articlesProcessed = addedCount
            dataVolumeBytes = estimateDataVolume(articlesCount: articlesProcessed, syncDuration: 0) // Duration tracked by GlobalSyncCoordinator
            syncSuccess = true
            
            // Update state after successful sync
            lastAutoSyncTime = Date()
            UserDefaults.standard.set(lastAutoSyncTime, forKey: "lastAutoSyncTime")
            
            // Phase 2.2: Reset failure counter on success
            consecutiveFailures = 0
            
            logger.info("Auto-sync completed successfully via GlobalSyncCoordinator - added: \(addedCount) articles")
            
            // Schedule next background sync
            backgroundTaskManager.scheduleBackgroundRefresh()
            
            // Notify UI that new content is available if articles were added
            if addedCount > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Notification.Name.articleProcessingCompleted,
                        object: nil
                    )
                }
                logger.info("Posted UI refresh notification - \(addedCount) new articles")
            }
            
        } catch {
            // Phase 2.2: Track consecutive failures for progressive backoff
            consecutiveFailures += 1
            syncError = handleSyncError(error, context: context.rawValue)
            
            logger.error("Auto-sync failed via GlobalSyncCoordinator (failure #\(self.consecutiveFailures)): \(error)")
            
            // Phase 4.1: Enhanced retry with intelligent backoff
            scheduleRetrySync(for: error, context: context)
        }
        
        // Phase 4.3: End performance monitoring
        endPerformanceMonitoring(
            context: context,
            articlesProcessed: articlesProcessed,
            dataVolumeBytes: dataVolumeBytes,
            success: syncSuccess,
            error: syncError
        )
    }
    
    /// Estimate data volume based on articles processed
    private func estimateDataVolume(articlesCount: Int, syncDuration: TimeInterval) -> Int {
        // Estimate based on average article size (simplified)
        let avgArticleSizeBytes = 2048 // 2KB per article (title, content summary, metadata)
        return max(1000, articlesCount * avgArticleSizeBytes) // Minimum 1KB
    }
    
    // MARK: - Error Handling & Recovery Methods (Phase 4.2)
    
    private func handleSyncError(_ error: Error, context: String? = nil) -> AutoSyncError {
        let autoSyncError = categorizeError(error)
        recordError(autoSyncError, context: context)
        
        switch autoSyncError.errorCategory {
        case .critical:
            handleCriticalError(autoSyncError, context: context)
        case .recoverable, .retryable:
            scheduleRecovery(for: autoSyncError, context: context)
        case .temporary:
            pauseUntilConditionsMet(for: autoSyncError)
        case .ignorable:
            logger.info("Ignoring expected error: \(autoSyncError.localizedDescription)")
        case .unknown:
            reportUnknownError(autoSyncError, context: context)
        }
        
        return autoSyncError
    }
    
    private func categorizeError(_ error: Error) -> AutoSyncError {
        // Handle already categorized AutoSyncError first
        if let autoSyncError = error as? AutoSyncError {
            return autoSyncError
        }
        
        // Handle ArticleServiceError cases
        if let articleError = error as? ArticleServiceError {
            switch articleError {
            case .networkError:
                return .networkUnavailable
            case .databaseError:
                return .dataCorruption
            case .validationError:
                return .configurationError("Validation failed")
            case .articleNotFound:
                return .serverUnavailable(statusCode: 404)
            case .cancelled:
                return .userDisabled
            case .unknown:
                return .unknownError("ArticleService error")
            }
        }
        
        // Handle NSError cases - since all Error types can be cast to NSError, use direct cast
        let nsError = error as NSError
        switch nsError.domain {
        case NSURLErrorDomain:
            return categorizeNetworkError(nsError)
        case "CloudKitError":
            return categorizeCloudKitError(nsError)
        default:
            return .unknownError("NSError: \(nsError.localizedDescription)")
        }
    }
    
    private func categorizeNetworkError(_ error: NSError) -> AutoSyncError {
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return .networkUnavailable
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
            return .serverUnavailable(statusCode: nil)
        case NSURLErrorHTTPTooManyRedirects:
            return .serverUnavailable(statusCode: 310)
        case NSURLErrorBackgroundSessionWasDisconnected:
            return .backgroundTimeExpired
        default:
            return .unknownError("Network error: \(error.localizedDescription)")
        }
    }
    
    private func categorizeCloudKitError(_ error: NSError) -> AutoSyncError {
        return .unknownError("CloudKit error: \(error.localizedDescription)")
    }
    
    private func recordError(_ error: AutoSyncError, context: String? = nil) {
        let currentNetworkConditions = describeNetworkConditions()
        let systemState = describeSystemState()
        
        let report = ErrorReport(
            error: error,
            timestamp: Date(),
            context: context,
            networkConditions: currentNetworkConditions,
            systemState: systemState,
            recoveryAttempts: consecutiveFailures
        )
        
        errorReports.append(report)
        if errorReports.count > maxErrorReports {
            errorReports.removeFirst(errorReports.count - maxErrorReports)
        }
        
        recoveryLogger.error("AutoSync error recorded: \(error.localizedDescription, privacy: .public)")
        logger.error("AutoSync error: \(error.localizedDescription) - Context: \(context ?? "none")")
    }
    
    private func handleCriticalError(_ error: AutoSyncError, context: String?) {
        criticalErrors.append(error)
        recoverySuspended = true
        
        recoveryLogger.fault("Critical AutoSync error - suspension required: \(error.localizedDescription, privacy: .public)")
        logger.error("CRITICAL: AutoSync suspended due to: \(error.localizedDescription)")
        
        scheduleCriticalErrorNotification(error: error, context: context)
    }
    
    private func scheduleRecovery(for error: AutoSyncError, context: String?) {
        guard !recoverySuspended else { return }
        
        let strategy = error.recoveryStrategy
        
        switch strategy {
        case .waitForNetwork:
            logger.info("Waiting for network recovery for error: \(error.localizedDescription)")
            
        case .exponentialBackoff(let baseDelay, let maxDelay):
            let attempts = consecutiveFailures
            let delay = min(baseDelay * pow(2.0, Double(attempts - 1)), maxDelay)
            
            recoveryLogger.info("Scheduling exponential backoff recovery: delay=\(delay, privacy: .public)s, attempt=\(attempts, privacy: .public)")
            
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.attemptRecovery(from: error, context: context)
                }
            }
            
        case .waitFixed(let delay):
            recoveryLogger.info("Scheduling fixed delay recovery: delay=\(delay, privacy: .public)s")
            
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.attemptRecovery(from: error, context: context)
                }
            }
            
        case .pauseUntilConditionsMet:
            logger.info("Pausing sync until conditions improve: \(error.localizedDescription)")
            
        case .disable:
            logger.warning("Disabling auto-sync due to: \(error.localizedDescription)")
            autoSyncEnabled = false
            
        case .ignore:
            break
            
        case .reportAndDisable:
            handleCriticalError(error, context: context)
        }
    }
    
    private func pauseUntilConditionsMet(for error: AutoSyncError) {
        logger.info("Sync paused due to temporary condition: \(error.localizedDescription)")
    }
    
    private func attemptRecovery(from error: AutoSyncError, context: String?) {
        guard !recoverySuspended, autoSyncEnabled else { return }
        
        lastRecoveryAttempt = Date()
        recoveryLogger.info("Attempting recovery from: \(error.localizedDescription, privacy: .public)")
        
        if shouldAttemptRecovery(for: error) {
            logger.info("Conditions improved, attempting sync recovery")
            Task {
                await performAutoSyncIfNeeded(context: .retry)
            }
        } else {
            scheduleRecovery(for: error, context: context)
        }
    }
    
    private func shouldAttemptRecovery(for error: AutoSyncError) -> Bool {
        switch error {
        case .networkUnavailable:
            return !isWaitingForNetwork
        case .serverUnavailable:
            return true
        case .userDisabled:
            return autoSyncEnabled
        case .lowBattery:
            return !ProcessInfo.processInfo.isLowPowerModeEnabled
        case .backgroundTimeExpired:
            return true
        default:
            return true
        }
    }
    
    private func reportUnknownError(_ error: AutoSyncError, context: String?) {
        recoveryLogger.error("Unknown error encountered: \(error.localizedDescription, privacy: .public)")
        scheduleRecovery(for: error, context: context)
    }
    
    private func scheduleCriticalErrorNotification(error: AutoSyncError, context: String?) {
        logger.fault("Critical AutoSync error notification: \(error.localizedDescription)")
    }
    
    private func describeNetworkConditions() -> String {
        let currentType = getCurrentNetworkType()
        return "Type: \(currentType), Quality: \(evaluateNetworkQualityDescription(currentType))"
    }
    
    private func describeSystemState() -> String {
        let batteryState = ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power" : "Normal"
        let backgroundState = UIApplication.shared.backgroundRefreshStatus == .available ? "Available" : "Restricted"
        return "Battery: \(batteryState), Background: \(backgroundState)"
    }
    
    private func evaluateNetworkQualityDescription(_ networkType: NetworkQuality) -> String {
        switch networkType {
        case .wifi: return "Excellent"
        case .wiredEthernet: return "Excellent"
        case .cellular: return "Good"
        case .poor: return "Poor"
        case .offline: return "None"
        }
    }
    
    // MARK: - Error Reporting & Diagnostics
    
    func getErrorReport() -> String {
        var report = "=== AutoSync Error Report ===\n\n"
        
        report += "System Status:\n"
        report += "- Auto-sync enabled: \(autoSyncEnabled)\n"
        report += "- Recovery suspended: \(recoverySuspended)\n"
        report += "- Network waiting: \(isWaitingForNetwork)\n"
        report += "- Critical errors: \(criticalErrors.count)\n"
        report += "- Failure history: \(failureHistory.count)\n"
        report += "- Consecutive failures: \(consecutiveFailures)\n\n"
        
        if !criticalErrors.isEmpty {
            report += "Critical Errors:\n"
            for error in criticalErrors.suffix(5) {
                report += "- \(error.localizedDescription)\n"
            }
            report += "\n"
        }
        
        if !errorReports.isEmpty {
            report += "Recent Error Reports:\n"
            for errorReport in errorReports.suffix(3) {
                report += errorReport.debugDescription + "\n"
            }
        }
        
        return report
    }
    
    func clearErrorHistory() {
        failureHistory.removeAll()
        errorReports.removeAll()
        criticalErrors.removeAll()
        recoverySuspended = false
        consecutiveFailures = 0
        
        logger.info("AutoSync error history cleared")
        recoveryLogger.info("Error history manually cleared")
    }
    
    // MARK: - Phase 4.3: Performance Monitoring Methods
    
    /// Start performance monitoring for sync operation
    private func startPerformanceMonitoring() {
        currentSyncStartTime = Date()
        currentSyncStartResources = captureSystemResourceSnapshot()
        performanceLogger.info("Performance monitoring started for sync operation")
    }
    
    /// End performance monitoring and record metrics
    private func endPerformanceMonitoring(context: AutoSyncContext, articlesProcessed: Int, dataVolumeBytes: Int, success: Bool, error: AutoSyncError? = nil) {
        guard let startTime = currentSyncStartTime else {
            performanceLogger.warning("Performance monitoring ended without start time")
            return
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let endResources = captureSystemResourceSnapshot()
        
        let metric = PerformanceMetric(
            timestamp: endTime,
            context: context,
            duration: duration,
            articlesProcessed: articlesProcessed,
            dataVolumeBytes: dataVolumeBytes,
            networkSpeedKbps: calculateNetworkSpeed(dataVolumeBytes: dataVolumeBytes, duration: duration),
            memoryUsageMB: endResources.memoryUsageMB,
            batteryLevel: endResources.batteryLevel,
            networkCondition: getCurrentNetworkType(),
            success: success,
            error: error
        )
        
        recordPerformanceMetric(metric)
        recordResourceSnapshot(endResources)
        
        // Clear monitoring state
        currentSyncStartTime = nil
        currentSyncStartResources = nil
        
        performanceLogger.info("Performance metric recorded: \(duration, privacy: .public)s, \(articlesProcessed, privacy: .public) articles, score: \(metric.performanceScore, privacy: .public)")
    }
    
    /// Capture current system resource snapshot
    private func captureSystemResourceSnapshot() -> SystemResourceSnapshot {
        let memoryInfo = getMemoryInfo()
        let batteryLevel = getBatteryLevel()
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalState = ProcessInfo.processInfo.thermalState
        
        return SystemResourceSnapshot(
            timestamp: Date(),
            memoryUsageMB: memoryInfo.used,
            availableMemoryMB: memoryInfo.available,
            batteryLevel: batteryLevel,
            lowPowerModeEnabled: lowPowerMode,
            thermalState: thermalState
        )
    }
    
    /// Get memory usage information
    private func getMemoryInfo() -> (used: Double, available: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / (1024 * 1024)
            let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
            let availableMB = max(totalMB - usedMB, 0)
            return (usedMB, availableMB)
        }
        
        return (0, 100) // Fallback values
    }
    
    /// Get battery level (iOS only)
    private func getBatteryLevel() -> Float? {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIDevice.current.isBatteryMonitoringEnabled = false }
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? level : nil
        #else
        return nil
        #endif
    }
    
    /// Calculate network speed based on data transfer
    private func calculateNetworkSpeed(dataVolumeBytes: Int, duration: TimeInterval) -> Double? {
        guard duration > 0, dataVolumeBytes > 0 else { return nil }
        return (Double(dataVolumeBytes) * 8) / (duration * 1000) // Convert to kbps
    }
    
    /// Record performance metric
    private func recordPerformanceMetric(_ metric: PerformanceMetric) {
        performanceMetrics.append(metric)
        
        // Keep only recent metrics
        if performanceMetrics.count > maxPerformanceHistory {
            performanceMetrics.removeFirst(performanceMetrics.count - maxPerformanceHistory)
        }
        
        // Log significant performance events
        if metric.duration > 30 {
            performanceLogger.warning("Slow sync detected: \(metric.duration, privacy: .public)s for \(metric.articlesProcessed, privacy: .public) articles")
        }
        
        if let startResources = currentSyncStartResources,
           startResources.memoryPressure == .warning || startResources.memoryPressure == .critical {
            performanceLogger.warning("High memory pressure during sync: \(metric.memoryUsageMB, privacy: .public)MB")
        }
    }
    
    /// Record resource snapshot
    private func recordResourceSnapshot(_ snapshot: SystemResourceSnapshot) {
        resourceSnapshots.append(snapshot)
        
        // Keep only recent snapshots
        if resourceSnapshots.count > maxResourceSnapshots {
            resourceSnapshots.removeFirst(resourceSnapshots.count - maxResourceSnapshots)
        }
    }
    
    /// Get comprehensive performance report
    @MainActor
    func getPerformanceReport() -> String {
        var report = "=== AutoSync Performance Report ===\n"
        report += "Generated: \(Date())\n"
        report += "Analysis Period: \(performanceMetrics.count) sync operations\n\n"
        
        guard !performanceMetrics.isEmpty else {
            report += "No performance data available.\n"
            return report
        }
        
        // Overall statistics
        let successfulOps = performanceMetrics.filter { $0.success }.count
        let successRate = Double(successfulOps) / Double(performanceMetrics.count) * 100
        
        report += "=== Overall Performance ===\n"
        report += "Success Rate: \(String(format: "%.1f", successRate))% (\(successfulOps)/\(performanceMetrics.count))\n"
        
        // Duration statistics
        let durations = performanceMetrics.map { $0.duration }
        let avgDuration = durations.reduce(0, +) / Double(durations.count)
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0
        
        report += "Average Duration: \(String(format: "%.2f", avgDuration))s\n"
        report += "Duration Range: \(String(format: "%.2f", minDuration))s - \(String(format: "%.2f", maxDuration))s\n"
        
        // Efficiency statistics
        let efficiencies = performanceMetrics.map { $0.efficiency }.filter { $0 > 0 }
        if !efficiencies.isEmpty {
            let avgEfficiency = efficiencies.reduce(0, +) / Double(efficiencies.count)
            report += "Average Efficiency: \(String(format: "%.2f", avgEfficiency)) articles/second\n"
        }
        
        // Performance score
        let scores = performanceMetrics.map { $0.performanceScore }
        let avgScore = scores.reduce(0, +) / Double(scores.count)
        report += "Average Performance Score: \(String(format: "%.1f", avgScore))/100\n"
        
        // Network performance
        let networkSpeeds = performanceMetrics.compactMap { $0.networkSpeedKbps }
        if !networkSpeeds.isEmpty {
            let avgSpeed = networkSpeeds.reduce(0, +) / Double(networkSpeeds.count)
            report += "Average Network Speed: \(String(format: "%.2f", avgSpeed)) kbps\n"
        }
        
        // Resource usage
        let memoryUsages = performanceMetrics.map { $0.memoryUsageMB }
        let avgMemory = memoryUsages.reduce(0, +) / Double(memoryUsages.count)
        let maxMemory = memoryUsages.max() ?? 0
        
        report += "\n=== Resource Usage ===\n"
        report += "Average Memory: \(String(format: "%.1f", avgMemory))MB\n"
        report += "Peak Memory: \(String(format: "%.1f", maxMemory))MB\n"
        
        // Performance by context
        report += "\n=== Performance by Context ===\n"
        for context in AutoSyncContext.allCases {
            let contextMetrics = performanceMetrics.filter { $0.context == context }
            if !contextMetrics.isEmpty {
                let avgDur = contextMetrics.map { $0.duration }.reduce(0, +) / Double(contextMetrics.count)
                let avgScore = contextMetrics.map { $0.performanceScore }.reduce(0, +) / Double(contextMetrics.count)
                report += "\(context.rawValue): \(String(format: "%.2f", avgDur))s avg, \(String(format: "%.1f", avgScore)) score (\(contextMetrics.count) ops)\n"
            }
        }
        
        return report
    }
    
    /// Get optimization recommendations based on performance data
    @MainActor
    func getOptimizationRecommendations() -> [String] {
        var recommendations: [String] = []
        
        guard !performanceMetrics.isEmpty else {
            return ["Insufficient performance data for recommendations"]
        }
        
        // Analyze success rate
        let successfulOps = performanceMetrics.filter { $0.success }.count
        let successRate = Double(successfulOps) / Double(performanceMetrics.count)
        if successRate < 0.8 {
            recommendations.append("Low success rate (\(String(format: "%.1f", successRate * 100))%) - review error handling and network conditions")
        }
        
        // Analyze sync duration
        let recentMetrics = Array(performanceMetrics.suffix(20))
        let avgDuration = recentMetrics.map { $0.duration }.reduce(0, +) / Double(recentMetrics.count)
        if avgDuration > 15 {
            recommendations.append("High average sync duration (\(String(format: "%.1f", avgDuration))s) - consider optimizing batch sizes or network usage")
        }
        
        // Memory usage analysis
        let highMemoryCount = performanceMetrics.filter { $0.memoryUsageMB > 150 }.count
        if Double(highMemoryCount) / Double(performanceMetrics.count) > 0.3 {
            recommendations.append("Frequent high memory usage detected - consider memory optimization during sync operations")
        }
        
        // Performance score analysis
        let avgScore = performanceMetrics.map { $0.performanceScore }.reduce(0, +) / Double(performanceMetrics.count)
        if avgScore < 60 {
            recommendations.append("Low average performance score (\(String(format: "%.1f", avgScore))/100) - review sync efficiency and network conditions")
        }
        
        // Context-specific analysis
        let periodicMetrics = performanceMetrics.filter { $0.context == .periodic }
        let manualMetrics = performanceMetrics.filter { $0.context == .manual }
        
        if !periodicMetrics.isEmpty && !manualMetrics.isEmpty {
            let periodicAvg = periodicMetrics.map { $0.duration }.reduce(0, +) / Double(periodicMetrics.count)
            let manualAvg = manualMetrics.map { $0.duration }.reduce(0, +) / Double(manualMetrics.count)
            
            if periodicAvg > manualAvg * 1.5 {
                recommendations.append("Periodic syncs are significantly slower than manual syncs - review background processing efficiency")
            }
        }
        
        if recommendations.isEmpty {
            recommendations.append("Performance is within acceptable ranges - no immediate optimization needed")
        }
        
        return recommendations
    }
    
    /// Clear performance history
    @MainActor
    func clearPerformanceHistory() {
        performanceMetrics.removeAll()
        resourceSnapshots.removeAll()
        performanceLogger.info("Performance history cleared")
    }

    /// Phase 4.1: Enhanced retry scheduling with intelligent backoff (Legacy support)
    private func scheduleRetrySync(for error: Error, context: AutoSyncContext) {
        // Use new error handling system
        let autoSyncError = handleSyncError(error, context: context.rawValue)
        
        // Legacy support - convert to old retry strategy for compatibility
        let retryStrategy = convertToLegacyRetryStrategy(autoSyncError.recoveryStrategy)
        
        switch retryStrategy {
        case .immediate:
            logger.debug("Scheduling immediate retry")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await self.performAutoSyncIfNeeded(context: .retry)
            }
            
        case .exponentialBackoff(let delay):
            logger.debug("Scheduling retry with exponential backoff in \(delay)s")
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.performAutoSyncIfNeeded(context: .retry)
                }
            }
            
        case .waitForNetwork:
            logger.debug("Network unavailable - queueing sync for network recovery")
            queueSyncForNetworkRecovery(context: context)
            
        case .abandon:
            logger.debug("Abandoning retry - too many failures or permanent error")
            consecutiveFailures = 0
        }
    }
    
    private func convertToLegacyRetryStrategy(_ recoveryStrategy: RecoveryStrategy) -> RetryStrategy {
        switch recoveryStrategy {
        case .waitForNetwork:
            return .waitForNetwork
        case .exponentialBackoff(let baseDelay, _):
            let attempts = consecutiveFailures
            let delay = min(baseDelay * pow(2.0, Double(attempts - 1)), 300)
            return .exponentialBackoff(delay: delay)
        case .waitFixed(let delay):
            return .exponentialBackoff(delay: delay)
        case .disable, .reportAndDisable:
            return .abandon
        case .ignore, .pauseUntilConditionsMet:
            return .waitForNetwork
        }
    }
    
    /// Checks if network conditions allow syncing - Phase 4.1 Network Intelligence
    private func shouldAllowSync() async -> Bool {
        // Use an actor to protect the hasResumed flag for thread safety in Swift 6
        actor ContinuationHandler {
            private var hasResumed = false
            
            func tryResume(continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }
            
            func isResumed() -> Bool {
                return hasResumed
            }
        }
        
        return await withCheckedContinuation { continuation in
            let networkMonitor = NWPathMonitor()
            let handler = ContinuationHandler()
            
            networkMonitor.pathUpdateHandler = { [weak self] path in
                Task {
                    defer {
                        networkMonitor.cancel()
                    }
                    
                    guard let self = self else {
                        await handler.tryResume(continuation: continuation, with: false)
                        return
                    }
                    
                    let result = self.evaluateNetworkConditions(path: path)
                    await handler.tryResume(continuation: continuation, with: result)
                }
            }
            
            networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
            
            // Add timeout to prevent indefinite waiting
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds timeout
                if await !handler.isResumed() {
                    networkMonitor.cancel()
                    await handler.tryResume(continuation: continuation, with: true) // Default to allow sync on timeout
                }
            }
        }
    }
    
    /// Phase 4.1: Enhanced network quality evaluation
    private nonisolated func evaluateNetworkConditions(path: NWPath) -> Bool {
        // Check basic connectivity
        guard path.status == .satisfied else {
            logger.debug("Network not available - no sync")
            return false
        }
        
        // Check network type and user preferences
        let networkType = determineNetworkType(path: path)
        
        switch networkType {
        case .wifi:
            logger.debug("WiFi network detected - allowing sync")
            return true
            
        case .cellular:
            let allowCellular = UserDefaults.standard.autoSyncOnCellular
            logger.debug("Cellular network detected - allow cellular: \(allowCellular)")
            return allowCellular
            
        case .wiredEthernet:
            logger.debug("Wired ethernet detected - allowing sync")
            return true
            
        case .poor:
            logger.debug("Poor network quality detected - skipping sync")
            return false
            
        case .offline:
            logger.debug("No network connectivity - skipping sync")
            return false
        }
    }
    
    /// Phase 4.1: Determine network type and quality
    private nonisolated func determineNetworkType(path: NWPath) -> NetworkQuality {
        // Check if offline
        guard path.status == .satisfied else {
            return .offline
        }
        
        // Check for WiFi
        if path.usesInterfaceType(.wifi) {
            // Additional WiFi quality checks could be added here
            return .wifi
        }
        
        // Check for wired ethernet
        if path.usesInterfaceType(.wiredEthernet) {
            return .wiredEthernet
        }
        
        // Check for cellular
        if path.usesInterfaceType(.cellular) {
            // Check for poor cellular conditions
            if path.isConstrained || path.isExpensive {
                logger.debug("Cellular network is constrained or expensive")
                // Still allow if user has explicitly enabled cellular sync
                return UserDefaults.standard.autoSyncOnCellular ? .cellular : .poor
            }
            return .cellular
        }
        
        // Unknown or other network types - treat as poor quality
        logger.debug("Unknown network interface type - treating as poor quality")
        return .poor
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
    
    /// Phase 4.1: Setup network recovery monitoring for offline queue
    private func setupNetworkRecoveryMonitoring() {
        networkStateMonitor = NWPathMonitor()
        
        networkStateMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                await self?.handleNetworkStateChange(path: path)
            }
        }
        
        networkStateMonitor?.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    /// Phase 4.1: Handle network state changes for offline queue processing
    private func handleNetworkStateChange(path: NWPath) async {
        let wasOffline = isWaitingForNetwork
        let isNowOnline = path.status == .satisfied
        
        // If we were waiting for network and it's now available, process queued sync
        if wasOffline && isNowOnline, let queuedContext = offlineQueuedSync {
            logger.info("Network recovered - processing queued sync")
            isWaitingForNetwork = false
            offlineQueuedSync = nil
            
            // Wait a brief moment for network to stabilize
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            await performAutoSyncIfNeeded(context: queuedContext)
        }
        
        // Update network waiting state
        isWaitingForNetwork = !isNowOnline
    }
    
    /// Phase 4.1: Queue sync operation for when network recovers
    private func queueSyncForNetworkRecovery(context: AutoSyncContext) {
        offlineQueuedSync = context
        isWaitingForNetwork = true
        logger.info("Sync queued for network recovery - context: \(context.rawValue)")
    }
    
    /// Phase 4.1: Record sync failure for intelligent retry decisions
    private func recordSyncFailure(error: Error, context: AutoSyncContext) {
        // Get current network type for failure analysis
        let currentNetworkType = getCurrentNetworkType()
        
        let failure = SyncFailure(
            timestamp: Date(),
            error: error,
            networkType: currentNetworkType
        )
        
        failureHistory.append(failure)
        
        // Limit history size
        if failureHistory.count > maxFailureHistorySize {
            failureHistory.removeFirst()
        }
        
        logger.debug("Recorded sync failure - total failures: \(self.failureHistory.count)")
    }
    
    /// Phase 4.1: Get current network type synchronously for failure recording
    private func getCurrentNetworkType() -> NetworkQuality {
        // This is a simplified version for failure recording
        // We'll use the last known state or default to unknown
        return .poor // Simplified - could be enhanced with cached network state
    }
    
    /// Phase 4.1: Determine retry strategy based on error and failure history
    private func determineRetryStrategy(for error: Error) -> RetryStrategy {
        // Check if this is a network-related error
        if isNetworkError(error) {
            return .waitForNetwork
        }
        
        // Check for permanent errors that shouldn't be retried
        if isPermanentError(error) {
            return .abandon
        }
        
        // Check if we've exceeded maximum failures
        if consecutiveFailures >= maxConsecutiveFailures * 2 {
            logger.debug("Too many consecutive failures - abandoning retries")
            return .abandon
        }
        
        // Analyze recent failure patterns
        let recentFailures = failureHistory.filter { 
            Date().timeIntervalSince($0.timestamp) < 3600 // Last hour
        }
        
        if recentFailures.count >= 5 {
            logger.debug("Too many recent failures - using longer backoff")
            let delay = calculateIntelligentBackoffDelay()
            return .exponentialBackoff(delay: delay)
        }
        
        // For transient errors, use exponential backoff
        let delay = calculateBackoffDelay()
        return .exponentialBackoff(delay: delay)
    }
    
    /// Phase 4.1: Check if error is network-related
    private func isNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return true
            default:
                return false
            }
        }
        
        // Check for ArticleServiceError network errors
        if let serviceError = error as? ArticleServiceError {
            switch serviceError {
            case .networkError:
                return true
            default:
                return false
            }
        }
        
        return false
    }
    
    /// Phase 4.1: Check if error is permanent (shouldn't retry)
    private func isPermanentError(_ error: Error) -> Bool {
        if let serviceError = error as? ArticleServiceError {
            switch serviceError {
            case .networkError, .databaseError, .articleNotFound:
                return false
            case .validationError, .cancelled, .unknown:
                return false // Treat these as retryable too
            }
        }
        
        // For now, treat most errors as retryable unless they're clearly permanent
        return false
    }
    
    /// Phase 4.1: Calculate intelligent backoff delay based on failure patterns
    private func calculateIntelligentBackoffDelay() -> TimeInterval {
        // Base exponential backoff
        let baseDelay = calculateBackoffDelay()
        
        // Analyze failure patterns to adjust delay
        let recentNetworkFailures = failureHistory.filter { failure in
            Date().timeIntervalSince(failure.timestamp) < 1800 && // Last 30 minutes
            failure.networkType == .poor || failure.networkType == .offline
        }
        
        // If we have many recent network failures, increase delay significantly
        if recentNetworkFailures.count >= 3 {
            let networkFailureMultiplier = min(Double(recentNetworkFailures.count), 5.0)
            return min(baseDelay * networkFailureMultiplier, 3600) // Max 1 hour
        }
        
        return baseDelay
    }
    
    /// Phase 2.3: Cleanup resources when coordinator is deallocated
    deinit {
        // Cancel all Combine subscriptions (can be done synchronously)
        cancellables.removeAll()
        
        // Stop periodic sync timer directly (avoiding main actor isolation issues)
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        
        // Phase 4.1: Cleanup network monitoring
        networkStateMonitor?.cancel()
        networkStateMonitor = nil
    }
}

// MARK: - Phase 4.3: Performance Monitoring Types

extension AutoSyncCoordinator {
    /// Performance metrics for individual sync operations
    public struct PerformanceMetric {
        let timestamp: Date
        let context: AutoSyncContext
        let duration: TimeInterval
        let articlesProcessed: Int
        let dataVolumeBytes: Int
        let networkSpeedKbps: Double?
        let memoryUsageMB: Double
        let batteryLevel: Float?
        let networkCondition: NetworkQuality
        let success: Bool
        let error: AutoSyncError?
        
        /// Articles processed per second
        var efficiency: Double {
            guard duration > 0, articlesProcessed > 0 else { return 0 }
            return Double(articlesProcessed) / duration
        }
        
        /// Network throughput in kbps
        var throughputKbps: Double? {
            guard duration > 0, dataVolumeBytes > 0 else { return nil }
            return (Double(dataVolumeBytes) * 8) / (duration * 1000)
        }
        
        /// Performance quality score (0-100)
        var performanceScore: Double {
            var score: Double = 0
            
            // Success contributes 40%
            if success { score += 40 }
            
            // Efficiency contributes 30%
            let normalizedEfficiency = min(efficiency / 2.0, 1.0) // 2+ articles/sec = max score
            score += normalizedEfficiency * 30
            
            // Duration contributes 20% (faster is better)
            let normalizedDuration = max(0, 1 - (duration / 60.0)) // 60+ seconds = min score
            score += normalizedDuration * 20
            
            // Network condition contributes 10%
            let networkScore: Double
            switch networkCondition {
            case .wifi, .wiredEthernet: networkScore = 1.0
            case .cellular: networkScore = 0.7
            case .poor: networkScore = 0.3
            case .offline: networkScore = 0.0
            }
            score += networkScore * 10
            
            return min(score, 100)
        }
    }
    
    /// System resource snapshot
    public struct SystemResourceSnapshot {
        let timestamp: Date
        let memoryUsageMB: Double
        let availableMemoryMB: Double
        let batteryLevel: Float?
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
        
        var memoryUsageBytes: UInt64 {
            UInt64(memoryUsageMB * 1024 * 1024)
        }
        
        var memoryPressure: MemoryPressure {
            let usageRatio = memoryUsageMB / (memoryUsageMB + availableMemoryMB)
            switch usageRatio {
            case 0..<0.7: return .normal
            case 0.7..<0.85: return .warning
            case 0.85..<0.95: return .critical
            default: return .critical
            }
        }
        
        public enum MemoryPressure: String, CaseIterable {
            case normal = "Normal"
            case warning = "Warning"
            case critical = "Critical"
        }
    }
}

// MARK: - Phase 4.1: Network Intelligence Types

extension AutoSyncCoordinator {
    /// Network quality categories for intelligent sync decisions
    public enum NetworkQuality {
        case wifi
        case cellular
        case wiredEthernet
        case poor
        case offline
    }
    
    /// Failure tracking for intelligent retry behavior
    private struct SyncFailure {
        let timestamp: Date
        let error: Error
        let networkType: NetworkQuality
    }
    
    /// Phase 4.1: Retry strategies for different error types
    private enum RetryStrategy {
        case immediate
        case exponentialBackoff(delay: TimeInterval)
        case waitForNetwork
        case abandon
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
