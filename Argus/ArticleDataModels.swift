import Foundation
import SwiftData
import SwiftUI

/// SwiftData model for articles
@Model
final class ArticleModel {
    // MARK: - Core Identifiers

    /// Unique identifier for the article
    // Removed @Attribute(.unique) for CloudKit compatibility
    var id: UUID = UUID()

    /// URL path to the JSON file for this article
    // Removed @Attribute(.unique) for CloudKit compatibility
    var jsonURL: String = ""

    /// Optional URL to the original article
    var url: String?

    // MARK: - Content Fields

    /// Main title of the article (from tiny_title in API)
    var title: String = ""

    /// Body text of the article (from tiny_summary in API)
    var body: String = ""

    /// Source domain for the article
    var domain: String?

    /// Full article title (from article_title in API)
    var articleTitle: String = ""

    /// Who or what is affected by this article
    var affected: String = ""

    // MARK: - Metadata

    /// When the article was published
    var publishDate: Date = Date()

    /// When the article was added to the database
    var addedDate: Date = Date()

    /// Topic this article belongs to
    var topic: String?

    // MARK: - User Interaction States

    /// Whether the user has viewed this article
    var isViewed: Bool = false

    /// Whether the user has bookmarked this article 
    var isBookmarked: Bool = false
    
    // Archive functionality removed
    
    // MARK: - Quality Indicators

    /// Quality score for the sources used in the article (1-10)
    var sourcesQuality: Int?

    /// Quality score for the logical arguments in the article (1-10)
    var argumentQuality: Int?

    /// Type of source (news, opinion, analysis, etc.)
    var sourceType: String?

    /// Analysis of the source reliability
    var sourceAnalysis: String?

    /// Overall quality score (1-10)
    var quality: Int?

    // MARK: - AI Analysis

    /// AI-generated summary of the article
    var summary: String?

    /// Critical analysis of the article content
    var criticalAnalysis: String?

    /// Identified logical fallacies in the article
    var logicalFallacies: String?

    /// How this article relates to its topic
    var relationToTopic: String?

    /// Additional AI insights about the article
    var additionalInsights: String?

    // MARK: - Rich Text Blobs

    /// Rich text blob for title
    var titleBlob: Data?

    /// Rich text blob for body content
    var bodyBlob: Data?

    /// Rich text blob for summary
    var summaryBlob: Data?

    /// Rich text blob for critical analysis
    var criticalAnalysisBlob: Data?

    /// Rich text blob for logical fallacies
    var logicalFallaciesBlob: Data?

    /// Rich text blob for source analysis
    var sourceAnalysisBlob: Data?

    /// Rich text blob for relation to topic
    var relationToTopicBlob: Data?

    /// Rich text blob for additional insights
    var additionalInsightsBlob: Data?

    // MARK: - Additional Metadata

    /// Statistics about the AI engine processing
    var engineStats: String?

    /// Related articles data
    var similarArticles: String?

    // MARK: - Relationships

    /// Topics this article belongs to (for many-to-many relationship)
    @Relationship(deleteRule: .cascade) var topics: [TopicModel]? = []

    // MARK: - Initializer

    init(
        id: UUID,
        jsonURL: String,
        url: String? = nil,
        title: String,
        body: String,
        domain: String? = nil,
        articleTitle: String,
        affected: String,
        publishDate: Date,
        addedDate: Date = Date(),
        topic: String? = nil,
        isViewed: Bool = false,
        isBookmarked: Bool = false,
        sourcesQuality: Int? = nil,
        argumentQuality: Int? = nil,
        sourceType: String? = nil,
        sourceAnalysis: String? = nil,
        quality: Int? = nil,
        summary: String? = nil,
        criticalAnalysis: String? = nil,
        logicalFallacies: String? = nil,
        relationToTopic: String? = nil,
        additionalInsights: String? = nil,
        engineStats: String? = nil,
        similarArticles: String? = nil,
        titleBlob: Data? = nil,
        bodyBlob: Data? = nil,
        summaryBlob: Data? = nil,
        criticalAnalysisBlob: Data? = nil,
        logicalFallaciesBlob: Data? = nil,
        sourceAnalysisBlob: Data? = nil,
        relationToTopicBlob: Data? = nil,
        additionalInsightsBlob: Data? = nil
    ) {
        self.id = id
        self.jsonURL = jsonURL
        self.url = url
        self.title = title
        self.body = body
        self.domain = domain
        self.articleTitle = articleTitle
        self.affected = affected
        self.publishDate = publishDate
        self.addedDate = addedDate
        self.topic = topic
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
        // isArchived parameter ignored (feature removed)
        self.sourcesQuality = sourcesQuality
        self.argumentQuality = argumentQuality
        self.sourceType = sourceType
        self.sourceAnalysis = sourceAnalysis
        self.quality = quality
        self.summary = summary
        self.criticalAnalysis = criticalAnalysis
        self.logicalFallacies = logicalFallacies
        self.relationToTopic = relationToTopic
        self.additionalInsights = additionalInsights
        self.engineStats = engineStats
        self.similarArticles = similarArticles
        self.titleBlob = titleBlob
        self.bodyBlob = bodyBlob
        self.summaryBlob = summaryBlob
        self.criticalAnalysisBlob = criticalAnalysisBlob
        self.logicalFallaciesBlob = logicalFallaciesBlob
        self.sourceAnalysisBlob = sourceAnalysisBlob
        self.relationToTopicBlob = relationToTopicBlob
        self.additionalInsightsBlob = additionalInsightsBlob
    }

    // Convenience initializer will be implemented after ArticleJSON is available
}

/// SwiftData model for tracking which articles have been seen
@Model
final class SeenArticleModel {
    /// Unique identifier matching the article ID
    // Removed @Attribute(.unique) for CloudKit compatibility
    var id: UUID = UUID()

    /// URL path to the JSON file for this article (for lookups)
    // Removed @Attribute(.unique) for CloudKit compatibility
    var jsonURL: String = ""

    /// When this article was first seen
    var date: Date = Date()

    /// Initializer
    init(id: UUID, jsonURL: String, date: Date = Date()) {
        self.id = id
        self.jsonURL = jsonURL
        self.date = date
    }
}

/// SwiftData model for article topics
@Model
final class TopicModel {
    /// Unique identifier for the topic
    // Removed @Attribute(.unique) for CloudKit compatibility
    var id: UUID = UUID()

    /// Name of the topic
    // Removed @Attribute(.unique) for CloudKit compatibility
    var name: String = ""

    /// User preference for priority level
    var priority: TopicPriority = TopicPriority.normal

    /// Whether to receive notifications for this topic
    var notificationsEnabled: Bool = false

    /// Display order for UI (lower values appear first)
    var displayOrder: Int = 0

    /// Articles belonging to this topic
    @Relationship(deleteRule: .cascade, inverse: \ArticleModel.topics) var articles: [ArticleModel]? = []

    /// Initializer
    init(id: UUID = UUID(), name: String, priority: TopicPriority = .normal, notificationsEnabled: Bool = false, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.priority = priority
        self.notificationsEnabled = notificationsEnabled
        self.displayOrder = displayOrder
    }
}

/// Priority levels for topics
enum TopicPriority: String, Codable, CaseIterable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"
    case critical = "Critical"

    var intValue: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}

// MARK: - Helpers for Migration and Data Access

// Migration utilities will be implemented in a later phase
// when NotificationData is properly defined and accessible
