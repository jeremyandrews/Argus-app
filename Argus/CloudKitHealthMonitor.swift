import Foundation
import CloudKit

/// Monitors CloudKit operational health and provides battery-efficient fallback mechanisms
class CloudKitHealthMonitor {
    /// Health status of CloudKit integration
    enum HealthStatus: String {
        case unknown = "Unknown"
        case healthy = "Healthy"
        case degraded = "Degraded"
        case failed = "Failed"
        
        var emoji: String {
            switch self {
            case .unknown: return "❓"
            case .healthy: return "✅"
            case .degraded: return "⚠️"
            case .failed: return "❌"
            }
        }
    }
    
    /// Tracks the current health status
    private(set) var status: HealthStatus = .unknown
    
    /// Tracks CloudKit operation metrics
    private var failedOperations = 0
    private var successfulOperations = 0
    private var lastError: Error?
    private var lastOperationDate: Date?
    
    /// Configurable thresholds
    private let fallbackThreshold = 3
    private let recoverThreshold = 2
    
    /// CloudKit container identifier
    private let containerIdentifier: String
    
    /// Initialize with container identifier
    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }
    
    /// Verifies if CloudKit is operational
    func verifyCloudKitAvailability() async -> Bool {
        ModernizationLogger.log(.debug, component: .cloudKit, 
                               message: "Verifying CloudKit availability")
        
        // Don't attempt verification during serious thermal conditions
        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .serious || thermalState == .critical {
            ModernizationLogger.log(.warning, component: .cloudKit, 
                                   message: "Skipping CloudKit verification due to \(thermalState) thermal state")
            return status == .healthy // Keep current status
        }
        
        // First check iCloud account status
        do {
            let container = CKContainer(identifier: containerIdentifier)
            let accountStatus = try await container.accountStatus()
            
            if accountStatus == .available {
                // Then test if we can access the database using a simple query
                let success = await checkDatabaseAccess(container: container)
                return success
            } else {
                // Account status not available
                let error = NSError(
                    domain: "CloudKitHealthMonitor", 
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "iCloud account status: \(accountStatus)"]
                )
                recordFailure(error: error)
                return false
            }
        } catch {
            // Account status check failed
            recordFailure(error: error)
            return false
        }
    }
    
    /// Checks if we can access the CloudKit database using a simple operation
    private func checkDatabaseAccess(container: CKContainer) async -> Bool {
        // Create a simple query
        let query = CKQuery(recordType: "TestRecordType", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Use fully async API for iOS 15+
        do {
            let database = container.publicCloudDatabase
            
            // Use a zone ID operation as a simple test
            let config = CKOperation.Configuration()
            config.timeoutIntervalForRequest = 10
            
            // Starting in iOS 15, we can use the fully async API
            let zone = CKRecordZone.ID(zoneName: CKRecordZone.ID.defaultZoneName, ownerName: CKCurrentUserDefaultName)
            
            // Test by checking zone metadata - a lightweight operation
            _ = try await database.recordZone(for: zone)
            
            // If we get here without error, CloudKit is operational
            ModernizationLogger.log(.debug, component: .cloudKit,
                                  message: "CloudKit zone check succeeded")
            
            // Record success
            recordSuccess()
            return true
        } catch {
            // The operation failed
            ModernizationLogger.logCloudKitError(
                operation: "CloudKit zone check",
                error: error
            )
            
            recordFailure(error: error)
            return false
        }
    }
    
    /// Performs a health check and notifies observers of any status changes
    func performHealthCheck() async {
        let previousStatus = status
        let isAvailable = await verifyCloudKitAvailability()
        
        // Only notify if status changed
        if previousStatus != status {
            NotificationCenter.default.post(
                name: .cloudKitHealthStatusChanged,
                object: self,
                userInfo: [
                    "isAvailable": isAvailable,
                    "status": status.rawValue,
                    "previousStatus": previousStatus.rawValue
                ]
            )
        }
    }
    
    /// Records a successful CloudKit operation, potentially upgrading status
    func recordSuccess() {
        successfulOperations += 1
        failedOperations = max(0, failedOperations - 1) // Gradual decay of failures
        lastOperationDate = Date()
        
        let oldStatus = status
        
        // Update status based on success threshold
        if successfulOperations >= recoverThreshold {
            if status != .healthy {
                status = .healthy
                ModernizationLogger.log(.info, component: .cloudKit, 
                                       message: "CloudKit health status changed to \(status.emoji) \(status.rawValue) after \(successfulOperations) successful operations")
            }
        } else if status == .failed {
            // Immediate upgrade from failed to degraded on any success
            status = .degraded
            ModernizationLogger.log(.info, component: .cloudKit, 
                                   message: "CloudKit health status improved to \(status.emoji) \(status.rawValue)")
        }
        
        // If status changed, post notification
        if oldStatus != status {
            NotificationCenter.default.post(
                name: .cloudKitHealthStatusChanged,
                object: self,
                userInfo: [
                    "isAvailable": true,
                    "status": status.rawValue,
                    "previousStatus": oldStatus.rawValue
                ]
            )
        }
    }
    
    /// Records a failed CloudKit operation, potentially downgrading status
    func recordFailure(error: Error) {
        lastError = error
        failedOperations += 1
        successfulOperations = 0
        lastOperationDate = Date()
        
        let oldStatus = status
        
        // Update status based on failure thresholds
        if failedOperations >= fallbackThreshold {
            if status != .failed {
                status = .failed
                ModernizationLogger.logCloudKitError(
                    operation: "CloudKit operation",
                    error: error,
                    detail: "Health status changed to \(status.emoji) \(status.rawValue) after \(failedOperations) failures"
                )
            }
        } else if status == .healthy {
            // Immediate downgrade from healthy to degraded on any failure
            status = .degraded
            ModernizationLogger.log(.warning, component: .cloudKit, 
                                   message: "CloudKit health status degraded to \(status.emoji) \(status.rawValue)")
        }
        
        // If status changed, post notification
        if oldStatus != status {
            NotificationCenter.default.post(
                name: .cloudKitHealthStatusChanged,
                object: self,
                userInfo: [
                    "isAvailable": false,
                    "status": status.rawValue,
                    "previousStatus": oldStatus.rawValue,
                    "error": error.localizedDescription
                ]
            )
        }
    }
    
    /// Determines if the application should fall back to local storage
    func shouldUseFallback() -> Bool {
        return status == .failed || 
               (status == .degraded && failedOperations > 1)
    }
    
    /// We don't need to cancel anything since we're using a task-based approach
    func cancelScheduledChecks() {
        // No-op - scheduling is handled by BGTaskScheduler in AppDelegate
    }
    
    /// Returns a debug description of current health status
    var statusDescription: String {
        var description = "CloudKit Status: \(status.emoji) \(status.rawValue)"
        description += "\nSuccesses: \(successfulOperations), Failures: \(failedOperations)"
        if let lastOpDate = lastOperationDate {
            let formatter = RelativeDateTimeFormatter()
            description += "\nLast operation: \(formatter.localizedString(for: lastOpDate, relativeTo: Date()))"
        }
        if let error = lastError {
            description += "\nLast error: \(error.localizedDescription)"
        }
        return description
    }
}

/// Extension to define CloudKit health-related notification names
extension Notification.Name {
    static let cloudKitHealthStatusChanged = Notification.Name("cloudKitHealthStatusChanged")
}
