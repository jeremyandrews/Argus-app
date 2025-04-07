import SwiftData
import SwiftUI

/// View for triggering migration from Settings
struct MigrationView: View {
    @ObservedObject private var coordinator = MigrationCoordinator.shared
    @State private var isMigrating = false
    private let swiftDataContainer = SwiftDataContainer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Migration")
                .font(.headline)

            Text("Migrate your existing articles to the new database format. This process now runs automatically at app startup.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Text("Status: ")
                Text(coordinator.status.isEmpty ? "Not started" : coordinator.status)
                    .foregroundColor(statusColor)
            }

            if coordinator.progress > 0 && coordinator.progress < 1.0 {
                ProgressView(value: coordinator.progress)
            }

            Button(actionText) {
                Task {
                    isMigrating = true
                    // Handle the migration result
                    let success = await coordinator.startMigration()
                    if !success {
                        // If migration failed, stop showing the modal
                        isMigrating = false
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.progress > 0 && coordinator.progress < 1.0 && !coordinator.isMigrationActive)

            // Add reset button for manual testing
            if coordinator.progress >= 1.0 {
                Button("Reset Migration State (For Testing)") {
                    Task {
                        let service = await MigrationService(mode: .temporary)
                        service.resetMigration()

                        // Refresh coordinator status
                        _ = await coordinator.checkMigrationStatus()
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.orange)
                .padding(.top, 8)
            }

            // Manual test button
            Button("Run Migration Manually") {
                Task {
                    isMigrating = true
                    // Handle the migration result
                    let success = await coordinator.startMigration()
                    if !success {
                        // If migration failed, stop showing the modal
                        isMigrating = false
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            .foregroundColor(.blue)

            // Information message
            Text("Note: Migration now runs automatically at app startup. This view is for manual testing and troubleshooting only.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .fullScreenCover(isPresented: $isMigrating) {
            MigrationModalView(coordinator: coordinator)
                .background(.ultraThinMaterial)
                .onDisappear {
                    isMigrating = false
                }
        }
        .onAppear {
            // Check migration status when view appears
            Task {
                _ = await coordinator.checkMigrationStatus()
            }
        }
    }

    private var actionText: String {
        if coordinator.progress >= 1.0 {
            return "Migration Complete"
        } else if coordinator.progress > 0 {
            return "Continue Migration"
        } else {
            return "Start Migration"
        }
    }

    private var statusColor: Color {
        if coordinator.progress >= 1.0 {
            return .green
        } else if coordinator.isMigrationActive {
            return .blue
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
