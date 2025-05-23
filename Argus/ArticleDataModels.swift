import Foundation
import SwiftData
import SwiftUI

/// Structure for storing Argus engine processing details in a strongly-typed format 
/// This is the canonical definition - do not redefine this struct elsewhere
struct ArgusDetailsData {
    /// The model used for processing (e.g., "mistral-small:24b-instruct-2501-fp16")
    let model: String
    
    /// Processing time in seconds (e.g., 232.673831761)
    let elapsedTime: Double
    
    /// When the article was processed
    let date: Date
    
    /// Raw statistics string (e.g., "324871:41249:327:3:11:30")
    let stats: String
    
    /// Article database ID from backend
    let databaseId: Int?
    
    /// Additional system information
    let systemInfo: [String: Any]?
}

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
    
    /// Database ID from the backend system
    var databaseId: Int?

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
    
    /// Action recommendations based on the article content
    var actionRecommendations: String?
    
    /// Talking points for facilitating discussions about the article
    var talkingPoints: String?
    
    /// Simplified explanation of the article (Explain Like I'm 5)
    var eli5: String?

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
    
    /// Rich text blob for action recommendations
    var actionRecommendationsBlob: Data?
    
    /// Rich text blob for talking points
    var talkingPointsBlob: Data?
    
    /// Rich text blob for eli5 content
    var eli5Blob: Data?

    // MARK: - Additional Metadata
    
    /// Engine model identifier (e.g., "mistral-small:24b-instruct-2501-fp16")
    var engineModel: String?
    
    /// Processing time in seconds (e.g., 232.673831761)
    var engineElapsedTime: Double?
    
    /// Raw statistics string (e.g., "324871:41249:327:3:11:30")
    var engineRawStats: String?
    
    /// Serialized system information (JSON data)
    var engineSystemInfoData: Data?

    /// Related articles serialized Data
    var relatedArticlesData: Data?
    
    /// Computed property to access structured related articles
    var relatedArticles: [RelatedArticle]? {
        get {
            guard let data = relatedArticlesData, !data.isEmpty else { 
                AppLogger.database.debug("No related articles data found for article \(self.id)")
                return nil 
            }
            
            do {
                // Create decoder with explicit date strategy
                let decoder = JSONDecoder()
                // Use seconds since 1970 format (default for JSONEncoder)
                decoder.dateDecodingStrategy = .secondsSince1970
                
                let decodedArticles = try decoder.decode([RelatedArticle].self, from: data)
                AppLogger.database.debug("Successfully decoded \(decodedArticles.count) related articles for article \(self.id)")
                
                // Validate that the related articles have valid data
                if !decodedArticles.isEmpty {
                    let firstArticle = decodedArticles[0]
                    AppLogger.database.debug("First related article - ID: \(firstArticle.id), Title: '\(firstArticle.title)', URL: '\(firstArticle.jsonURL)'")
                    if let date = firstArticle.publishedDate {
                        AppLogger.database.debug("Published date: \(date.formatted())")
                    }
                }
                
                return decodedArticles
            } catch {
                AppLogger.database.error("Failed to decode relatedArticlesData for article \(self.id): \(error)")
                return nil
            }
        }
        set {
            if let newValue = newValue, !newValue.isEmpty {
                do {
                    // Check if the articles have valid data
                    for article in newValue {
                        if article.jsonURL.isEmpty {
                            AppLogger.database.warning("Related article with empty jsonURL: ID: \(article.id), Title: '\(article.title)'")
                        }
                    }
                    
                    // Create encoder with explicit date strategy
                    let encoder = JSONEncoder()
                    // Use seconds since 1970 format (default, but being explicit)
                    encoder.dateEncodingStrategy = .secondsSince1970
                    
                    relatedArticlesData = try encoder.encode(newValue)
                    AppLogger.database.debug("Stored \(newValue.count) related articles for article \(self.id)")
                } catch {
                    AppLogger.database.error("Failed to encode related articles for article \(self.id): \(error)")
                    relatedArticlesData = nil
                }
            } else {
                relatedArticlesData = nil
                AppLogger.database.debug("Cleared related articles for article \(self.id)")
            }
        }
    }

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
        actionRecommendations: String? = nil,
        talkingPoints: String? = nil,
        eli5: String? = nil,
        // Legacy field - we'll parse it if provided
        engineStats: String? = nil,
        // New engine stats fields
        engineModel: String? = nil,
        engineElapsedTime: Double? = nil,
        engineRawStats: String? = nil,
        engineSystemInfo: [String: Any]? = nil,
        databaseId: Int? = nil,
        relatedArticles: [RelatedArticle]? = nil,
        titleBlob: Data? = nil,
        bodyBlob: Data? = nil,
        summaryBlob: Data? = nil,
        criticalAnalysisBlob: Data? = nil,
        logicalFallaciesBlob: Data? = nil,
        sourceAnalysisBlob: Data? = nil,
        relationToTopicBlob: Data? = nil,
        additionalInsightsBlob: Data? = nil,
        actionRecommendationsBlob: Data? = nil,
        talkingPointsBlob: Data? = nil,
        eli5Blob: Data? = nil
    ) {
        self.id = id
        self.jsonURL = jsonURL
        self.url = url
        self.title = title
        self.body = body
        self.domain = domain
        self.articleTitle = articleTitle
        self.affected = affected
        self.databaseId = databaseId
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
        self.actionRecommendations = actionRecommendations
        self.talkingPoints = talkingPoints
        self.eli5 = eli5
        // Handle new engine stats fields:
        self.engineModel = engineModel
        self.engineElapsedTime = engineElapsedTime
        self.engineRawStats = engineRawStats
        
        // Serialize system info if provided
        if let systemInfo = engineSystemInfo {
            self.engineSystemInfoData = try? JSONSerialization.data(withJSONObject: systemInfo)
        }
        
        // If no structured data but we have engineStats, try to parse it
        if (engineModel == nil || engineElapsedTime == nil || engineRawStats == nil) && engineStats != nil {
            if let data = engineStats?.data(using: .utf8),
               let engineDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // Parse the engine stats and extract structured fields
                self.engineModel = self.engineModel ?? engineDict["model"] as? String
                self.engineElapsedTime = self.engineElapsedTime ?? engineDict["elapsed_time"] as? Double
                self.engineRawStats = self.engineRawStats ?? engineDict["stats"] as? String
                
                // ENHANCED: Extract the database ID with robust type handling if it's not already set
                if self.databaseId == nil {
                    if let intId = engineDict["id"] as? Int {
                        self.databaseId = intId
                        AppLogger.database.debug("✅ Initializer: Extracted database ID as Int: \(intId)")
                    } else if let numberVal = engineDict["id"] as? NSNumber {
                        // NSNumber case - common when deserialized from JSON
                        self.databaseId = numberVal.intValue
                        AppLogger.database.debug("✅ Initializer: Extracted database ID from NSNumber: \(numberVal.intValue)")
                    } else if let stringId = engineDict["id"] as? String, let intFromString = Int(stringId) {
                        self.databaseId = intFromString
                        AppLogger.database.debug("✅ Initializer: Extracted database ID from String: \(intFromString)")
                    } else if let doubleId = engineDict["id"] as? Double, doubleId.truncatingRemainder(dividingBy: 1) == 0 {
                        self.databaseId = Int(doubleId)
                        AppLogger.database.debug("✅ Initializer: Extracted database ID from Double: \(Int(doubleId))")
                    } else if let rawId = engineDict["id"] {
                        let typeString = String(describing: type(of: rawId))
                        AppLogger.database.debug("⚠️ Initializer: ID found but couldn't convert to Int: \(String(describing: rawId)) (Type: \(typeString))")
                    }
                }
                
                // If we have system info and no existing engine system info data
                if self.engineSystemInfoData == nil, let sysInfo = engineDict["system_info"] as? [String: Any] {
                    self.engineSystemInfoData = try? JSONSerialization.data(withJSONObject: sysInfo)
                }
            }
        }
        
        // Store related articles as encoded data
        self.relatedArticles = relatedArticles
        self.titleBlob = titleBlob
        self.bodyBlob = bodyBlob
        self.summaryBlob = summaryBlob
        self.criticalAnalysisBlob = criticalAnalysisBlob
        self.logicalFallaciesBlob = logicalFallaciesBlob
        self.sourceAnalysisBlob = sourceAnalysisBlob
        self.relationToTopicBlob = relationToTopicBlob
        self.additionalInsightsBlob = additionalInsightsBlob
        self.actionRecommendationsBlob = actionRecommendationsBlob
        self.talkingPointsBlob = talkingPointsBlob
        self.eli5Blob = eli5Blob
    }

    /// Regenerates missing blob data for this ArticleModel
    /// Returns the number of blobs regenerated
    @MainActor
    func regenerateMissingBlobs() -> Int {
        return regenerateAllBlobs(for: self)
    }

    /// Computed property to access the system info
    var engineSystemInfo: [String: Any]? {
        get {
            guard let data = engineSystemInfoData else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
    
    /// Computed property for structured engine stats data
    var engineDetails: ArgusDetailsData? {
        // Only generate if we have the essential fields
        guard let model = engineModel,
              let elapsed = engineElapsedTime,
              let stats = engineRawStats else {
            return nil
        }
        
        return ArgusDetailsData(
            model: model,
            elapsedTime: elapsed,
            date: addedDate,
            stats: stats,
            databaseId: databaseId,
            systemInfo: engineSystemInfo
        )
    }
    
    public static func == (lhs: ArticleModel, rhs: ArticleModel) -> Bool {
        return lhs.id == rhs.id
    }
}

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

// MARK: - API Compatibility Extensions

/// Typealias for backward compatibility
typealias SeenArticle = SeenArticleModel

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
    
    /// The action_recommendations property of the notification data (snake_case format)
    var action_recommendations: String? {
        get { return actionRecommendations }
        set { actionRecommendations = newValue }
    }
    
    /// The talking_points property of the notification data (snake_case format)
    var talking_points: String? {
        get { return talkingPoints }
        set { talkingPoints = newValue }
    }
    
    /// The eli5 property of the notification data (snake_case format)
    var eli5_text: String? {
        get { return eli5 }
        set { eli5 = newValue }
    }

    /// The engine_stats property of the notification data (renamed to match NotificationData)
    var engine_stats: String? {
        get {
            // If we have the structured fields, reconstruct a JSON string
            if let model = engineModel, let elapsedTime = engineElapsedTime, let stats = engineRawStats {
                // Create the base dictionary with the required fields
                var dict: [String: Any] = [
                    "model": model,
                    "elapsed_time": elapsedTime,
                    "stats": stats
                ]
                
                // IMPORTANT: Add database ID with explicit type handling to ensure proper serialization
                // We MUST add this before creating any copies of the dictionary
                if let dbId = databaseId {
                    // Force dbId to be treated as NSNumber to ensure proper JSON serialization
                    dict["id"] = NSNumber(value: dbId)
                    
                    // Enhanced logging to diagnose the issue
                    AppLogger.database.debug("✅ engine_stats: Adding database ID to JSON: \(dbId) (Type: \(type(of: NSNumber(value: dbId))))")
                } else {
                    // Log when databaseId is nil to help diagnose issues
                    AppLogger.database.debug("⚠️ engine_stats: No database ID available to add to JSON (databaseId is nil)")
                }
                
                // Now handle system info - making sure we're working with the dictionary that already has the ID
                if let sysInfo = engineSystemInfo {
                    // Add system info to the same dictionary that already has the ID
                    dict["system_info"] = sysInfo
                    
                    // Debug logging to verify the final dictionary contents before serialization
                    if let dbId = dict["id"] {
                        let dbIdString = String(describing: dbId)
                        let typeString = String(describing: type(of: dbId))
                        AppLogger.database.debug("✅ engine_stats with system_info: Dictionary includes ID: \(dbIdString) (Type: \(typeString))")
                    } else {
                        AppLogger.database.debug("❌ engine_stats with system_info: Dictionary is MISSING ID field")
                    }
                    
                    // Serialize the dictionary with system info and ID
                    if let data = try? JSONSerialization.data(withJSONObject: dict),
                       let jsonString = String(data: data, encoding: .utf8) {
                        return jsonString
                    }
                } else {
                    // Without system info - serialize the dictionary that has the ID
                    if let data = try? JSONSerialization.data(withJSONObject: dict),
                       let jsonString = String(data: data, encoding: .utf8) {
                        return jsonString
                    }
                }
            }
            
            // If we don't have structured fields or serialization failed, return nil
            return nil
        }
        set {
            // Parse the new value and update structured fields
            if let newValue = newValue, let data = newValue.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // Extract structured fields
                self.engineModel = dict["model"] as? String
                self.engineElapsedTime = dict["elapsed_time"] as? Double
                self.engineRawStats = dict["stats"] as? String
                
                // ENHANCED: Extract database ID with more detailed type handling and logging
                if let intId = dict["id"] as? Int {
                    // Direct Int case - preferred
                    self.databaseId = intId
                    AppLogger.database.debug("✅ engine_stats setter: Extracted database ID as Int: \(intId)")
                } else if let numberVal = dict["id"] as? NSNumber {
                    // NSNumber case - common when deserialized from JSON
                    self.databaseId = numberVal.intValue
                    AppLogger.database.debug("✅ engine_stats setter: Extracted database ID from NSNumber: \(numberVal.intValue)")
                } else if let stringId = dict["id"] as? String, let intFromString = Int(stringId) {
                    // String that can be converted to Int
                    self.databaseId = intFromString
                    AppLogger.database.debug("✅ engine_stats setter: Extracted database ID from String: \(intFromString)")
                } else if let doubleId = dict["id"] as? Double, doubleId.truncatingRemainder(dividingBy: 1) == 0 {
                    // Double with no fractional part
                    self.databaseId = Int(doubleId)
                    AppLogger.database.debug("✅ engine_stats setter: Extracted database ID from Double: \(Int(doubleId))")
                } else if let rawId = dict["id"] {
                    // ID exists but couldn't be converted to Int
                    let typeString = String(describing: type(of: rawId))
                    AppLogger.database.debug("⚠️ engine_stats setter: ID found but couldn't convert to Int: \(String(describing: rawId)) (Type: \(typeString))")
                }
                
                // Handle system info
                if let sysInfo = dict["system_info"] as? [String: Any] {
                    self.engineSystemInfoData = try? JSONSerialization.data(withJSONObject: sysInfo)
                }
            }
        }
    }

    /// The similar_articles property of the notification data (renamed to match NotificationData)
    var similar_articles: String? {
        get {
            if let relatedArticles = relatedArticles {
                // Use consistent encoder with explicit date strategy
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                
                if let data = try? encoder.encode(relatedArticles),
                   let jsonString = String(data: data, encoding: .utf8) {
                    return jsonString
                }
            }
            return nil
        }
        set {
            if let newValue = newValue, let data = newValue.data(using: .utf8) {
                do {
                    // Create decoder with explicit date strategy
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    
                    // First try to parse as an array of RelatedArticle
                    self.relatedArticles = try decoder.decode([RelatedArticle].self, from: data)
                } catch {
                    // If that fails, try to parse as a raw JSON array
                    if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let serializedData = try? JSONSerialization.data(withJSONObject: jsonArray)
                        if let serializedData = serializedData {
                            // Use the same decoder with date strategy here too
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .secondsSince1970
                            self.relatedArticles = try? decoder.decode([RelatedArticle].self, from: serializedData)
                        }
                    }
                }
            } else {
                self.relatedArticles = nil
            }
        }
    }
}
