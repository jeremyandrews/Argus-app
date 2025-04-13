import SwiftUI

/// A view that displays the current sync status in the navigation bar
/// following standard iOS patterns
struct SyncStatusIndicator: View {
    /// The current sync status
    @Binding var status: SyncStatus
    
    var body: some View {
        HStack(spacing: 6) {
            // Standard iOS activity indicator
            if status.isActive {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
            } else if status.shouldDisplay {
                // For completed or error states, show appropriate icon
                Image(systemName: status.systemImage)
                    .foregroundColor(colorForStatus)
            }
            
            // Only show text if there's a message to display
            if status.shouldDisplay {
                Text(status.message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            
            // For downloading state, show the count
            if case .downloading(let current, let total) = status {
                Text("\(current)/\(total)")
                    .font(.footnote.monospacedDigit())
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
