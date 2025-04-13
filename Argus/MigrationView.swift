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

            Text("One-time migration from legacy to modern database. This process runs automatically on first app startup with the new version.")
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
            .disabled((coordinator.progress > 0 && coordinator.progress < 1.0 && !coordinator.isMigrationActive) || coordinator.isMigrationCompleted)

            // Manual test button (only shown if migration not completed)
            if !coordinator.isMigrationCompleted {
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

                // Info about one-time migration
                Text("Migration runs only once per device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

            // Migration completion status (shown if completed)
            if coordinator.isMigrationCompleted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Migration completed. Using new database exclusively.")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
                .padding(.top, 4)
            }

            // Information message
            Text("Note: This is a one-time migration to the modern database. After migration completes, the legacy database will no longer be used.")
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
