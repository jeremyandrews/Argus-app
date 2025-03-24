import Foundation
import SwiftData

// MARK: - Array Extensions for NotificationData

extension Array where Element == NotificationData {
    /// Returns a new array containing only unique NotificationData objects by their ID
    /// This prevents duplicate articles from appearing in the UI
    func uniqued() -> [NotificationData] {
        var seen = Set<UUID>()
        var result = [NotificationData]()
        result.reserveCapacity(underestimatedCount)

        for notification in self {
            if seen.insert(notification.id).inserted {
                result.append(notification)
            } else {
                #if DEBUG
                    print("🚨 Found duplicate NotificationData with ID: \(notification.id)")
                #endif
            }
        }

        return result
    }
}

// MARK: - General Collection Extensions

extension Collection {
    /// Returns a nil if the collection is empty, otherwise returns self as optional.
    /// Useful for chaining operations that should not be performed on empty collections.
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }

    /// Returns a new array containing the first occurrence of each unique key,
    /// in the order they appear in self.
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        var result = [Element]()
        result.reserveCapacity(underestimatedCount)

        for element in self {
            let key = element[keyPath: keyPath]
            if seen.insert(key).inserted {
                result.append(element)
            }
        }

        return result
    }
}

// Note: The effectiveDate property is defined in MarkdownUtilities.swift
