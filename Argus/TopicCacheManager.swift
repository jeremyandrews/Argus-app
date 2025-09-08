import Foundation
import SwiftData
import SwiftUI

/// Manages ultra-lightweight topic discovery for optimal performance
/// Only fetches topic names - counts are computed on-demand when needed
@MainActor
final class TopicCacheManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Cached list of available topic names (no counts for performance)
    @Published var availableTopics: [String] = []
    
    /// Flag indicating if topic cache is currently being updated
    @Published var isUpdatingTopics = false
    
    // MARK: - Cache Management
    
    /// Timestamp of last cache update
    private var lastCacheUpdate = Date.distantPast
    
    /// Cache validity duration (5 minutes)
    private let cacheValidityDuration: TimeInterval = 300
    
    /// Flag indicating if cache is currently valid
    private var isCacheValid: Bool {
        Date().timeIntervalSince(lastCacheUpdate) < cacheValidityDuration
    }
    
    /// Background task for cache updates
    private var cacheUpdateTask: Task<Void, Never>?
    
    // MARK: - Singleton
    
    /// Shared instance for global topic cache management
    static let shared = TopicCacheManager()
    
    private init() {
        // Start with empty cache - will be populated on first request
    }
    
    // MARK: - Public Methods
    
    /// Gets available topic names with ultra-fast caching
    /// - Parameters:
    ///   - forceRefresh: Whether to force a cache refresh
    /// - Returns: Array of available topic names (no counts for performance)
    func getAvailableTopics(forceRefresh: Bool = false) async -> [String] {
        // Return cached data immediately if valid and not forcing refresh
        if !forceRefresh && isCacheValid && !self.availableTopics.isEmpty {
            AppLogger.database.debug("🚀 Topic cache hit: \(self.availableTopics.count) topics")
            return self.availableTopics
        }
        
        // Update cache if needed
        await updateTopicCache()
        
        return availableTopics
    }
    
    /// Updates the topic cache with ultra-lightweight queries
    private func updateTopicCache() async {
        // Prevent concurrent updates
        cacheUpdateTask?.cancel()
        
        cacheUpdateTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            
            isUpdatingTopics = true
            let startTime = CFAbsoluteTimeGetCurrent()
            
            do {
                // Use ultra-lightweight topic discovery - just get unique topic names
                let topics = try await performUltraLightweightTopicDiscovery()
                
                guard !Task.isCancelled else { return }
                
                // Update cache
                availableTopics = topics
                lastCacheUpdate = Date()
                
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                AppLogger.database.debug("✅ Topic cache updated: \(topics.count) topics in \(String(format: "%.3f", duration))s")
                
            } catch {
                AppLogger.database.error("❌ Failed to update topic cache: \(error)")
            }
            
            isUpdatingTopics = false
        }
        
        await cacheUpdateTask?.value
    }
    
    /// Performs ultra-lightweight topic discovery - just gets unique topic names
    /// This is equivalent to "SELECT DISTINCT topic" and uses the topic index
    /// - Returns: Array of unique topic names
    private func performUltraLightweightTopicDiscovery() async throws -> [String] {
        let container = SwiftDataContainer.shared.container
        let modelContext = container.mainContext
        
        AppLogger.database.debug("🔍 Ultra-lightweight topic discovery...")
        
        // Create a minimal descriptor that only fetches what we need
        var descriptor = FetchDescriptor<ArticleModel>()
        // Sort by topic to use the topic index efficiently
        descriptor.sortBy = [SortDescriptor(\.topic)]
        
        let allArticles = try modelContext.fetch(descriptor)
        
        // Extract unique topics efficiently
        var uniqueTopics = Set<String>()
        for article in allArticles {
            if let topic = article.topic {
                uniqueTopics.insert(topic)
            } else {
                uniqueTopics.insert("Uncategorized")
            }
        }
        
        let sortedTopics = Array(uniqueTopics).sorted()
        AppLogger.database.debug("✅ Found \(sortedTopics.count) unique topics")
        
        return sortedTopics
    }
    
    /// Gets article count for a specific topic on-demand (only when needed for "x of y" display)
    /// - Parameters:
    ///   - topic: The topic to count articles for
    ///   - showUnreadOnly: Whether to count only unread articles
    ///   - showBookmarkedOnly: Whether to count only bookmarked articles
    ///   - qualityFilter: Quality filter to apply
    /// - Returns: Article count for the topic
    func getTopicArticleCount(
        topic: String,
        showUnreadOnly: Bool = false,
        showBookmarkedOnly: Bool = false,
        qualityFilter: String = "All"
    ) async throws -> Int {
        let container = SwiftDataContainer.shared.container
        let modelContext = container.mainContext
        
        // Use separate methods to avoid complex predicate compilation issues
        let articles: [ArticleModel]
        
        if topic == "Uncategorized" {
            articles = try await fetchUncategorizedArticles(
                modelContext: modelContext,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly
            )
        } else {
            articles = try await fetchTopicArticles(
                topic: topic,
                modelContext: modelContext,
                showUnreadOnly: showUnreadOnly,
                showBookmarkedOnly: showBookmarkedOnly
            )
        }
        
        // Apply quality filter in memory if needed
        if qualityFilter == "All" {
            return articles.count
        } else {
            return articles.filter { $0.meetsQualityThreshold(qualityFilter) }.count
        }
    }
    
    /// Fetches uncategorized articles with simple predicates
    private func fetchUncategorizedArticles(
        modelContext: ModelContext,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool
    ) async throws -> [ArticleModel] {
        var descriptor = FetchDescriptor<ArticleModel>()
        
        if showUnreadOnly && showBookmarkedOnly {
            descriptor.predicate = #Predicate<ArticleModel> { $0.topic == nil }
            let allArticles = try modelContext.fetch(descriptor)
            return allArticles.filter { !$0.isViewed && $0.isBookmarked }
        } else if showUnreadOnly {
            descriptor.predicate = #Predicate<ArticleModel> { $0.topic == nil }
            let allArticles = try modelContext.fetch(descriptor)
            return allArticles.filter { !$0.isViewed }
        } else if showBookmarkedOnly {
            descriptor.predicate = #Predicate<ArticleModel> { $0.topic == nil }
            let allArticles = try modelContext.fetch(descriptor)
            return allArticles.filter { $0.isBookmarked }
        } else {
            descriptor.predicate = #Predicate<ArticleModel> { $0.topic == nil }
            return try modelContext.fetch(descriptor)
        }
    }
    
    /// Fetches articles for a specific topic with simple predicates
    private func fetchTopicArticles(
        topic: String,
        modelContext: ModelContext,
        showUnreadOnly: Bool,
        showBookmarkedOnly: Bool
    ) async throws -> [ArticleModel] {
        var descriptor = FetchDescriptor<ArticleModel>()
        descriptor.predicate = #Predicate<ArticleModel> { $0.topic == topic }
        
        let allArticles = try modelContext.fetch(descriptor)
        
        if showUnreadOnly && showBookmarkedOnly {
            return allArticles.filter { !$0.isViewed && $0.isBookmarked }
        } else if showUnreadOnly {
            return allArticles.filter { !$0.isViewed }
        } else if showBookmarkedOnly {
            return allArticles.filter { $0.isBookmarked }
        } else {
            return allArticles
        }
    }
    
    /// Invalidates the topic cache, forcing a refresh on next request
    func invalidateCache() {
        lastCacheUpdate = Date.distantPast
        AppLogger.database.debug("🗑️ Topic cache invalidated")
    }
    
    /// Warms the topic cache in the background for better performance
    func warmCache() {
        Task.detached(priority: .background) { @MainActor in
            _ = await self.getAvailableTopics(forceRefresh: false)
        }
    }
    
    /// Gets topic names (now the primary method since we only cache names)
    /// - Returns: Array of topic names
    func getTopicNames() async -> [String] {
        return await getAvailableTopics()
    }
    
    // MARK: - Cache Statistics
    
    /// Gets cache performance statistics
    func getCacheStatistics() -> (isValid: Bool, topicCount: Int, lastUpdate: Date, age: TimeInterval) {
        return (
            isValid: isCacheValid,
            topicCount: availableTopics.count,
            lastUpdate: lastCacheUpdate,
            age: Date().timeIntervalSince(lastCacheUpdate)
        )
    }
}
