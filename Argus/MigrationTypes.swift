import Foundation
import SwiftUI

/**
 * MigrationTypes - Core data structures for the migration system
 *
 * This file contains the shared data structures used throughout the migration system.
 * These types facilitate state tracking, progress reporting, and error handling during
 * the one-time migration process from legacy storage to SwiftData.
 *
 * ## Primary Components
 * - MigrationState: Enum tracking various migration phases
 * - MigrationProgress: Structure for storing detailed migration progress
 * - MigrationError: Migration-specific error types
 * - MigrationMetrics: Performance tracking for migration operations
 *
 * ## Dependencies
 * - None (this file is imported by other migration components)
 *
 * ## Removal Considerations
 * - Should be removed after all components that reference it are removed
 * - No types have leaked into public interfaces outside the migration system
 * - Can be safely removed as part of Phase 4 (Final Cleanup)
 *
 * @see migration-removal-plan.md for complete removal strategy
 */

/// Tracks the state of the data migration process
enum MigrationState: String, Codable {
    case notStarted
    case inProgress
    case completed
    case failed
}

/// Stores migration progress for resilience against app termination
struct MigrationProgress: Codable {
    var state: MigrationState = .notStarted
    var progressPercentage: Double = 0
    var lastBatchIndex: Int = 0
    var lastProcessedArticleId: UUID? = nil
    var migratedArticleIds: [UUID] = []
    var migratedTopics: [String] = []
    var lastUpdated: Date = .init()
    var migrationInterrupted: Bool = false
}

/// Migration-specific errors
enum MigrationError: Error, LocalizedError, Equatable {
    case cancelled
    case dataError(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Migration was cancelled"
        case let .dataError(message):
            return "Data error: \(message)"
        }
    }

    static func == (lhs: MigrationError, rhs: MigrationError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled):
            return true
        case let (.dataError(lhsMsg), .dataError(rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Metrics for tracking migration performance
struct MigrationMetrics {
    var operationCount: Int = 0
    var totalDuration: TimeInterval = 0
    var minDuration: TimeInterval = .infinity
    var maxDuration: TimeInterval = 0

    mutating func recordOperation(duration: TimeInterval) {
        operationCount += 1
        totalDuration += duration
        minDuration = min(minDuration, duration)
        maxDuration = max(maxDuration, duration)
    }

    var averageDuration: TimeInterval {
        guard operationCount > 0 else { return 0 }
        return totalDuration / Double(operationCount)
    }

    func formattedSummary() -> String {
        if operationCount == 0 {
            return "No operations performed"
        }

        return """
        Operations: \(operationCount)
        Average: \(String(format: "%.2f", averageDuration * 1000))ms
        Min: \(String(format: "%.2f", minDuration * 1000))ms
        Max: \(String(format: "%.2f", maxDuration * 1000))ms
        """
    }
}
