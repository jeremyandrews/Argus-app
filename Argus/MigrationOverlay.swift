import SwiftUI

/// Migration overlay view for visual progress
struct MigrationOverlay: View {
    @ObservedObject var migrationService: MigrationService
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                Text("Migrating Data")
                    .font(.headline)

                ProgressView(value: migrationService.progress)
                    .frame(width: 250)

                Text(migrationService.status)
                    .font(.subheadline)

                // Display migrated article count during migration
                if migrationService.progress > 0 && migrationService.progress < 1.0 {
                    Text("Articles processed: \(migrationService.totalArticlesMigrated)")
                        .font(.caption)
                        .padding(.top, 4)
                }

                if migrationService.progress >= 1.0 {
                    Button("Done") {
                        onComplete()
                    }
                    .buttonStyle(.bordered)
                } else if migrationService.progress < 0.95 {
                    // Cancel button
                    Button("Cancel", role: .destructive) {
                        Task {
                            migrationService.cancelMigration()
                            // Allow time for cancellation to process
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            onComplete()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.top, 4)
                }

                if let error = migrationService.error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 8)
                }
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color(.systemBackground).opacity(0.95))
            )
            .shadow(color: Color.primary.opacity(0.2), radius: 10)
        }
    }

    // Helper methods for formatting metrics
    private func timeString(from timeInterval: TimeInterval) -> String {
        if timeInterval.isNaN || timeInterval.isInfinite || timeInterval <= 0 {
            return "Calculating..."
        }

        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) % 3600 / 60
        let seconds = Int(timeInterval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func memoryString(bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", megabytes)
    }
}
