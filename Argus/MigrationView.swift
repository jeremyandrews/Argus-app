import SwiftUI

/// View for triggering migration from Settings
struct MigrationView: View {
    @State private var migrationService: MigrationService?
    @State private var isMigrating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Migration")
                .font(.headline)

            Text("Migrate your existing articles to the new database format. This is a one-time process.")
                .font(.subheadline)
                .foregroundColor(.secondary)

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
