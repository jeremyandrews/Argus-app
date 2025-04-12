import CloudKit
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// A dedicated container for SwiftData models used in the modernization plan
/// This keeps our new models separate from the existing app infrastructure
class SwiftDataContainer {
    // A singleton instance for easier access
    static let shared = SwiftDataContainer()

    // The model container for our new models
    let container: ModelContainer

    // Container configuration
    enum ContainerType {
        case cloudKit // With CloudKit integration
        case localPersistent // Local persistent storage only
        case fallback // Fallback mode after error
    }

    // Current container type
    private(set) var containerType: ContainerType

    // CloudKit container identifier
    private let cloudKitContainerIdentifier = "iCloud.com.andrews.Argus.Argus"

    // Status tracking
    private(set) var lastError: Error?
    private(set) var cloudKitError: Error?

    // Health monitor for CloudKit operations
    let healthMonitor: CloudKitHealthMonitor

    // Request coordinator for managing CloudKit operations
    private let requestCoordinator: CloudKitRequestCoordinator

    // Initialization status
    var status: String {
        switch containerType {
        case .cloudKit:
            return "Using CloudKit integration (\(healthMonitor.status.emoji) \(healthMonitor.status.rawValue))"
        case .localPersistent:
            return "Using local persistent storage"
        case .fallback:
            if let error = lastError {
                return "Using fallback after error: \(error.localizedDescription)"
            } else {
                return "Using fallback storage"
            }
        }
    }

    // Database location
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private var testStorageURL: URL {
        return documentsDirectory.appendingPathComponent("ArgusTestDB.store")
    }

    private init() {
        // Initialize all stored properties first
        containerType = .fallback // Default until we succeed
        cloudKitError = nil
        lastError = nil

        // Initialize health monitor
        healthMonitor = CloudKitHealthMonitor(containerIdentifier: cloudKitContainerIdentifier)
        CloudKitHealthMonitor.shared = healthMonitor

        // Initialize request coordinator
        requestCoordinator = CloudKitRequestCoordinator(containerIdentifier: cloudKitContainerIdentifier)

        // Create a schema with only the new models plus legacy SeenArticle for migration
        let schema = Schema([
            // Legacy model needed for migration only
            SeenArticle.self,

            // New SwiftData models - our primary schema
            ArticleModel.self,
            SeenArticleModel.self,
            TopicModel.self,
        ])

        // Storage path
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbPath = documentsDir.appendingPathComponent("ArgusTestDB.store")

        // First attempt: Try CloudKit integration
        ModernizationLogger.logTransitionStart("Creating SwiftData container with CloudKit", component: .cloudKit)

        do {
            // Create configuration with CloudKit integration
            ModernizationLogger.log(.debug, component: .cloudKit,
                                    message: "Setting up CloudKit container for identifier: \(cloudKitContainerIdentifier)")
            let cloudKitConfig = ModelConfiguration(schema: schema)

            container = try ModelContainer(for: schema, configurations: [cloudKitConfig])

            // Set as provisional CloudKit container, pending verification
            containerType = .cloudKit

            ModernizationLogger.logTransitionCompletion(
                "CloudKit container creation",
                component: .cloudKit,
                success: true,
                detail: "Container created, verifying operational status"
            )

            // IMPORTANT: Container creation succeeded, but we need to verify
            // CloudKit operations actually work by running a test
            Task {
                if await healthMonitor.verifyCloudKitAvailability() {
                    // CloudKit is fully operational
                    ModernizationLogger.log(.info, component: .cloudKit,
                                            message: "CloudKit integration verified and operational")
                } else {
                    // Container created but operations fail, switch to local mode
                    ModernizationLogger.logFallback(
                        from: "CloudKit storage",
                        to: "Local persistent storage",
                        reason: "CloudKit operational verification failed",
                        component: .cloudKit
                    )
                    await switchToLocalMode()
                }
            }
        } catch {
            // Log CloudKit error details
            ModernizationLogger.logCloudKitError(
                operation: "Creating CloudKit container",
                error: error,
                detail: "Falling back to local persistent storage"
            )

            print("Failed to create CloudKit container: \(error)")
            cloudKitError = error

            // Second attempt: Fall back to local persistent storage
            ModernizationLogger.logTransitionStart("Creating fallback persistent container", component: .cloudKit)

            // Use persistent storage with a dedicated test database name
            print("Creating persistent SwiftData container at: \(dbPath.path)")
            let localConfig = ModelConfiguration(url: dbPath)

            do {
                container = try ModelContainer(for: schema, configurations: [localConfig])
                containerType = .localPersistent

                ModernizationLogger.logTransitionCompletion(
                    "Fallback container creation",
                    component: .cloudKit,
                    success: true,
                    detail: "Successfully created local persistent container as fallback"
                )

                print("Local persistent SwiftData container successfully created")
            } catch {
                // Log the fallback error
                ModernizationLogger.log(
                    .critical,
                    component: .cloudKit,
                    message: "CRITICAL: Failed to create both CloudKit and local persistent containers: \(error.localizedDescription)"
                )

                print("Failed to create persistent container: \(error)")
                lastError = error
                containerType = .fallback

                // Create a container in the temp directory as a last resort
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ArgusEmergencyFallback.store")

                ModernizationLogger.logFallback(
                    from: "Normal storage paths",
                    to: "Temporary directory fallback",
                    reason: "Both CloudKit and persistent storage failed",
                    component: .cloudKit
                )

                do {
                    let emergencyConfig = ModelConfiguration(url: tempURL)
                    container = try ModelContainer(for: schema, configurations: [emergencyConfig])

                    ModernizationLogger.log(
                        .warning,
                        component: .cloudKit,
                        message: "Created emergency fallback container in temporary directory"
                    )
                } catch {
                    // At this point, we have no choice but to crash, as we've tried all options
                    ModernizationLogger.log(
                        .critical,
                        component: .cloudKit,
                        message: "FATAL: All container creation attempts failed - app cannot function: \(error.localizedDescription)"
                    )

                    fatalError("All container creation attempts failed - app cannot function: \(error)")
                }
            }
        }

        // Set up notification observers for CloudKit health changes
        setupCloudKitHealthObservers()
    }

    /// Switches from CloudKit mode to local persistent storage mode
    /// Call this when CloudKit operations are failing
    @MainActor
    func switchToLocalMode() async {
        // Only switch if we're currently in CloudKit mode
        guard containerType == .cloudKit else { return }

        ModernizationLogger.log(.warning, component: .cloudKit,
                                message: "Switching from CloudKit to local-only mode")

        containerType = .localPersistent

        // Cancel any pending CloudKit operations
        Task {
            await requestCoordinator.cancelOperations(ofType: nil)
        }

        // If we have a properly created container, keep using it but without CloudKit operations
        // No need to recreate the container, just change how we use it

        // Notify observers about the mode change
        NotificationCenter.default.post(
            name: .cloudKitModeChanged,
            object: self,
            userInfo: ["containerType": containerType.rawValue]
        )
    }

    /// Try to recover CloudKit functionality when it becomes available again
    @MainActor
    func attemptCloudKitRecovery() async -> Bool {
        // Only attempt recovery if we're not already using CloudKit
        guard containerType != .cloudKit else { return true }

        // Verify CloudKit is now available
        if await healthMonitor.verifyCloudKitAvailability() {
            ModernizationLogger.log(.info, component: .cloudKit,
                                    message: "CloudKit recovery successful, reinstating CloudKit mode")

            // Switch back to CloudKit mode
            containerType = .cloudKit

            // Notify observers about the mode change
            NotificationCenter.default.post(
                name: .cloudKitModeChanged,
                object: self,
                userInfo: ["containerType": containerType.rawValue]
            )

            return true
        }

        return false
    }

    /// Set up observers for CloudKit health status changes
    private func setupCloudKitHealthObservers() {
        NotificationCenter.default.addObserver(
            forName: .cloudKitHealthStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            // If health status indicates failure, switch to local mode
            if let status = notification.userInfo?["status"] as? String,
               status == CloudKitHealthMonitor.HealthStatus.failed.rawValue,
               self.containerType == .cloudKit
            {
                Task { @MainActor in
                    await self.switchToLocalMode()
                }
            }
        }
    }

    /// Schedule a CloudKit operation through the coordinator
    /// This method will check health status first
    func scheduleCloudKitOperation<T: CKOperation>(_ operation: T,
                                                   type: CloudKitRequestCoordinator.RequestType,
                                                   priority: Int = 1,
                                                   description: String = "") async -> UUID?
    {
        // Check if we should use CloudKit at all
        guard containerType == .cloudKit, !healthMonitor.shouldUseFallback() else {
            ModernizationLogger.log(.warning, component: .cloudKit,
                                    message: "Skipping CloudKit operation - using local mode or health check failed")
            return nil
        }

        // Schedule through coordinator
        return await requestCoordinator.scheduleOperation(
            operation,
            type: type,
            priority: priority,
            description: description
        )
    }

    /// Makes a best effort to delete any persistent store files
    func resetStore() -> String {
        // Cancel any scheduled health checks
        healthMonitor.cancelScheduledChecks()

        // Cancel any pending operations
        Task {
            await requestCoordinator.cancelOperations(ofType: nil)
        }

        var deletedFiles: [String] = []
        var errors: [String] = []

        // Try multiple locations where SwiftData might store its files
        let possibleLocations = [
            // Default app support directory
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            // Document directory
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            // Library directory
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
            // Caches directory
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        // First specifically target our test database file
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let testDBURL = documentsDirectory.appendingPathComponent("ArgusTestDB.store")
        let testDBExtensions = ["", "-wal", "-shm", ".sqlite-wal", ".sqlite-shm"]

        for ext in testDBExtensions {
            let fileURL = testDBURL.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    print("Removed test database file: \(fileURL.path)")
                    deletedFiles.append(fileURL.lastPathComponent)
                } catch {
                    print("Failed to remove test database file \(fileURL.lastPathComponent): \(error)")
                    errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Look for typical SwiftData store files with various naming patterns
        let storeNames = [
            "default.store",
            "ArgusSwiftData.store",
            "SwiftData.sqlite",
            "ArticleModel.store",
            "Argus.store",
            "ArgusTestDB.store",
        ]
        let extensions = ["", "-wal", "-shm", ".sqlite-wal", ".sqlite-shm"]

        for location in possibleLocations {
            print("Searching for SwiftData files in: \(location.path)")

            for name in storeNames {
                for ext in extensions {
                    let fileURL = location.appendingPathComponent(name + ext)

                    // Try to remove if exists
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        do {
                            try FileManager.default.removeItem(at: fileURL)
                            print("Removed SwiftData file: \(fileURL.path)")
                            deletedFiles.append(fileURL.lastPathComponent)
                        } catch {
                            print("Failed to remove \(fileURL.lastPathComponent): \(error)")
                            errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }

            // Also try to find any SwiftData directories that might exist
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
                for item in contents {
                    if item.lastPathComponent.contains("SwiftData") ||
                        item.lastPathComponent.contains("ModelContainer") ||
                        item.lastPathComponent.contains("Argus.sqlite") ||
                        item.lastPathComponent.contains("ArgusTestDB")
                    {
                        do {
                            try FileManager.default.removeItem(at: item)
                            print("Removed SwiftData directory/file: \(item.path)")
                            deletedFiles.append(item.lastPathComponent)
                        } catch {
                            print("Failed to remove \(item.lastPathComponent): \(error)")
                            errors.append("\(item.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                print("Failed to list directory contents at \(location.path): \(error)")
            }
        }

        // Also clear UserDefaults related to migration
        UserDefaults.standard.removeObject(forKey: "migrationProgress")

        // Build result summary
        var result = "Store reset attempted - please restart the app for changes to take effect\n\n"

        if !deletedFiles.isEmpty {
            result += "Deleted \(deletedFiles.count) files:\n"
            result += deletedFiles.joined(separator: "\n")
            result += "\n\n"
        } else {
            result += "No SwiftData files found to delete.\n\n"
        }

        if !errors.isEmpty {
            result += "Encountered \(errors.count) errors:\n"
            result += errors.joined(separator: "\n")
        }

        print(result)
        return result
    }

    /// Creates a new ModelContext for use in background operations
    func newContext() -> ModelContext {
        return ModelContext(container)
    }

    /// The main context for main thread operations
    @MainActor
    func mainContext() -> ModelContext {
        return ModelContext(container)
    }
}

// Extension to define CloudKit-related notification names
extension Notification.Name {
    /// Posted when the CloudKit mode changes (between CloudKit and local-only)
    static let cloudKitModeChanged = Notification.Name("cloudKitModeChanged")
}

// Make ContainerType Rawrepresentable for notifications
extension SwiftDataContainer.ContainerType: RawRepresentable {
    typealias RawValue = String

    init?(rawValue: String) {
        switch rawValue {
        case "cloudKit": self = .cloudKit
        case "localPersistent": self = .localPersistent
        case "fallback": self = .fallback
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .cloudKit: return "cloudKit"
        case .localPersistent: return "localPersistent"
        case .fallback: return "fallback"
        }
    }
}
