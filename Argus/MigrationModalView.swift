import SwiftUI

/// Standard iOS modal view for migration progress display
struct MigrationModalView: View {
    @ObservedObject var coordinator: MigrationCoordinator
    
    var body: some View {
        ZStack {
            // Full opacity background to completely block interaction
            Color(.systemBackground)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                // Title and icon
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                
                Text("Database Migration")
                    .font(.headline)
                
                // Progress bar
                ProgressView(value: coordinator.progress)
                    .frame(width: 250)
                    .padding(.vertical)
                
                // Status text
                Text(coordinator.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.horizontal)
                
                // Only show done button when completed
                if coordinator.progress >= 1.0 {
                    Button("Continue") {
                        coordinator.completeMigration()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                
                // Help text
                Text("Please wait while your data is being prepared")
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
