import Combine
import Foundation

// MARK: - UserDefaults Keys

// Define static keys to avoid stringly-typed programming
extension UserDefaults {
    enum Keys {
        static let sortOrder = "sortOrder"
        static let groupingStyle = "groupingStyle"
        static let showUnreadOnly = "showUnreadOnly"
        static let showBookmarkedOnly = "showBookmarkedOnly"
        static let showBadge = "showBadge"
        static let selectedTopic = "selectedTopic"
        static let useReaderMode = "useReaderMode"
        static let allowCellularSync = "allowCellularSync"
        static let autoDeleteDays = "autoDeleteDays"
    }
}

// MARK: - UserDefaults Computed Properties

extension UserDefaults {
    @objc var sortOrder: String {
        get { string(forKey: Keys.sortOrder) ?? "newest" }
        set { set(newValue, forKey: Keys.sortOrder) }
    }

    @objc var groupingStyle: String {
        get { string(forKey: Keys.groupingStyle) ?? "date" } // Standardized default to "date"
        set { set(newValue, forKey: Keys.groupingStyle) }
    }

    @objc var showUnreadOnly: Bool {
        get { bool(forKey: Keys.showUnreadOnly) }
        set { set(newValue, forKey: Keys.showUnreadOnly) }
    }

    @objc var showBookmarkedOnly: Bool {
        get { bool(forKey: Keys.showBookmarkedOnly) }
        set { set(newValue, forKey: Keys.showBookmarkedOnly) }
    }

    @objc var showBadge: Bool {
        get { bool(forKey: Keys.showBadge) }
        set { set(newValue, forKey: Keys.showBadge) }
    }

    @objc var selectedTopic: String {
        get { string(forKey: Keys.selectedTopic) ?? "All" }
        set { set(newValue, forKey: Keys.selectedTopic) }
    }

    @objc var useReaderMode: Bool {
        get { bool(forKey: Keys.useReaderMode) }
        set { set(newValue, forKey: Keys.useReaderMode) }
    }

    @objc var allowCellularSync: Bool {
        get { bool(forKey: Keys.allowCellularSync) }
        set { set(newValue, forKey: Keys.allowCellularSync) }
    }

    @objc var autoDeleteDays: Int {
        get { object(forKey: Keys.autoDeleteDays) == nil ? 3 : integer(forKey: Keys.autoDeleteDays) }
        set { set(newValue, forKey: Keys.autoDeleteDays) }
    }
}

// MARK: - Publisher for UserDefaults

extension UserDefaults {
    /// Creates a publisher that emits when the specified key's value changes
    func publisher<T>(for keyPath: KeyPath<UserDefaults, T>) -> AnyPublisher<T, Never> {
        return NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { [weak self] _ in
                self?[keyPath: keyPath]
            }
            .removeDuplicates(by: { first, second in
                // Custom equality check using string representation
                // This avoids the need for T to conform to Equatable
                String(describing: first) == String(describing: second)
            })
            .eraseToAnyPublisher()
    }
}
