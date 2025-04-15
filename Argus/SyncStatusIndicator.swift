import SwiftUI

/// A view that displays the current sync status in the navigation bar
/// following standard iOS patterns
struct SyncStatusIndicator: View {
    /// The current sync status
    @Binding var status: SyncStatus
    
    var body: some View {
        HStack(spacing: 8) {
            // Standard iOS pattern: status icon or activity indicator first
            if status.isActive {
                // Use circular progress indicator (standard iOS pattern)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
            } else if status.shouldDisplay {
                // For completed or error states, show appropriate icon
                Image(systemName: status.systemImage)
                    .foregroundColor(colorForStatus)
            }
            
            // Status text follows the indicator (standard iOS pattern)
            if status.shouldDisplay {
                // In iOS native apps, status message is clear and includes count
                // We're following the pattern from Files, Mail, and other Apple apps
                Text(status.message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.3), value: status)
    }
    
    /// Returns the appropriate color for the current status
    private var colorForStatus: Color {
        switch status {
        case .complete:
            return .green
        case .error:
            return .red
        default:
            return .primary
        }
    }
}

// Use separate preview macros for each state with the proper naming format
#Preview("Idle State") {
    SyncStatusIndicator(status: .constant(.idle))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Searching State") {
    SyncStatusIndicator(status: .constant(.searching))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Downloading State") {
    SyncStatusIndicator(status: .constant(.downloading(current: 4, total: 10)))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Complete State") {
    SyncStatusIndicator(status: .constant(.complete))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Error State") {
    SyncStatusIndicator(status: .constant(.error("Network connection failed")))
        .padding()
        .background(Color(.systemGroupedBackground))
}

// Combined preview with all states
#Preview("All States") {
    VStack(spacing: 20) {
        SyncStatusIndicator(status: .constant(.idle))
        SyncStatusIndicator(status: .constant(.searching))
        SyncStatusIndicator(status: .constant(.downloading(current: 4, total: 10)))
        SyncStatusIndicator(status: .constant(.complete))
        SyncStatusIndicator(status: .constant(.error("Network connection failed")))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
