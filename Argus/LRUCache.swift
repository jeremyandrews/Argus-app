import Foundation

/// A Least Recently Used (LRU) cache implementation
/// Automatically evicts least recently used items when capacity is reached
final class LRUCache<Key: Hashable, Value> {
    private var cache: [Key: Value] = [:]
    private var accessOrder: [Key] = []
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.argus.lrucache", attributes: .concurrent)
    
    init(capacity: Int) {
        self.capacity = max(1, capacity) // Ensure at least 1 item capacity
    }
    
    /// Gets a value from the cache and updates its access order
    func get(_ key: Key) -> Value? {
        queue.sync {
            guard let value = cache[key] else {
                return nil
            }
            
            // Move to front (most recently used)
            accessOrder.removeAll { $0 == key }
            accessOrder.insert(key, at: 0)
            
            return value
        }
    }
    
    /// Sets a value in the cache and manages eviction
    func set(_ key: Key, _ value: Value) {
        queue.async(flags: .barrier) {
            // Remove existing entry if present
            if self.cache[key] != nil {
                self.accessOrder.removeAll { $0 == key }
            }
            
            // Add new entry
            self.cache[key] = value
            self.accessOrder.insert(key, at: 0)
            
            // Evict LRU if over capacity
            while self.accessOrder.count > self.capacity {
                if let lruKey = self.accessOrder.popLast() {
                    self.cache.removeValue(forKey: lruKey)
                }
            }
        }
    }
    
    /// Removes a specific key from the cache
    func removeValue(forKey key: Key) {
        queue.async(flags: .barrier) {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
        }
    }
    
    /// Clears all cached items
    func clear() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
            self.accessOrder.removeAll()
        }
    }
    
    /// Returns the current number of cached items
    var count: Int {
        queue.sync { cache.count }
    }
}
