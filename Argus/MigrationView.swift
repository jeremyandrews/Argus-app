import SwiftUI

/// View for triggering migration from Settings
struct MigrationView: View {
    @State private var migrationService: MigrationService?
    @State private var isMigrating = false
    // Removed test mode state as we're now using persistent storage by default
    private let swiftDataContainer = SwiftDataContainer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Migration")
                .font(.headline)

            Text("Migrate your existing articles to the new database format. This is a one-time process.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Warning if using in-memory storage (unlikely since we now default to persistent)
            if swiftDataContainer.isUsingInMemoryFallback {
                Text("⚠️ Using in-memory storage. Migration will work but data will NOT be saved permanently!")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.vertical, 8)
            }

            if let service = migrationService {
                HStack {
                    Text("Status: ")
                    Text(service.status)
                        .foregroundColor(statusColor(for: service))
                }

                if service.progress > 0 && service.progress < 1.0 {
                    ProgressView(value: service.progress)
                }
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }

            Button(actionText) {
                if migrationService == nil {
                    // Initialize the service on first button press
                    Task {
                        migrationService = await MigrationService()

                        // No test mode to set as we're now using persistent storage by default
                    }
                }

                isMigrating = true

                if let service = migrationService {
                    Task {
                        await service.migrateAllData()
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(migrationService?.progress ?? 0 > 0 && migrationService?.progress ?? 0 < 1.0)

            // Add reset button when migration is completed or failed
            if let service = migrationService, service.progress >= 1.0 || service.error != nil {
                Button("Reset Migration State") {
                    service.resetMigration()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.orange)
                .padding(.top, 8)
            }

            if let service = migrationService, let error = service.error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 8)
            }
        }
        .padding()
        .fullScreenCover(isPresented: $isMigrating) {
            if let service = migrationService {
                MigrationOverlay(migrationService: service) {
                    isMigrating = false
                }
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            // Initialize the service when the view appears
            Task {
                let service = await MigrationService()
                self.migrationService = service

                if service.checkAndResumeIfNeeded() {
                    isMigrating = true

                    Task {
                        await service.migrateAllData()
                    }
                }
            }
        }
    }

    private var actionText: String {
        guard let service = migrationService else {
            return "Start Migration"
        }

        if service.progress >= 1.0 {
            return "Migration Complete"
        } else if service.progress > 0 {
            return "Continue Migration"
        } else {
            return "Start Migration"
        }
    }

    private func statusColor(for service: MigrationService) -> Color {
        if service.error != nil {
            return .red
        } else if service.progress >= 1.0 {
            return .green
        } else {
            return .primary
        }
    }
}

#Preview {
    NavigationView {
        MigrationView()
    }
}
