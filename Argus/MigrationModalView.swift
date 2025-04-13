import SwiftUI

/**
 * MigrationModalView - Full-screen modal UI for displaying migration progress
 *
 * This view provides a blocking modal interface that prevents user interaction
 * during the migration process. It displays progress, status, and appropriate
 * animations to indicate that migration is in progress.
 *
 * ## Primary Responsibilities
 * - Display migration progress visually with animations
 * - Block all user interaction during migration
 * - Show status messages from the migration coordinator
 * - Auto-dismiss when migration is complete
 *
 * ## Dependencies
 * - MigrationCoordinator: For migration state and progress
 *
 * ## Removal Considerations
 * - Should be removed along with other migration UI components
 * - Remove during Phase 2 (UI Component Removal) after MigrationView
 * - No functionality needs to be preserved
 *
 * @see migration-removal-plan.md for complete removal strategy
 */

/// Standard iOS modal view for migration progress display
struct MigrationModalView: View {
    @ObservedObject var coordinator: MigrationCoordinator

    var body: some View {
        ZStack {
            // Full opacity background to completely block interaction
            Color(.systemBackground)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                // Animated icon
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                    .rotationEffect(.degrees(coordinator.progress < 1.0 ? 360 : 0))
                    .animation(
                        coordinator.progress < 1.0 ?
                            Animation.linear(duration: 2.0).repeatForever(autoreverses: false) :
                            Animation.default,
                        value: coordinator.progress
                    )

                Text("Database Migration")
                    .font(.headline)

                // Progress indicator with animation
                ZStack {
                    // Progress bar with animation
                    ProgressView(value: coordinator.progress)
                        .frame(width: 250)
                        .padding(.vertical)
                        .animation(.easeInOut(duration: 0.3), value: coordinator.progress)

                    // Pulse animation on progress track
                    if coordinator.progress < 1.0 {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 250, height: 4)
                            .scaleEffect(x: 0.3, y: 1, anchor: .leading)
                            .offset(y: 10)
                            .opacity(0.7)
                            .animation(
                                Animation.easeInOut(duration: 1.0)
                                    .repeatForever(autoreverses: true),
                                value: coordinator.progress
                            )
                    }
                }

                // Status text with animation
                Text(coordinator.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.horizontal)
                    .transition(.opacity)
                    .animation(.easeIn, value: coordinator.status)

                // Help text with automatic dismissal logic
                Text(coordinator.progress >= 1.0 ?
                    "This is the update you've been waiting for... doing stuff..." :
                    "Please wait while your data is being prepared")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
            )
            .shadow(radius: 10)
            .onChange(of: coordinator.progress) { _, newValue in
                // Auto-dismiss when complete
                if newValue >= 1.0 {
                    // Delay dismissal briefly to show completion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        coordinator.completeMigration()
                    }
                }
            }
        }
        // Critical: Prevent dismissal by any means
        .interactiveDismissDisabled(true)
    }
}

/// Full-screen modal view that completely blocks interaction
struct FullScreenBlockingView<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Blocking color that takes up the entire screen
            Color(.systemBackground)
                .edgesIgnoringSafeArea(.all)

            // Content centered in the view
            content
        }
        // Prevent any kind of dismissal
        .interactiveDismissDisabled(true)
        // Capture all touch events to prevent them from passing through
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
}

#if DEBUG
    struct MigrationModalView_Previews: PreviewProvider {
        static var previews: some View {
            // Mock coordinator for preview
            let coordinator = MigrationCoordinator.shared

            // Group multiple previews together
            Group {
                MigrationModalView(coordinator: coordinator)
                    .preferredColorScheme(.light)
                    .previewDisplayName("Light Mode")

                MigrationModalView(coordinator: coordinator)
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Dark Mode")
            }
        }
    }
#endif
