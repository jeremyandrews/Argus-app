import Combine
import Foundation
import SQLite3
import SwiftUI

/**
 * MigrationCoordinator - Central coordinator for the one-time database migration
 *
 * This coordinator is the primary entry point for the migration system and orchestrates
 * the entire migration process. It is designed to be self-contained and easily removable
 * once all users have completed the migration to SwiftData.
 *
 * ## Primary Responsibilities
 * - Determine if migration is needed based on state tracking
 * - Initialize and manage the MigrationService
 * - Display migration UI when needed
 * - Track migration state and progress in UserDefaults
 * - Handle app termination during migration
 *
 * ## Dependencies
 * - MigrationService: Performs the actual data migration
 * - UserDefaults: Stores migration state
 * - MigrationModalView: UI for displaying migration progress
 *
 * ## Removal Considerations
 * - This is the primary entry point from ArgusApp.swift
 * - Should be removed only after verifying all users have completed migration
 * - Removing this coordinator should be the final step in migration system removal
 * - When removing, also clean up associated UserDefaults keys
 *
 * ## Future Removal Path
 * 1. In ArgusApp.swift, remove the call to checkMigrationStatus()
 * 2. Remove all migration-related UI components (MigrationModalView, etc.)
 * 3. Remove MigrationService.swift
 * 4. Finally, remove this coordinator class
 * 5. Clean up UserDefaults keys: migration_completed, migration_count, last_migration_date
 *
 * @see migration-removal-plan.md for complete removal strategy
 */

// Keys for UserDefaults - These will be removed when migration system is removed
private enum MigrationDefaults {
    static let migrationCompletedKey = "migration_completed"
    static let migrationCountKey = "migration_count"
    static let lastMigrationDateKey = "last_migration_date"
}

/// Self-contained coordinator for migration management
@MainActor
final class MigrationCoordinator: ObservableObject {
    // Singleton for app-wide access
    static let shared = MigrationCoordinator()

    // Public properties for observation
    @Published private(set) var isMigrationRequired: Bool = false
    @Published private(set) var isMigrationActive: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String = ""

    // Additional tracking properties
    @Published private(set) var migrationCount: Int = 0
    @Published private(set) var lastMigrationDate: Date?
    @Published private(set) var isMigrationCompleted: Bool = false

    // Internal state and service
    private var migrationService: MigrationService?
    private var cancelBag: Set<AnyCancellable> = []

    // Private init for singleton pattern
    private init() {
        // Load previous settings
        loadMigrationSettings()
    }

    // Load migration settings from UserDefaults
    private func loadMigrationSettings() {
        let defaults = UserDefaults.standard

        // Load migration completion state
        isMigrationCompleted = defaults.bool(forKey: MigrationDefaults.migrationCompletedKey)

        // Load migration count
        migrationCount = defaults.integer(forKey: MigrationDefaults.migrationCountKey)

        // Load last migration date
        if let dateValue = defaults.object(forKey: MigrationDefaults.lastMigrationDateKey) as? Date {
            lastMigrationDate = dateValue
        }

        // Log current state
        ModernizationLogger.log(.info, component: .migration,
                                message: "Migration settings loaded - " +
                                    "Completed: \(isMigrationCompleted), " +
                                    "Count: \(migrationCount)")
    }

    // Save migration settings to UserDefaults
    private func saveMigrationSettings() {
        let defaults = UserDefaults.standard

        defaults.set(isMigrationCompleted, forKey: MigrationDefaults.migrationCompletedKey)
        defaults.set(migrationCount, forKey: MigrationDefaults.migrationCountKey)

        if let date = lastMigrationDate {
            defaults.set(date, forKey: MigrationDefaults.lastMigrationDateKey)
        }

        ModernizationLogger.log(.debug, component: .migration,
                                message: "Migration settings saved")
    }

    // Note: Removed setMigrationMode function since we're committed to production mode

    /// Public method to check if migration is needed
    func checkMigrationStatus() async -> Bool {
        // If migration is already completed, no migration is needed
        if isMigrationCompleted {
            ModernizationLogger.log(.info, component: .migration,
                                    message: "Migration already completed, no migration needed")
            return false
        }

        // Lazy initialization of migration service
        if migrationService == nil {
            migrationService = await MigrationService()
        }

        // Setup bindings if not already done
        setupBindings()

        // Check if migration is needed
        guard let service = migrationService else {
            return false
        }

        isMigrationRequired = service.wasMigrationInterrupted() ||
            service.migrationProgress.state == .inProgress ||
            !isMigrationCompleted

        ModernizationLogger.log(.info, component: .migration,
                                message: "Migration status check - Required: \(isMigrationRequired)")

        return isMigrationRequired
    }

    /// Public method to start migration
    func startMigration() async -> Bool {
        guard let service = migrationService, isMigrationRequired else {
            ModernizationLogger.log(.info, component: .migration,
                                    message: "Migration not required or service not available")
            return false
        }

        ModernizationLogger.log(.info, component: .migration,
                                message: "Starting migration")

        // Flag as active
        isMigrationActive = true

        // Run migration with high priority
        let result = await Task.detached(priority: .userInitiated) {
            await service.migrateAllData()
        }.value

        // Update migration tracking
        migrationCount += 1
        lastMigrationDate = Date()

        // If migration succeeded, mark it as completed
        if result {
            isMigrationCompleted = true
            ModernizationLogger.log(.info, component: .migration,
                                    message: "Migration completed successfully")
        }

        // Save updated settings
        saveMigrationSettings()

        ModernizationLogger.log(.info, component: .migration,
                                message: "Migration completed with result: \(result)")

        // Handle completion - no need for MainActor.run since this class is already @MainActor
        // Auto-dismiss after completion with slight delay
        if result {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.isMigrationActive = false
            }
        } else {
            // Even on error, auto-dismiss after a longer delay
            // This ensures the app isn't permanently stuck
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                self.isMigrationActive = false
            }
        }

        return result
    }

    /// Setup bindings to migration service properties
    private func setupBindings() {
        guard let service = migrationService else { return }

        // Set initial values
        progress = service.progress
        status = service.status

        // Setup observation of service properties
        Task { @MainActor in
            for await newProgress in service.$progress.values {
                self.progress = newProgress
            }
        }

        Task { @MainActor in
            for await newStatus in service.$status.values {
                self.status = newStatus
            }
        }
    }

    /// Public method to stop migration and dismiss UI
    func completeMigration() {
        ModernizationLogger.log(.info, component: .migration,
                                message: "Completing migration UI")
        isMigrationActive = false
    }

    // Reset functionality is no longer needed in one-time migration approach

    /// Mark migration as completed without actually running it
    /// Used when source tables don't exist but we need to mark migration as complete
    func markMigrationCompleted() {
        ModernizationLogger.log(.warning, component: .migration,
                                message: "Manually marking migration as completed without migration")
        // Set as completed
        isMigrationCompleted = true
        // Update tracking
        migrationCount += 1
        lastMigrationDate = Date()
        // Save settings
        saveMigrationSettings()

        // Ensure migration not flagged as active
        isMigrationActive = false
    }

    /// Check if the app was terminated during migration
    func wasInterrupted() -> Bool {
        return migrationService?.wasMigrationInterrupted() ?? false
    }

    /// Mark app as terminating during migration
    func appWillTerminate() {
        // Mark migration as interrupted through public API
        if let service = migrationService, service.migrationProgress.state == .inProgress {
            ModernizationLogger.log(.warning, component: .migration,
                                    message: "App terminating during migration - marking as interrupted")
            service.migrationProgress.migrationInterrupted = true
            // Save the progress to UserDefaults immediately
            service.saveMigrationProgress()
        }

        // Save our own settings as well
        saveMigrationSettings()
    }

    // Note: Removed shouldTransitionToProductionMode function since we're now always in production mode
}
