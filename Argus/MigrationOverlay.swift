import SwiftUI

/**
 * MigrationOverlay - Visual component for displaying migration progress
 *
 * This view provides a semi-transparent overlay that displays migration progress, 
 * status, and performance metrics during the migration process. It's designed to
 * be shown on top of other content to indicate migration is in progress.
 *
 * ## Primary Responsibilities
 * - Display migration progress with animations
 * - Show real-time migration status and metrics
 * - Present error messages if migration encounters problems
 * - Auto-dismiss when migration completes
 *
 * ## Dependencies
 * - MigrationService: For migration state, progress and metrics
 *
 * ## Removal Considerations
 * - Should be removed along with other migration UI components
 * - Remove during Phase 2 (UI Component Removal)
 * - No functionality needs to be preserved
 * - Simplest of the UI components to remove as it has no direct references from app bootstrap code
 *
 * @see migration-removal-plan.md for complete removal strategy
 */

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

                // Animated progress indicator with spinner
                ZStack(alignment: .top) {
                    // Progress bar with animation
                    ProgressView(value: migrationService.progress)
                        .frame(width: 250)
                        .animation(.easeInOut(duration: 0.3), value: migrationService.progress)

                    // Spinner animation above progress bar
                    if migrationService.progress < 1.0 {
                        ProgressView() // Indeterminate circular spinner
                            .scaleEffect(0.7)
                            .offset(y: -24)
                    }
                }

                // Status with animation
                Text(migrationService.status)
                    .font(.subheadline)
                    .animation(.easeIn, value: migrationService.status)
                    .multilineTextAlignment(.center)

                // Metrics display - article count during migration
                VStack(spacing: 8) {
                    if migrationService.progress > 0 && migrationService.progress < 1.0 {
                        Text("Articles processed: \(migrationService.totalArticlesMigrated)")
                            .font(.caption)

                        // Only show speed when we have meaningful data
                        if migrationService.articlesPerSecond > 0 {
                            Text("\(Int(migrationService.articlesPerSecond)) articles/sec")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Estimated time remaining
                        if migrationService.estimatedTimeRemaining > 0 {
                            Text("Estimated time: \(timeString(from: migrationService.estimatedTimeRemaining))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 4)

                // Display error if present
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
            .onChange(of: migrationService.progress) { _, newValue in
                // Auto-dismiss when complete
                if newValue >= 1.0 {
                    // Delay dismissal briefly to show completion state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onComplete()
                    }
                }
            }
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
