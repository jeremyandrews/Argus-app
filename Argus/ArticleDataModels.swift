import Foundation
import SwiftData
import SwiftUI

/// SwiftData model for articles
@Model
final class ArticleModel: Equatable {
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

    /// Updates blob data from a NotificationData object
    /// Used during migration and compatibility with legacy code
    func updateBlobs(from notification: NotificationData) {
        // Transfer all blob data from the NotificationData to this ArticleModel
        self.titleBlob = notification.title_blob
        self.bodyBlob = notification.body_blob
        self.summaryBlob = notification.summary_blob
        self.criticalAnalysisBlob = notification.critical_analysis_blob
        self.logicalFallaciesBlob = notification.logical_fallacies_blob
        self.sourceAnalysisBlob = notification.source_analysis_blob
        self.relationToTopicBlob = notification.relation_to_topic_blob
        self.additionalInsightsBlob = notification.additional_insights_blob
    }
    
    /// Regenerates missing blob data for this ArticleModel
    /// Returns the number of blobs regenerated
    @MainActor
    func regenerateMissingBlobs() -> Int {
        return regenerateAllBlobs(for: self)
    }
    
    public static func == (lhs: ArticleModel, rhs: ArticleModel) -> Bool {
        return lhs.id == rhs.id
    }
}

// Extensions removed, implementation moved inside classes

/// SwiftData model for tracking which articles have been seen
@Model
final class SeenArticleModel: Equatable {
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
    
    public static func == (lhs: SeenArticleModel, rhs: SeenArticleModel) -> Bool {
        return lhs.id == rhs.id
    }
}

/// SwiftData model for article topics
@Model
final class TopicModel: Equatable {
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
    
    public static func == (lhs: TopicModel, rhs: TopicModel) -> Bool {
        return lhs.id == rhs.id
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

// MARK: - API Compatibility Extensions

/// Typealias for backward compatibility
typealias SeenArticle = SeenArticleModel
// Note: NotificationData is defined in MarkdownUtilities.swift as a legacy class for migration

/// SeenArticle compatibility extension to make SeenArticleModel work with existing APIs
extension SeenArticleModel {
    /// The json_url property of the seen article (renamed to match SeenArticle)
    var json_url: String {
        get { return jsonURL }
        set { jsonURL = newValue }
    }
}

// MARK: - API Compatibility Extensions

/// NotificationData compatibility extension to make ArticleModel work with existing APIs
extension ArticleModel {
    /// The json_url property of the notification data (renamed to match NotificationData)
    var json_url: String {
        get { return jsonURL }
        set { jsonURL = newValue }
    }

    /// The article_url property of the notification data (renamed to match NotificationData)
    var article_url: String? {
        get { return url }
        set { url = newValue }
    }
    
    /// Get the best available URL for this article - mirrors NotificationData implementation
    func getArticleUrl(additionalContent: [String: Any]? = nil) -> String? {
        // First check for the direct article_url field (which is 'url' in ArticleModel)
        if let directURL = url, !directURL.isEmpty {
            return directURL
        }

        // If we have the URL cached in additionalContent, use that
        if let content = additionalContent, let urlString = content["url"] as? String {
            return urlString
        }

        // Otherwise try to construct a URL from the domain
        if let domain = domain {
            return "https://\(domain)"
        }

        return nil
    }

    /// The article_title property of the notification data (renamed to match NotificationData)
    var article_title: String {
        get { return articleTitle }
        set { articleTitle = newValue }
    }

    /// The pub_date property of the notification data (renamed to match NotificationData)
    var pub_date: Date {
        get { return publishDate }
        set { publishDate = newValue }
    }

    /// The date property of the notification data (renamed to match NotificationData)
    var date: Date {
        get { return addedDate }
        set { addedDate = newValue }
    }

    /// The sources_quality property of the notification data (renamed to match NotificationData)
    var sources_quality: Int? {
        get { return sourcesQuality }
        set { sourcesQuality = newValue }
    }

    /// The argument_quality property of the notification data (renamed to match NotificationData)
    var argument_quality: Int? {
        get { return argumentQuality }
        set { argumentQuality = newValue }
    }

    /// The source_type property of the notification data (renamed to match NotificationData)
    var source_type: String? {
        get { return sourceType }
        set { sourceType = newValue }
    }

    /// The source_analysis property of the notification data (renamed to match NotificationData)
    var source_analysis: String? {
        get { return sourceAnalysis }
        set { sourceAnalysis = newValue }
    }

    /// The critical_analysis property of the notification data (renamed to match NotificationData)
    var critical_analysis: String? {
        get { return criticalAnalysis }
        set { criticalAnalysis = newValue }
    }

    /// The logical_fallacies property of the notification data (renamed to match NotificationData)
    var logical_fallacies: String? {
        get { return logicalFallacies }
        set { logicalFallacies = newValue }
    }

    /// The relation_to_topic property of the notification data (renamed to match NotificationData)
    var relation_to_topic: String? {
        get { return relationToTopic }
        set { relationToTopic = newValue }
    }

    /// The additional_insights property of the notification data (renamed to match NotificationData)
    var additional_insights: String? {
        get { return additionalInsights }
        set { additionalInsights = newValue }
    }

    /// The engine_stats property of the notification data (renamed to match NotificationData)
    var engine_stats: String? {
        get { return engineStats }
        set { engineStats = newValue }
    }

    /// The similar_articles property of the notification data (renamed to match NotificationData)
    var similar_articles: String? {
        get { return similarArticles }
        set { similarArticles = newValue }
    }
}
