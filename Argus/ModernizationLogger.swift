import Foundation
import os.log

/// A specialized logging system for the modernization transition period.
/// Provides component-specific tracking, performance metrics, and comprehensive diagnostics.
class ModernizationLogger {
    /// Logging components for categorization
    enum Component: String, CaseIterable {
        case sync = "Sync" // Renamed from syncManager
        case cloudKit = "CloudKit"
        case apiClient = "APIClient"
        case databaseCoordinator = "DatabaseCoordinator"
        case modernization = "Modernization"
        case articleService = "ArticleService"
        case viewModel = "ViewModel"
        case backgroundTask = "BackgroundTask"
    }

    /// Log severity levels
    enum LogLevel: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case critical = 4

        var emoji: String {
            switch self {
            case .debug: return "🔍"
            case .info: return "ℹ️"
            case .warning: return "⚠️"
            case .error: return "❌"
            case .critical: return "🚨"
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            case .critical: return .fault
            }
        }

        static func < (lhs: ModernizationLogger.LogLevel, rhs: ModernizationLogger.LogLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Properties

    /// Current minimum log level to display
    static var minimumLogLevel: LogLevel = .debug

    /// Enable or disable file logging
    static var enableFileLogging = true

    /// Log file URL
    static let logFileURL: URL = {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDirectory.appendingPathComponent("modernization_log.txt")
    }()

    /// OSLog subsystem
    private static let subsystem = "com.andrews.Argus"

    /// OSLog objects for each component
    private static let osLoggers: [Component: OSLog] = {
        var loggers = [Component: OSLog]()
        for component in Component.allCases {
            loggers[component] = OSLog(subsystem: subsystem, category: component.rawValue)
        }
        return loggers
    }()

    // MARK: - Logging Methods

    /// Main logging method
    /// - Parameters:
    ///   - level: The severity level
    ///   - component: The component generating the log
    ///   - message: The message to log
    ///   - file: Source file (auto-filled)
    ///   - function: Function name (auto-filled)
    ///   - line: Line number (auto-filled)
    static func log(_ level: LogLevel,
                    component: Component,
                    message: String,
                    file: String = #file,
                    function: String = #function,
                    line: Int = #line)
    {
        // Skip if below minimum level
        if level < minimumLogLevel {
            return
        }

        let filename = URL(fileURLWithPath: file).lastPathComponent
        let location = "\(filename):\(line) \(function)"

        // Log to console with emoji
        let fullMessage = "\(level.emoji) [\(component.rawValue)] \(message) [\(location)]"
        print(fullMessage)

        // Log to OS Logger
        if let logger = osLoggers[component] {
            os_log("%{public}@", log: logger, type: level.osLogType, message)
        }

        // Log to file if enabled
        if enableFileLogging {
            appendToLogFile(level: level, component: component, message: message, location: location)
        }
    }

    /// Append a log entry to the log file
    /// - Parameters:
    ///   - level: Log severity level
    ///   - component: Component generating the log
    ///   - message: Message content
    ///   - location: Source location (file:line)
    private static func appendToLogFile(level: LogLevel, component: Component, message: String, location: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(level)] [\(component.rawValue)] \(message) [\(location)]\n"

        do {
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try "Modernization Log\n".write(to: logFileURL, atomically: true, encoding: .utf8)
            }

            // Append to file
            let fileHandle = try FileHandle(forWritingTo: logFileURL)
            fileHandle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } catch {
            print("Error writing to log file: \(error.localizedDescription)")
        }
    }

    // MARK: - Specialized Logging Methods

    /// Log a deprecated method call
    /// - Parameters:
    ///   - method: The method name
    ///   - component: The component containing the method
    ///   - file: Source file
    ///   - line: Line number
    static func logDeprecatedMethodCall(_ method: String,
                                        component: Component,
                                        file: String = #file,
                                        line: Int = #line)
    {
        log(.warning, component: component, message: "DEPRECATED: '\(method)' called", file: file, line: line)
    }

    /// Log a performance metric
    /// - Parameters:
    ///   - operation: The operation being measured
    ///   - component: The component performing the operation
    ///   - duration: Time taken in seconds
    ///   - context: Additional context information
    ///   - file: Source file
    ///   - line: Line number
    static func logPerformanceMetric(operation: String,
                                     component: Component,
                                     duration: TimeInterval,
                                     context: String = "",
                                     file: String = #file,
                                     line: Int = #line)
    {
        let contextInfo = context.isEmpty ? "" : " (\(context))"
        log(.info, component: component,
            message: "PERFORMANCE: '\(operation)' completed in \(String(format: "%.4f", duration))s\(contextInfo)",
            file: file, line: line)
    }

    /// Log a fallback event when one method is used as a replacement for another
    /// - Parameters:
    ///   - from: Original method or component
    ///   - to: Fallback method or component
    ///   - reason: Why the fallback was necessary
    ///   - component: The component where fallback occurred
    ///   - file: Source file
    ///   - line: Line number
    static func logFallback(from: String,
                            to: String,
                            reason: String,
                            component: Component,
                            file: String = #file,
                            line: Int = #line)
    {
        log(.warning, component: component,
            message: "FALLBACK: '\(from)' → '\(to)' because: \(reason)",
            file: file, line: line)
    }

    /// Log a state inconsistency
    /// - Parameters:
    ///   - detail: Description of the inconsistency
    ///   - component: The component with the inconsistency
    ///   - file: Source file
    ///   - line: Line number
    static func logStateInconsistency(_ detail: String,
                                      component: Component,
                                      file: String = #file,
                                      line: Int = #line)
    {
        log(.error, component: component,
            message: "STATE INCONSISTENCY: \(detail)",
            file: file, line: line)
    }

    /// Log the start of a transition operation
    /// - Parameters:
    ///   - operation: The operation name
    ///   - component: The component initiating the operation
    ///   - file: Source file
    ///   - line: Line number
    static func logTransitionStart(_ operation: String,
                                   component: Component,
                                   file: String = #file,
                                   line: Int = #line)
    {
        log(.info, component: component,
            message: "TRANSITION START: '\(operation)'",
            file: file, line: line)
    }

    /// Log the completion of a transition operation
    /// - Parameters:
    ///   - operation: The operation name
    ///   - component: The component that completed the operation
    ///   - success: Whether the operation was successful
    ///   - detail: Additional details
    ///   - file: Source file
    ///   - line: Line number
    static func logTransitionCompletion(_ operation: String,
                                        component: Component,
                                        success: Bool,
                                        detail: String = "",
                                        file: String = #file,
                                        line: Int = #line)
    {
        let status = success ? "succeeded" : "failed"
        let detailInfo = detail.isEmpty ? "" : ": \(detail)"
        log(success ? .info : .error, component: component,
            message: "TRANSITION COMPLETE: '\(operation)' \(status)\(detailInfo)",
            file: file, line: line)
    }

    /// Log an API error
    /// - Parameters:
    ///   - endpoint: The API endpoint
    ///   - method: The HTTP method used
    ///   - statusCode: The HTTP status code
    ///   - error: The error message
    ///   - file: Source file
    ///   - line: Line number
    static func logAPIError(endpoint: String,
                            method: String,
                            statusCode: Int,
                            error: String,
                            file: String = #file,
                            line: Int = #line)
    {
        log(.error, component: .apiClient,
            message: "API ERROR: \(method) \(endpoint) returned \(statusCode) - \(error)",
            file: file, line: line)
    }

    /// Log CloudKit error
    /// - Parameters:
    ///   - operation: The CloudKit operation
    ///   - error: The error object
    ///   - detail: Additional details
    ///   - file: Source file
    ///   - line: Line number
    static func logCloudKitError(operation: String,
                                 error: Error,
                                 detail: String = "",
                                 file: String = #file,
                                 line: Int = #line)
    {
        let detailInfo = detail.isEmpty ? "" : " - \(detail)"
        log(.error, component: .cloudKit,
            message: "CLOUDKIT ERROR: '\(operation)' failed with \(error.localizedDescription)\(detailInfo)",
            file: file, line: line)
    }

    // MARK: - Performance Measurement Methods

    /// Measure the execution time of a synchronous operation
    /// - Parameters:
    ///   - operation: The operation name
    ///   - component: The component performing the operation
    ///   - context: Additional context information
    ///   - file: Source file
    ///   - line: Line number
    ///   - block: The operation to measure
    /// - Returns: The result of the operation
    static func measurePerformance<T>(operation: String,
                                      component: Component,
                                      context: String = "",
                                      file: String = #file,
                                      line: Int = #line,
                                      block: () throws -> T) rethrows -> T
    {
        let startTime = Date()
        let result = try block()
        let duration = Date().timeIntervalSince(startTime)

        logPerformanceMetric(operation: operation,
                             component: component,
                             duration: duration,
                             context: context,
                             file: file,
                             line: line)
        return result
    }

    /// Measure the execution time of an asynchronous operation
    /// - Parameters:
    ///   - operation: The operation name
    ///   - component: The component performing the operation
    ///   - context: Additional context information
    ///   - file: Source file
    ///   - line: Line number
    ///   - block: The async operation to measure
    /// - Returns: The result of the operation
    static func measureAsyncPerformance<T>(operation: String,
                                           component: Component,
                                           context: String = "",
                                           file: String = #file,
                                           line: Int = #line,
                                           block: () async throws -> T) async rethrows -> T
    {
        let startTime = Date()
        let result = try await block()
        let duration = Date().timeIntervalSince(startTime)

        logPerformanceMetric(operation: operation,
                             component: component,
                             duration: duration,
                             context: context,
                             file: file,
                             line: line)
        return result
    }

    // MARK: - Utility Methods

    /// Retrieve the contents of the log file
    /// - Returns: Log file contents as a string
    static func getLogFileContents() -> String? {
        do {
            return try String(contentsOf: logFileURL, encoding: .utf8)
        } catch {
            print("Error reading log file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear the log file
    static func clearLogFile() {
        do {
            try "Modernization Log\n".write(to: logFileURL, atomically: true, encoding: .utf8)
            log(.info, component: .modernization, message: "Log file cleared")
        } catch {
            print("Error clearing log file: \(error.localizedDescription)")
        }
    }

    /// Export log file to a chosen location with timestamp
    /// - Returns: URL of the exported file
    @discardableResult
    static func exportLogFile() -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let exportDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportURL = exportDirectory.appendingPathComponent("argus_log_\(timestamp).txt")

        do {
            if let contents = getLogFileContents() {
                try contents.write(to: exportURL, atomically: true, encoding: .utf8)
                log(.info, component: .modernization, message: "Log exported to \(exportURL.path)")
                return exportURL
            }
        } catch {
            print("Error exporting log file: \(error.localizedDescription)")
        }

        return nil
    }
}
