import OSLog

/// Application-wide logging facility
enum AppLogger {
    // Main application subsystems
    static let sync = Logger(subsystem: "com.arguspulse", category: "SyncManager")
    static let api = Logger(subsystem: "com.arguspulse", category: "APIClient")
    static let notifications = Logger(subsystem: "com.arguspulse", category: "Notifications")
    static let database = Logger(subsystem: "com.arguspulse", category: "Database")
    static let ui = Logger(subsystem: "com.arguspulse", category: "UserInterface")
    static let app = Logger(subsystem: "com.arguspulse", category: "Application")

    // Helper function for debug-only logging
    static func debugOnly(_ message: String, category: Logger = app) {
        #if DEBUG
            category.debug("\(message)")
        #endif
    }
}
