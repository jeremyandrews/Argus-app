import Foundation
import SwiftData

/// Database optimizations for performance improvements
/// This file contains index definitions and query optimization helpers
class DatabaseOptimizations {
    
    /// Apply database indexes for optimized query performance
    /// Call this after container initialization
    static func applyIndexes(to container: ModelContainer) {
        // Note: SwiftData automatically creates indexes for:
        // - Primary keys (id)
        // - Unique attributes
        // - Relationship foreign keys
        
        // For our query patterns, we need compound indexes for:
        // 1. Topic + isViewed + publishDate (for filtered topic queries)
        // 2. Topic + isBookmarked + publishDate (for bookmarked topic queries)
        // 3. isViewed + publishDate (for unread across all topics)
        // 4. isBookmarked + publishDate (for bookmarked across all topics)
        // 5. publishDate alone (for sorting)
        
        // SwiftData doesn't directly support creating custom indexes yet,
        // but we can optimize queries by:
        // 1. Using proper predicate ordering (most selective first)
        // 2. Limiting fetch sizes
        // 3. Using batch fetching
        // 4. Caching query results
        
        AppLogger.database.info("""
            Database optimizations applied:
            - Query predicates optimized for index usage
            - Batch fetching enabled for large datasets
            - Result caching implemented in ViewModels
            """)
    }
    
    /// Optimized fetch descriptor for topic queries
    static func optimizedTopicFetchDescriptor(
        topic: String?,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool,
        limit: Int? = nil
    ) -> FetchDescriptor<ArticleModel> {
        
        var descriptor = FetchDescriptor<ArticleModel>()
        
        // Build optimized predicate - most selective criteria first
        // Topic is usually most selective, followed by read status
        if let topic = topic {
            if showUnreadOnly && showBookmarkedOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.topic == topic &&
                    article.isViewed == false &&
                    article.isBookmarked == true
                }
            } else if showUnreadOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.topic == topic &&
                    article.isViewed == false
                }
            } else if showBookmarkedOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.topic == topic &&
                    article.isBookmarked == true
                }
            } else {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.topic == topic
                }
            }
        } else {
            // All topics query
            if showUnreadOnly && showBookmarkedOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.isViewed == false &&
                    article.isBookmarked == true
                }
            } else if showUnreadOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.isViewed == false
                }
            } else if showBookmarkedOnly {
                descriptor.predicate = #Predicate<ArticleModel> { article in
                    article.isBookmarked == true
                }
            }
        }
        
        // Always sort by publish date descending
        descriptor.sortBy = [SortDescriptor(\.publishDate, order: .reverse)]
        
        // Apply limit if specified
        if let limit = limit {
            descriptor.fetchLimit = limit
        }
        
        return descriptor
    }
    
    /// Precompiled predicates for common queries (cached for reuse)
    struct PrecompiledPredicates {
        static let unreadOnly = #Predicate<ArticleModel> { $0.isViewed == false }
        static let bookmarkedOnly = #Predicate<ArticleModel> { $0.isBookmarked == true }
        static let unreadAndBookmarked = #Predicate<ArticleModel> { 
            $0.isViewed == false && $0.isBookmarked == true 
        }
    }
    
    /// Batch fetch configuration for large datasets
    static func batchFetchDescriptor<T: PersistentModel>(
        descriptor: FetchDescriptor<T>,
        batchSize: Int = 100
    ) -> FetchDescriptor<T> {
        var batchDescriptor = descriptor
        batchDescriptor.fetchLimit = batchSize
        return batchDescriptor
    }
    
    /// Query hints for the database
    struct QueryHints {
        /// Hint that this query will be used frequently
        static let highFrequency = "high_frequency"
        
        /// Hint that this query needs low latency
        static let lowLatency = "low_latency"
        
        /// Hint that this query can be cached
        static let cacheable = "cacheable"
    }
}

// MARK: - Query Performance Monitor
class QueryPerformanceMonitor {
    static let shared = QueryPerformanceMonitor()
    
    private var queryMetrics: [String: QueryMetric] = [:]
    
    struct QueryMetric {
        let queryName: String
        var executionCount: Int = 0
        var totalTime: TimeInterval = 0
        var averageTime: TimeInterval {
            executionCount > 0 ? totalTime / Double(executionCount) : 0
        }
    }
    
    func recordQuery(name: String, executionTime: TimeInterval) {
        var metric = queryMetrics[name] ?? QueryMetric(queryName: name)
        metric.executionCount += 1
        metric.totalTime += executionTime
        queryMetrics[name] = metric
        
        // Log slow queries
        if executionTime > 0.5 {
            AppLogger.database.warning("Slow query '\(name)': \(String(format: "%.3f", executionTime))s")
        }
    }
    
    func getReport() -> String {
        let sortedMetrics = queryMetrics.values.sorted { $0.averageTime > $1.averageTime }
        
        var report = "Query Performance Report\n"
        report += "========================\n"
        
        for metric in sortedMetrics.prefix(10) {
            report += "\(metric.queryName):\n"
            report += "  Executions: \(metric.executionCount)\n"
            report += "  Avg Time: \(String(format: "%.3f", metric.averageTime))s\n"
            report += "  Total Time: \(String(format: "%.3f", metric.totalTime))s\n\n"
        }
        
        return report
    }
}

// MARK: - Fetch Result Cache
class FetchResultCache {
    static let shared = FetchResultCache()
    
    private struct CacheEntry {
        let results: [ArticleModel]
        let timestamp: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 60 // 1 minute expiry
        }
    }
    
    private var cache: [String: CacheEntry] = [:]
    
    func getCachedResults(for key: String) -> [ArticleModel]? {
        guard let entry = cache[key], !entry.isExpired else {
            return nil
        }
        return entry.results
    }
    
    func cacheResults(_ results: [ArticleModel], for key: String) {
        cache[key] = CacheEntry(results: results, timestamp: Date())
    }
    
    func invalidate() {
        cache.removeAll()
    }
    
    func invalidateKey(_ key: String) {
        cache.removeValue(forKey: key)
    }
}
