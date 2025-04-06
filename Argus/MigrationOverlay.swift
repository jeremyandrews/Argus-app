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

                if migrationService.progress >= 1.0 {
                    Button("Done") {
                        onComplete()
                    }
                    .buttonStyle(.bordered)
                } else if migrationService.progress < 0.95 {
                    Button("Cancel", role: .destructive) {
                        migrationService.cancelMigration()
                    }
                    .buttonStyle(.bordered)
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
                    .fill(Color.white.opacity(0.95))
            )
            .shadow(radius: 10)
        }
    }
}
