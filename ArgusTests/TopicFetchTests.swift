//
//  TopicFetchTests.swift
//  ArgusTests
//
//  Tests for the lightweight topic fetching optimization
//

import Testing
import SwiftData
import Foundation
@testable import Argus

@Suite("Topic Fetch Optimization Tests")
struct TopicFetchTests {

    /// Shared ModelContainer for all tests
    static let container: ModelContainer = {
        let schema = Schema([ArticleModel.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)

        // Setup test data once for all tests
        let context = ModelContext(container)
        try! setupTestData(context: context)

        return container
    }()

    /// Setup test database with realistic data distribution
    /// - Total: ~3000 articles
    /// - Topic distribution varies from 0 to 1000 articles per topic
    /// - Mix of read/unread, bookmarked, and quality scores
    static func setupTestData(context: ModelContext) throws {
        print("📊 Setting up test database with ~3000 articles...")

        let startTime = CFAbsoluteTimeGetCurrent()

        // Define topics with varying article counts
        let topicDistribution: [(topic: String, count: Int)] = [
            ("Politics", 1000),      // Major topic
            ("Technology", 800),     // Major topic
            ("Science", 500),        // Medium topic
            ("Business", 300),       // Medium topic
            ("Health", 200),         // Small topic
            ("Sports", 100),         // Small topic
            ("Entertainment", 50),   // Very small topic
            ("Education", 30),       // Very small topic
            ("Environment", 20),     // Tiny topic
            ("EmptyTopic", 0)        // No articles (edge case)
        ]

        var articleCount = 0
        let baseDate = Date().addingTimeInterval(-365 * 24 * 60 * 60) // 1 year ago

        for (topic, count) in topicDistribution {
            for i in 0..<count {
                // Create article using the existing initializer
                let article = ArticleModel(
                    id: UUID(),
                    jsonURL: "test://\(topic.lowercased())/\(i).json",
                    title: "\(topic) Article \(i + 1)",
                    body: "Test body for \(topic) article \(i + 1)",
                    articleTitle: "\(topic) Article \(i + 1)",
                    affected: "",
                    publishDate: baseDate.addingTimeInterval(Double(articleCount) * (365.0 / 3000.0) * 24 * 60 * 60),
                    addedDate: Date(),
                    topic: topic,
                    isViewed: Double.random(in: 0...1) > 0.6,
                    isBookmarked: Double.random(in: 0...1) > 0.9,
                    quality: Int.random(in: 1...10)
                )

                context.insert(article)
                articleCount += 1

                // Batch save every 500 articles for performance
                if articleCount % 500 == 0 {
                    try context.save()
                    print("  Inserted \(articleCount) articles...")
                }
            }
        }

        // Final save
        try context.save()

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("✅ Created \(articleCount) test articles in \(String(format: "%.2f", duration))s")
        print("   Topics: \(topicDistribution.map { "\($0.topic)(\($0.count))" }.joined(separator: ", "))")
    }

    /// Helper to create ArticleOperations with test container
    static func createTestArticleOps() -> ArticleOperations {
        let service = ArticleService(modelContainer: container)
        return ArticleOperations(articleService: service)
    }

    /// Test that fetchDistinctTopics returns unique topics
    @Test("fetchDistinctTopics returns unique topics")
    func testFetchDistinctTopics() async throws {
        // This test verifies that the lightweight topic query works
        let articleOps = Self.createTestArticleOps()

        // The method should execute without throwing
        //  Using default context (.listView)
        let topics = try await articleOps.fetchDistinctTopics()

        // Topics should be a Set (no duplicates) - type is guaranteed by signature

        // All topics should be non-empty strings
        for topic in topics {
            #expect(!topic.isEmpty, "Topic should not be empty string")
        }

        // With our test data, we should have 9 topics (excluding EmptyTopic which has 0 articles)
        print("Found \(topics.count) topics: \(topics.sorted())")
    }

    /// Test that using .detailView context returns ALL topics, not just those in limited fetch
    @Test("fetchDistinctTopics with .detailView returns all topics")
    func testFetchDistinctTopicsWithDetailViewReturnsAllTopics() async throws {
        let articleOps = Self.createTestArticleOps()

        // Get topics with .listView (limited)
        let limitedTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "All",
            context: .listView
        )

        // Get topics with .detailView (all)
        let allTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "All",
            context: .detailView
        )

        // .detailView should return same or more topics than .listView
        #expect(allTopics.count >= limitedTopics.count,
                ".detailView returned \(allTopics.count) topics, .listView returned \(limitedTopics.count) - should be >=")

        // All topics from limited fetch should be in the full fetch
        #expect(limitedTopics.isSubset(of: allTopics),
                "Limited topics should be a subset of all topics")
    }

    /// Test that fetchDistinctTopics respects unread filter
    @Test("fetchDistinctTopics respects unread filter")
    func testFetchDistinctTopicsUnreadFilter() async throws {
        let articleOps = Self.createTestArticleOps()

        // Fetch all topics
        let allTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "All"
        )

        // Fetch only unread topics
        let unreadTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: true,
            showBookmarkedOnly: false,
            qualityFilter: "All"
        )

        // Unread topics should be subset or equal to all topics
        #expect(unreadTopics.isSubset(of: allTopics) || unreadTopics == allTopics,
                "Unread topics should be a subset of all topics")
    }

    /// Test that fetchDistinctTopics respects bookmarked filter
    @Test("fetchDistinctTopics respects bookmarked filter")
    func testFetchDistinctTopicsBookmarkedFilter() async throws {
        let articleOps = Self.createTestArticleOps()

        // Fetch all topics
        let allTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "All"
        )

        // Fetch only bookmarked topics
        let bookmarkedTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: true,
            qualityFilter: "All"
        )

        // Bookmarked topics should be subset or equal to all topics
        #expect(bookmarkedTopics.isSubset(of: allTopics) || bookmarkedTopics == allTopics,
                "Bookmarked topics should be a subset of all topics")
    }

    /// Test that fetchDistinctTopics respects quality filter
    @Test("fetchDistinctTopics respects quality filter")
    func testFetchDistinctTopicsQualityFilter() async throws {
        let articleOps = Self.createTestArticleOps()

        // Fetch all topics
        let allTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "All"
        )

        // Fetch only good+ topics
        let goodTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "Good+"
        )

        // Good+ topics should be subset or equal to all topics
        #expect(goodTopics.isSubset(of: allTopics) || goodTopics == allTopics,
                "Good+ topics should be a subset of all topics")
    }

    /// Test performance: fetchDistinctTopics should be fast
    @Test("fetchDistinctTopics performance")
    func testFetchDistinctTopicsPerformance() async throws {
        let articleOps = Self.createTestArticleOps()

        let startTime = CFAbsoluteTimeGetCurrent()
        // Using default context (.listView)
        _ = try await articleOps.fetchDistinctTopics()
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        // Should complete in under 1 second even with large datasets
        #expect(duration < 1.0, "fetchDistinctTopics took \(duration)s, expected < 1s")
    }

    /// Test that combined filters work correctly
    @Test("fetchDistinctTopics with combined filters")
    func testFetchDistinctTopicsCombinedFilters() async throws {
        let articleOps = Self.createTestArticleOps()

        // Fetch with multiple filters
        let filteredTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: true,
            showBookmarkedOnly: true,
            qualityFilter: "Good+"
        )

        // Should execute without error - type is guaranteed by signature

        // All topics should be non-empty
        for topic in filteredTopics {
            #expect(!topic.isEmpty)
        }
    }

    /// Test that topics with zero matching articles are not shown
    /// BUG: Topics appear in topic bar even when they have no articles matching current filters
    @Test("Topics with zero articles should not appear")
    func testTopicsWithZeroArticlesShouldNotAppear() async throws {
        let articleOps = Self.createTestArticleOps()

        // Get topics with a specific filter
        let unreadTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: true,
            showBookmarkedOnly: false,
            qualityFilter: "All"
        )

        // For each topic, verify it actually has articles matching the filter
        for topic in unreadTopics {
            let articles = try await articleOps.fetchArticles(
                topic: topic,
                showUnreadOnly: true,
                showBookmarkedOnly: false,
                qualityFilter: "All",
                context: .listView
            )

            // BUG: This should never fail, but if it does, we have a topic with zero articles
            #expect(articles.count > 0,
                    "Topic '\(topic)' appears in topic list but has 0 unread articles")
        }
    }

    /// Test consistency between topics and article counts for bookmarked filter
    @Test("Bookmarked topics should have bookmarked articles")
    func testBookmarkedTopicsHaveBookmarkedArticles() async throws {
        let articleOps = Self.createTestArticleOps()

        // Get topics with bookmarked filter
        let bookmarkedTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: true,
            qualityFilter: "All"
        )

        // For each topic, verify it actually has bookmarked articles
        for topic in bookmarkedTopics {
            let articles = try await articleOps.fetchArticles(
                topic: topic,
                showUnreadOnly: false,
                showBookmarkedOnly: true,
                qualityFilter: "All",
                context: .listView
            )

            #expect(articles.count > 0,
                    "Topic '\(topic)' appears in bookmarked topics but has 0 bookmarked articles")
        }
    }

    /// Test consistency for quality filter
    @Test("Good+ topics should have Good+ articles")
    func testQualityFilteredTopicsHaveQualityArticles() async throws {
        let articleOps = Self.createTestArticleOps()

        // Get topics with Good+ filter
        let goodTopics = try await articleOps.fetchDistinctTopics(
            showUnreadOnly: false,
            showBookmarkedOnly: false,
            qualityFilter: "Good+"
        )

        // For each topic, verify it actually has Good+ articles
        for topic in goodTopics {
            let articles = try await articleOps.fetchArticles(
                topic: topic,
                showUnreadOnly: false,
                showBookmarkedOnly: false,
                qualityFilter: "Good+",
                context: .listView
            )

            #expect(articles.count > 0,
                    "Topic '\(topic)' appears in Good+ topics but has 0 Good+ articles")
        }
    }
}
