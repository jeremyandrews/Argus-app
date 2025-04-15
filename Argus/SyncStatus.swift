import Foundation

/// Represents the different states of the sync operation for UI display
enum SyncStatus: Equatable {
    /// No sync operation is currently in progress
    case idle
    
    /// Actively searching for new articles from the server
    case searching
    
    /// Downloading articles with progress information
    case downloading(current: Int, total: Int)
    
    /// Sync operation completed successfully
    case complete
    
    /// Sync operation failed with an error
    case error(String)
    
    /// Returns a descriptive message based on the current state
    var message: String {
        switch self {
        case .idle:
            return ""
        case .searching:
            return "Checking for new articles..."
        case .downloading(let current, let total):
            // Format matches standard iOS progress indicators
            // Example: "Downloading articles... (4 of 10)"
            return "Downloading articles... (\(current) of \(total))"
        case .complete:
            return "Articles updated"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    /// Returns a system image name based on the current state
    var systemImage: String {
        switch self {
        case .idle:
            return ""
        case .searching:
            return "magnifyingglass"
        case .downloading:
            return "arrow.down.circle"
        case .complete:
            return "checkmark.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
    
    /// Returns whether the status should be displayed
    var shouldDisplay: Bool {
        switch self {
        case .idle:
            return false
        default:
            return true
        }
    }
    
    /// Returns true if the status represents an active operation
    var isActive: Bool {
        switch self {
        case .searching, .downloading:
            return true
        default:
            return false
        }
    }
}
