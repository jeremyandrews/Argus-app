import Combine
import Foundation
import SQLite3
import SwiftUI

// Keys for UserDefaults
private enum MigrationDefaults {
    static let migrationModeKey = "migration_mode"
    static let oneTimeMigrationCompletedKey = "one_time_migration_completed"
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

    // Migration mode - now permanent production mode
    private(set) var currentMigrationMode: MigrationMode = .production

    // Additional tracking properties
    @Published private(set) var migrationCount: Int = 0
    @Published private(set) var lastMigrationDate: Date?
    @Published private(set) var isOneTimeMigrationCompleted: Bool = false

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

        // Note: We no longer load the migration mode - always using production mode
        ModernizationLogger.log(.info, component: .migration,
                                message: "Using permanent one-time migration mode (production)")

        // Load one-time migration completion state
        isOneTimeMigrationCompleted = defaults.bool(forKey: MigrationDefaults.oneTimeMigrationCompletedKey)

        // Load migration count
        migrationCount = defaults.integer(forKey: MigrationDefaults.migrationCountKey)

        // Load last migration date
        if let dateValue = defaults.object(forKey: MigrationDefaults.lastMigrationDateKey) as? Date {
            lastMigrationDate = dateValue
        }

        // Log current state
        ModernizationLogger.log(.info, component: .migration,
                                message: "Migration settings loaded - Mode: \(currentMigrationMode.rawValue), " +
                                    "Completed: \(isOneTimeMigrationCompleted), " +
                                    "Count: \(migrationCount)")
    }

    // Save migration settings to UserDefaults
    private func saveMigrationSettings() {
        let defaults = UserDefaults.standard

        defaults.set(currentMigrationMode.rawValue, forKey: MigrationDefaults.migrationModeKey)
        defaults.set(isOneTimeMigrationCompleted, forKey: MigrationDefaults.oneTimeMigrationCompletedKey)
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
        // If one-time migration is completed and mode is production, no migration is needed
        if currentMigrationMode == .production && isOneTimeMigrationCompleted {
            ModernizationLogger.log(.info, component: .migration,
                                    message: "One-time migration already completed, no migration needed")
            return false
        }

        // Lazy initialization of migration service with current mode
        if migrationService == nil {
            migrationService = await MigrationService(mode: currentMigrationMode)
        }

        // Setup bindings if not already done
        setupBindings()

        // Check if migration is needed
        guard let service = migrationService else {
            return false
        }

        isMigrationRequired = service.migrationMode == .temporary ||
            service.wasMigrationInterrupted() ||
            service.migrationProgress.state == .inProgress ||
            (service.migrationMode == .production && !isOneTimeMigrationCompleted)

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
                                message: "Starting migration in \(service.migrationMode.rawValue) mode")

        // Flag as active
        isMigrationActive = true

        // Run migration with high priority
        let result = await Task.detached(priority: .userInitiated) {
            await service.migrateAllData()
        }.value

        // Update migration tracking
        migrationCount += 1
        lastMigrationDate = Date()

        // If we're in production mode and migration succeeded, mark it as completed
        if result && service.migrationMode == .production {
            isOneTimeMigrationCompleted = true
            ModernizationLogger.log(.info, component: .migration,
                                    message: "One-time migration completed successfully")
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

    /// Reset one-time migration status (for testing)
    func resetOneTimeMigrationStatus() {
        ModernizationLogger.log(.warning, component: .migration,
                                message: "Resetting one-time migration status")
        isOneTimeMigrationCompleted = false
        saveMigrationSettings()
    }

    /// Force a complete migration reset - clears all migration state and forces re-migration
    /// Additionally ensures database tables are properly rebuilt
    func forceCompleteReset() async {
        ModernizationLogger.log(.warning, component: .migration,
                                message: "FORCING COMPLETE MIGRATION RESET")

        // Reset one-time migration completion flag
        isOneTimeMigrationCompleted = false

        // Reset any stored migration progress
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "migrationProgress")
        defaults.removeObject(forKey: "one_time_migration_completed")

        // CRITICAL: Delete and recreate database files
        // First attempt to use the SwiftDataContainer's resetStore method
        let resetResult = SwiftDataContainer.shared.resetStore()
        ModernizationLogger.log(.warning, component: .migration,
                                message: "Database reset result: \(resetResult)")

        // Also try direct deletion of any default.store files
        // that might be causing the table creation issues
        do {
            // Try to find and delete the default store file
            let fileManager = FileManager.default
            let applicationSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )

            // Paths to check for CoreData stores
            let possiblePaths = [
                applicationSupportURL.appendingPathComponent("default.store"),
                applicationSupportURL.appendingPathComponent("Argus.store"),
                applicationSupportURL.appendingPathComponent("ArgusDB.store"),
            ]

            // Extensions to check for each store path
            let extensions = ["", "-wal", "-shm", ".sqlite-wal", ".sqlite-shm", ".sqlite"]

            // Try to remove all store files and variants
            for path in possiblePaths {
                for ext in extensions {
                    let filePath = path.appendingPathExtension(ext)
                    if fileManager.fileExists(atPath: filePath.path) {
                        try fileManager.removeItem(at: filePath)
                        ModernizationLogger.log(.info, component: .migration,
                                                message: "Successfully deleted database file: \(filePath.path)")
                    }
                }
            }
        } catch {
            ModernizationLogger.log(.error, component: .migration,
                                    message: "Error deleting database files: \(error.localizedDescription)")
        }

        // Clear service if it exists
        if migrationService != nil {
            migrationService = await MigrationService(mode: currentMigrationMode)
            migrationService?.resetMigration()
        }

        // Reset progress tracking
        progress = 0
        status = "Reset - migration required"

        // Force migration to be required
        isMigrationRequired = true

        // Save all settings
        saveMigrationSettings()

        // CRITICAL: Ensure database tables are recreated AFTER all files are deleted
        // This is important because we need to make sure the legacy tables exist
        // for the migration process to work properly
        ModernizationLogger.log(.info, component: .migration,
                                message: "Triggering database tables creation after reset")

        Task {
            do {
                // First try to ensure database indexes which will also create tables if needed
                let indexResult = try ArgusApp.ensureDatabaseIndexes()
                ModernizationLogger.log(.info, component: .migration,
                                        message: "Database tables and indexes created: \(indexResult)")

                // Verify the tables were created by checking if they exist
                let tablesExist = await verifyTablesExistAfterReset()
                if tablesExist {
                    ModernizationLogger.log(.info, component: .migration,
                                            message: "Legacy database tables verified after reset")
                } else {
                    ModernizationLogger.log(.error, component: .migration,
                                            message: "Failed to verify legacy tables after reset - migration may fail")
                }
            } catch {
                ModernizationLogger.log(.error, component: .migration,
                                        message: "Error creating database tables/indexes: \(error.localizedDescription)")
            }
        }

        ModernizationLogger.log(.info, component: .migration,
                                message: "Migration completely reset - will run on next attempt")
    }

    /// Helper method to verify tables exist after a reset
    private func verifyTablesExistAfterReset() async -> Bool {
        // Using SQLite directly to check if the tables exist
        guard let dbURL = ArgusApp.sharedModelContainer.configurations.first?.url else {
            return false
        }

        var db: OpaquePointer?
        defer {
            if db != nil {
                sqlite3_close(db)
            }
        }

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return false
        }

        let tableCheckQuery = """
            SELECT count(*) FROM sqlite_master 
            WHERE type='table' AND (name LIKE '%NOTIFICATIONDATA' OR name LIKE '%SEENARTICLE');
        """

        var statement: OpaquePointer?
        var tableCount = 0

        if sqlite3_prepare_v2(db, tableCheckQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                tableCount = Int(sqlite3_column_int(statement, 0))
            }
            sqlite3_finalize(statement)

            return tableCount >= 2
        }

        return false
    }

    /// Mark migration as completed without actually running it
    /// Used when source tables don't exist but we need to mark migration as complete
    func markMigrationCompleted() {
        ModernizationLogger.log(.warning, component: .migration,
                                message: "Manually marking migration as completed without migration")
        // Set as completed
        isOneTimeMigrationCompleted = true
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
