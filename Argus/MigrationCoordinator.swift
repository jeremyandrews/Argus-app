import Combine
import Foundation
import SwiftUI

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

    // Internal state and service
    private var migrationService: MigrationService?
    private var cancelBag: Set<AnyCancellable> = []

    // Private init for singleton pattern
    private init() {}

    /// Public method to check if migration is needed
    func checkMigrationStatus() async -> Bool {
        // Lazy initialization of migration service
        if migrationService == nil {
            migrationService = await MigrationService(mode: .temporary)
        }

        // Setup bindings if not already done
        setupBindings()

        // Check if migration is needed
        guard let service = migrationService else {
            return false
        }

        isMigrationRequired = service.migrationMode == .temporary ||
            service.wasMigrationInterrupted() ||
            service.migrationProgress.state == .inProgress

        return isMigrationRequired
    }

    /// Public method to start migration
    func startMigration() async -> Bool {
        guard let service = migrationService, isMigrationRequired else {
            return false
        }

        // Flag as active
        isMigrationActive = true

        // Run migration with high priority
        let result = await Task.detached(priority: .userInitiated) {
            await service.migrateAllData()
        }.value

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
            service.migrationProgress.migrationInterrupted = true
            // Save the progress to UserDefaults immediately
            service.saveMigrationProgress()
        }
    }
}
