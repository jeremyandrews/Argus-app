import Foundation
import SwiftUI

/// Struct specifically for decoding related articles from API responses with ISO8601 date strings
struct APIRelatedArticle: Codable {
    let id: Int
    let category: String
    let jsonURL: String
    let publishedDate: String? // API provides this as an ISO8601 string
    let qualityScore: Int
    let similarityScore: Double
    let tinySummary: String
    let title: String
    
    // New vector quality fields
    let vectorScore: Double?
    let vectorActiveDimensions: Int?
    let vectorMagnitude: Double?
    
    // New entity similarity fields
    let entityOverlapCount: Int?
    let primaryOverlapCount: Int?
    let personOverlap: Double?
    let orgOverlap: Double?
    let locationOverlap: Double?
    let eventOverlap: Double?
    let temporalProximity: Double?
    
    // Formula explanation
    let similarityFormula: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case category
        case jsonURL = "json_url"
        case publishedDate = "published_date"
        case qualityScore = "quality_score"
        case similarityScore = "similarity_score"
        case tinySummary = "tiny_summary"
        case title
        
        // New vector quality fields
        case vectorScore = "vector_score"
        case vectorActiveDimensions = "vector_active_dimensions"
        case vectorMagnitude = "vector_magnitude"
        
        // New entity similarity fields
        case entityOverlapCount = "entity_overlap_count"
        case primaryOverlapCount = "primary_overlap_count"
        case personOverlap = "person_overlap"
        case orgOverlap = "org_overlap"
        case locationOverlap = "location_overlap"
        case eventOverlap = "event_overlap"
        case temporalProximity = "temporal_proximity"
        
        // Formula explanation
        case similarityFormula = "similarity_formula"
    }
    
    /// Converts API model to database model with proper date conversion
    func toRelatedArticle() -> RelatedArticle {
        return RelatedArticle(
            id: id,
            category: category,
            jsonURL: jsonURL,
            publishedDate: publishedDate != nil ? ISO8601DateFormatter().date(from: publishedDate!) : nil,
            qualityScore: qualityScore,
            similarityScore: similarityScore,
            tinySummary: tinySummary,
            title: title,
            // New vector quality fields
            vectorScore: vectorScore,
            vectorActiveDimensions: vectorActiveDimensions,
            vectorMagnitude: vectorMagnitude,
            // New entity similarity fields
            entityOverlapCount: entityOverlapCount,
            primaryOverlapCount: primaryOverlapCount,
            personOverlap: personOverlap,
            orgOverlap: orgOverlap,
            locationOverlap: locationOverlap,
            eventOverlap: eventOverlap,
            temporalProximity: temporalProximity,
            // Formula explanation
            similarityFormula: similarityFormula
        )
    }
}

/// Struct for representing a related article in the database
struct RelatedArticle: Codable, Identifiable, Hashable {
    let id: Int
    let category: String
    let jsonURL: String
    let publishedDate: Date?
    let qualityScore: Int
    let similarityScore: Double
    let tinySummary: String
    let title: String
    
    // New vector quality fields
    let vectorScore: Double?
    let vectorActiveDimensions: Int?
    let vectorMagnitude: Double?
    
    // New entity similarity fields
    let entityOverlapCount: Int?
    let primaryOverlapCount: Int?
    let personOverlap: Double?
    let orgOverlap: Double?
    let locationOverlap: Double?
    let eventOverlap: Double?
    let temporalProximity: Double?
    
    // Formula explanation
    let similarityFormula: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case category
        case jsonURL = "json_url"
        case publishedDate = "published_date"
        case qualityScore = "quality_score"
        case similarityScore = "similarity_score"
        case tinySummary = "tiny_summary"
        case title
        
        // New vector quality fields
        case vectorScore = "vector_score"
        case vectorActiveDimensions = "vector_active_dimensions"
        case vectorMagnitude = "vector_magnitude"
        
        // New entity similarity fields
        case entityOverlapCount = "entity_overlap_count"
        case primaryOverlapCount = "primary_overlap_count"
        case personOverlap = "person_overlap"
        case orgOverlap = "org_overlap"
        case locationOverlap = "location_overlap"
        case eventOverlap = "event_overlap"
        case temporalProximity = "temporal_proximity"
        
        // Formula explanation
        case similarityFormula = "similarity_formula"
    }
    
    /// Standard initializer for creating instances directly
    init(id: Int, category: String, jsonURL: String, publishedDate: Date?,
         qualityScore: Int, similarityScore: Double, tinySummary: String, title: String,
         // New vector quality fields
         vectorScore: Double? = nil,
         vectorActiveDimensions: Int? = nil,
         vectorMagnitude: Double? = nil,
         // New entity similarity fields
         entityOverlapCount: Int? = nil,
         primaryOverlapCount: Int? = nil,
         personOverlap: Double? = nil,
         orgOverlap: Double? = nil,
         locationOverlap: Double? = nil,
         eventOverlap: Double? = nil,
         temporalProximity: Double? = nil,
         // Formula explanation
         similarityFormula: String? = nil) {
        self.id = id
        self.category = category
        self.jsonURL = jsonURL
        self.publishedDate = publishedDate
        self.qualityScore = qualityScore
        self.similarityScore = similarityScore
        self.tinySummary = tinySummary
        self.title = title
        
        // New vector quality fields
        self.vectorScore = vectorScore
        self.vectorActiveDimensions = vectorActiveDimensions
        self.vectorMagnitude = vectorMagnitude
        
        // New entity similarity fields
        self.entityOverlapCount = entityOverlapCount
        self.primaryOverlapCount = primaryOverlapCount
        self.personOverlap = personOverlap
        self.orgOverlap = orgOverlap
        self.locationOverlap = locationOverlap
        self.eventOverlap = eventOverlap
        self.temporalProximity = temporalProximity
        
        // Formula explanation
        self.similarityFormula = similarityFormula
    }
    
    /// Decoder initializer for database loading where dates are stored as timestamps
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        jsonURL = try container.decodeIfPresent(String.self, forKey: .jsonURL) ?? ""
        qualityScore = try container.decodeIfPresent(Int.self, forKey: .qualityScore) ?? 0
        similarityScore = try container.decodeIfPresent(Double.self, forKey: .similarityScore) ?? 0.0
        tinySummary = try container.decodeIfPresent(String.self, forKey: .tinySummary) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Title"
        
        // When loaded from database, published_date is stored as a timestamp
        let timestamp = try container.decodeIfPresent(Double.self, forKey: .publishedDate)
        if let timestamp = timestamp {
            publishedDate = Date(timeIntervalSince1970: timestamp)
        } else {
            publishedDate = nil
        }
        
        // New vector quality fields
        vectorScore = try container.decodeIfPresent(Double.self, forKey: .vectorScore)
        vectorActiveDimensions = try container.decodeIfPresent(Int.self, forKey: .vectorActiveDimensions)
        vectorMagnitude = try container.decodeIfPresent(Double.self, forKey: .vectorMagnitude)
        
        // New entity similarity fields
        entityOverlapCount = try container.decodeIfPresent(Int.self, forKey: .entityOverlapCount)
        primaryOverlapCount = try container.decodeIfPresent(Int.self, forKey: .primaryOverlapCount)
        personOverlap = try container.decodeIfPresent(Double.self, forKey: .personOverlap)
        orgOverlap = try container.decodeIfPresent(Double.self, forKey: .orgOverlap)
        locationOverlap = try container.decodeIfPresent(Double.self, forKey: .locationOverlap)
        eventOverlap = try container.decodeIfPresent(Double.self, forKey: .eventOverlap)
        temporalProximity = try container.decodeIfPresent(Double.self, forKey: .temporalProximity)
        
        // Formula explanation
        similarityFormula = try container.decodeIfPresent(String.self, forKey: .similarityFormula)
    }
    
    // Computed properties for UI display
    var formattedDate: String {
        guard let date = publishedDate else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
    
    var qualityDescription: String {
        switch qualityScore {
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Excellent"
        default: return "Unknown"
        }
    }
    
    var similarityPercent: String {
        String(format: "%.1f%%", similarityScore * 100)
    }
    
    var isSimilarityHigh: Bool {
        similarityScore >= 0.95
    }
    
    var isSimilarityVeryHigh: Bool {
        similarityScore >= 0.98
    }
    
    // MARK: - Vector Quality Computed Properties
    
    /// Formatted vector score as percentage
    var formattedVectorScore: String? {
        guard let score = vectorScore else { return nil }
        return String(format: "%.1f%%", score * 100)
    }
    
    /// Formatted vector active dimensions
    var formattedVectorDimensions: String? {
        guard let dimensions = vectorActiveDimensions else { return nil }
        return "\(dimensions)"
    }
    
    /// Formatted vector magnitude
    var formattedVectorMagnitude: String? {
        guard let magnitude = vectorMagnitude else { return nil }
        return String(format: "%.2f", magnitude)
    }
    
    // MARK: - Entity Similarity Computed Properties
    
    /// Whether this article has any entity similarity data
    var hasEntityData: Bool {
        return personOverlap != nil || orgOverlap != nil || 
               locationOverlap != nil || eventOverlap != nil ||
               temporalProximity != nil
    }
    
    /// Entity overlap count as formatted string
    var formattedEntityOverlapCount: String? {
        guard let count = entityOverlapCount else { return nil }
        return "\(count) shared entities"
    }
    
    /// Primary overlap count as formatted string
    var formattedPrimaryOverlapCount: String? {
        guard let count = primaryOverlapCount else { return nil }
        return "\(count) primary entities"
    }
    
    /// Person overlap as percentage
    var formattedPersonOverlap: String? {
        guard let overlap = personOverlap else { return nil }
        return String(format: "%.0f%%", overlap * 100)
    }
    
    /// Organization overlap as percentage
    var formattedOrgOverlap: String? {
        guard let overlap = orgOverlap else { return nil }
        return String(format: "%.0f%%", overlap * 100)
    }
    
    /// Location overlap as percentage
    var formattedLocationOverlap: String? {
        guard let overlap = locationOverlap else { return nil }
        return String(format: "%.0f%%", overlap * 100)
    }
    
    /// Event overlap as percentage
    var formattedEventOverlap: String? {
        guard let overlap = eventOverlap else { return nil }
        return String(format: "%.0f%%", overlap * 100)
    }
    
    /// Temporal proximity as percentage
    var formattedTemporalProximity: String? {
        guard let proximity = temporalProximity else { return nil }
        return String(format: "%.0f%%", proximity * 100)
    }
    
    /// Concise summary of entity similarity for UI display
    var entitySimilaritySummary: String? {
        guard hasEntityData else { return nil }
        
        var components: [String] = []
        
        if let personOverlap = personOverlap, personOverlap > 0 {
            components.append("Persons: \(formattedPersonOverlap!)")
        }
        
        if let orgOverlap = orgOverlap, orgOverlap > 0 {
            components.append("Orgs: \(formattedOrgOverlap!)")
        }
        
        if let locationOverlap = locationOverlap, locationOverlap > 0 {
            components.append("Locations: \(formattedLocationOverlap!)")
        }
        
        if let eventOverlap = eventOverlap, eventOverlap > 0 {
            components.append("Events: \(formattedEventOverlap!)")
        }
        
        if let temporalProximity = temporalProximity, temporalProximity > 0 {
            components.append("Temporal: \(formattedTemporalProximity!)")
        }
        
        if components.isEmpty {
            return "No significant entity overlap"
        }
        
        return components.joined(separator: ", ")
    }
    
    /// Get a color representing the overall similarity strength
    var similarityColor: Color {
        if similarityScore >= 0.98 {
            return .red      // Extremely high similarity
        } else if similarityScore >= 0.95 {
            return .orange   // Very high similarity
        } else if similarityScore >= 0.85 {
            return .blue     // High similarity
        } else {
            return .gray     // Moderate similarity
        }
    }
}

struct ArticleJSON {
    let id: String // New field for storing the external article ID
    let title: String // tiny_title
    let body: String // tiny_summary
    let jsonURL: String
    let url: String?
    let topic: String?
    let articleTitle: String // unused
    let affected: String
    let domain: String?
    let pubDate: Date?
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    let sourceAnalysis: String?
    let quality: Int?
    let summary: String?
    let criticalAnalysis: String?
    let logicalFallacies: String?
    let relationToTopic: String?
    let additionalInsights: String?
    
    // Engine stats fields
    let engineModel: String?
    let engineElapsedTime: Double?
    let engineRawStats: String?
    let engineSystemInfo: [String: Any]?
    
    // Related articles stored as structured data instead of a string
    let relatedArticles: [RelatedArticle]?
    
    // New fields for R2 URL JSON payload
    let actionRecommendations: String?
    let talkingPoints: String?
    
    // Article database ID from backend
    let databaseId: Int?
}

struct PreparedArticle {
    let id: String // New field for storing the external article ID
    let title: String // tiny_title
    let body: String // tiny_summary
    let jsonURL: String
    let url: String?
    let topic: String?
    let articleTitle: String
    let affected: String
    let domain: String?
    let pubDate: Date?
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    let sourceAnalysis: String?
    let quality: Int?
    let summary: String?
    let criticalAnalysis: String?
    let logicalFallacies: String?
    let relationToTopic: String?
    let additionalInsights: String?
    
    // Structured engine stats
    let engineModel: String?
    let engineElapsedTime: Double?
    let engineRawStats: String?
    let engineSystemInfo: [String: Any]?
    
    // Related articles stored as structured data
    let relatedArticles: [RelatedArticle]?
    
    // New fields for R2 URL JSON payload
    let actionRecommendations: String?
    let talkingPoints: String?
    
    // Article database ID from backend
    let databaseId: Int?
}

func convertToPreparedArticle(_ input: ArticleJSON) -> PreparedArticle {
    return PreparedArticle(
        id: input.id, // Pass the string ID
        title: input.title, // tiny_title
        body: input.body, // tiny_summary
        jsonURL: input.jsonURL,
        url: input.url, // Pass the URL
        topic: input.topic,
        articleTitle: input.articleTitle, // unused
        affected: input.affected,
        domain: input.domain,
        pubDate: input.pubDate,
        sourcesQuality: input.sourcesQuality,
        argumentQuality: input.argumentQuality,
        sourceType: input.sourceType,
        sourceAnalysis: input.sourceAnalysis,
        quality: input.quality,
        summary: input.summary,
        criticalAnalysis: input.criticalAnalysis,
        logicalFallacies: input.logicalFallacies,
        relationToTopic: input.relationToTopic,
        additionalInsights: input.additionalInsights,
        
        // Pass the structured engine stats fields
        engineModel: input.engineModel,
        engineElapsedTime: input.engineElapsedTime,
        engineRawStats: input.engineRawStats,
        engineSystemInfo: input.engineSystemInfo,
        
        relatedArticles: input.relatedArticles,
        
        // Pass the new R2 URL JSON fields
        actionRecommendations: input.actionRecommendations,
        talkingPoints: input.talkingPoints,
        
        // Pass the database ID
        databaseId: input.databaseId
    )
}

func processArticleJSON(_ json: [String: Any]) -> ArticleJSON? {
    // Required fields - function returns nil if any of these are missing
    guard let title = json["tiny_title"] as? String, // Maps from "tiny_title" to local "title" variable
          let body = json["tiny_summary"] as? String, // Maps from "tiny_summary" to local "body" variable
          let jsonURL = json["json_url"] as? String // Maps from "json_url" to camelCase "jsonURL" variable
    else {
        return nil
    }

    let url = json["url"] as? String // Extract the URL but don't make it required
    // Use a local domain extraction function for cloud build compatibility
    let domain = extractDomain(from: url ?? "")

    // Include quality badge information in the first pass
    let sourcesQuality = json["sources_quality"] as? Int
    let argumentQuality = json["argument_quality"] as? Int
    let sourceType = json["source_type"] as? String

    // Extract structured engine stats fields directly from the JSON
    let engineModel = json["model"] as? String
    let engineElapsedTime = json["elapsed_time"] as? Double
    let engineRawStats = json["stats"] as? String
    let engineSystemInfo = json["system_info"] as? [String: Any]
    
    // CRITICAL FIX: Enhanced ID extraction with direct JSON dump and all keys
    AppLogger.database.debug("📊 ==== ARTICLE ID DEBUGGING ====")
    AppLogger.database.debug("🔍 EXAMINING JSON FOR ID [processArticleJSON]")
    
    if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        // Log the first 1000 chars of the JSON to see the structure - expanded for better debugging
        let sample = String(jsonString.prefix(1000)) + (jsonString.count > 1000 ? "..." : "")
        AppLogger.database.debug("JSON sample: \(sample)")
    }
    
    // Output ALL keys for comprehensive debugging
    let allKeys = Array(json.keys).sorted()
    AppLogger.database.debug("ALL JSON KEYS: \(allKeys.joined(separator: ", "))")
    
    // Check nested engine_stats JSON if present (might contain ID)
    if let engineStatsStr = json["engine_stats"] as? String,
       let engineStatsData = engineStatsStr.data(using: .utf8),
       let engineStatsDict = try? JSONSerialization.jsonObject(with: engineStatsData) as? [String: Any] {
        AppLogger.database.debug("📊 ENGINE STATS JSON CONTAINS:")
        let engineStatsKeys = Array(engineStatsDict.keys).sorted()
        AppLogger.database.debug("ENGINE STATS KEYS: \(engineStatsKeys.joined(separator: ", "))")
        
        if let engineId = engineStatsDict["id"] {
            AppLogger.database.debug("🔑 FOUND ID IN ENGINE STATS: \(String(describing: engineId)) (Type: \(type(of: engineId)))")
        }
    }
    
    // Check for all possible ID keys - expanded list
    let possibleIdKeys = ["id", "ID", "article_id", "articleId", "identifier", "external_id", 
                          "database_id", "databaseId", "db_id", "dbId", "engine_id", "engineId"]
    var foundIdKey: String? = nil
    var foundIdValue: Any? = nil
    
    AppLogger.database.debug("🔍 CHECKING ALL POSSIBLE ID KEYS...")
    for key in possibleIdKeys {
        if let value = json[key] {
            AppLogger.database.debug("✅ FOUND ID KEY: '\(key)' with value: \(String(describing: value)) (Type: \(type(of: value)))")
            foundIdKey = key
            foundIdValue = value
            break
        }
    }
    
    // Extract the database ID, handling different possible types
    var databaseId: Int? = nil
    
    // Try multiple approaches to find the ID - explicit detail logging
    AppLogger.database.debug("🔍 ATTEMPTING ID EXTRACTION...")
    
    // APPROACH 1: Direct ID in JSON
    if let intId = json["id"] as? Int {
        databaseId = intId
        AppLogger.database.debug("✅ SUCCESS! Direct Int ID found in JSON: \(intId)")
    } else if let stringId = json["id"] as? String, let intFromString = Int(stringId) {
        databaseId = intFromString
        AppLogger.database.debug("✅ SUCCESS! String ID found in JSON, converted to Int: \(intFromString)")
    } else if let doubleId = json["id"] as? Double, doubleId.truncatingRemainder(dividingBy: 1) == 0 {
        databaseId = Int(doubleId)
        AppLogger.database.debug("✅ SUCCESS! Double ID found in JSON, converted to Int: \(Int(doubleId))")
    } else if let rawId = json["id"] {
        let typeString = String(describing: type(of: rawId))
        AppLogger.database.debug("⚠️ ID found but COULDN'T CONVERT to Int: \(String(describing: rawId)) (Type: \(typeString))")
    } 
    // APPROACH 2: Alternative ID key in JSON
    else if let foundKey = foundIdKey, let value = foundIdValue {
        AppLogger.database.debug("🔄 TRYING ALTERNATIVE ID KEY: '\(foundKey)' with value: \(String(describing: value))")
        
        if let intValue = value as? Int {
            databaseId = intValue
            AppLogger.database.debug("✅ SUCCESS! Alternative Int ID: \(intValue)")
        } else if let stringValue = value as? String, let intFromString = Int(stringValue) {
            databaseId = intFromString
            AppLogger.database.debug("✅ SUCCESS! Alternative String ID converted to Int: \(intFromString)")
        } else if let doubleValue = value as? Double, doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
            databaseId = Int(doubleValue)
            AppLogger.database.debug("✅ SUCCESS! Alternative Double ID converted to Int: \(Int(doubleValue))")
        } else {
            AppLogger.database.debug("⚠️ Alternative ID couldn't be converted to Int: \(String(describing: value))")
        }
    } 
    // APPROACH 3: ID in engine_stats nested JSON
    else if let engineStatsStr = json["engine_stats"] as? String,
            let engineStatsData = engineStatsStr.data(using: .utf8),
            let engineStatsDict = try? JSONSerialization.jsonObject(with: engineStatsData) as? [String: Any] {
        
        if let engineIntId = engineStatsDict["id"] as? Int {
            databaseId = engineIntId
            AppLogger.database.debug("✅ SUCCESS! Int ID found in engine_stats: \(engineIntId)")
        } else if let engineStringId = engineStatsDict["id"] as? String, let intFromString = Int(engineStringId) {
            databaseId = intFromString
            AppLogger.database.debug("✅ SUCCESS! String ID in engine_stats, converted to Int: \(intFromString)")
        } else if let engineDoubleId = engineStatsDict["id"] as? Double, engineDoubleId.truncatingRemainder(dividingBy: 1) == 0 {
            databaseId = Int(engineDoubleId)
            AppLogger.database.debug("✅ SUCCESS! Double ID in engine_stats, converted to Int: \(Int(engineDoubleId))")
        }
    } 
    // APPROACH 4: No ID found anywhere
    else {
        AppLogger.database.debug("❌ NO database ID found in JSON under any common ID keys")
        
        // Print all keys to help diagnose
        let keys = json.keys.joined(separator: ", ")
        AppLogger.database.debug("Available JSON keys: \(keys)")
        
        // Since we couldn't find an ID, try a different approach - look in system_info
        if let systemInfo = json["system_info"] as? [String: Any] {
            AppLogger.database.debug("🔍 CHECKING SYSTEM INFO FOR ID...")
            if let systemInfoId = systemInfo["id"] as? Int {
                databaseId = systemInfoId
                AppLogger.database.debug("✅ SUCCESS! Int ID found in system_info: \(systemInfoId)")
            }
        }
        
        // Look for any field with "id" in its name as last resort
        for key in json.keys where key.lowercased().contains("id") {
            AppLogger.database.debug("🔍 POTENTIAL ID FIELD: '\(key)' with value: \(String(describing: json[key]))")
        }
    }
    
    // Extract the string ID that's separate from the numeric database ID
    // This will be used for the new id field in ArticleJSON
    var stringId = ""
    
    // Try these approaches in order of preference
    if let idValue = json["id"] {
        // Direct approach: use the string value or convert other types to string
        if let strValue = idValue as? String {
            stringId = strValue
            AppLogger.database.debug("✅ ID STRING: Using direct string value: \(strValue)")
        } else {
            // For non-string types, convert to string
            stringId = String(describing: idValue)
            AppLogger.database.debug("✅ ID STRING: Converted \(type(of: idValue)) to string: \(stringId)")
        }
    } else if let jsonURLParts = jsonURL.split(separator: "/").last?.split(separator: "."), let idPart = jsonURLParts.first {
        // Extract from JSON URL (e.g., "articles/bbc-12345.json" → "bbc-12345")
        stringId = String(idPart)
        AppLogger.database.debug("✅ ID STRING: Extracted from jsonURL: \(stringId)")
    } else {
        // Last resort: use the jsonURL as ID
        stringId = jsonURL
        AppLogger.database.debug("⚠️ ID STRING: Using jsonURL as fallback: \(stringId)")
    }
    
    // Final ID status report
    if let extractedId = databaseId {
        AppLogger.database.debug("✅ FINAL RESULT: Successfully extracted database ID: \(extractedId)")
    } else {
        AppLogger.database.debug("❌ FINAL RESULT: Failed to extract any database ID")
    }
    AppLogger.database.debug("🔑 ID STRING: Final string ID: \(stringId)")
    AppLogger.database.debug("📊 ==== END ID DEBUGGING ====")
    
        // Extract new R2 URL JSON fields (snake_case in API response)
        let actionRecommendations = json["action_recommendations"] as? String
        let talkingPoints = json["talking_points"] as? String
        
        // Comprehensive debug logging for all content fields
        AppLogger.database.debug("📊 JSON FIELD EXTRACTION REPORT:")
        let fieldsList = [
            "title": json["tiny_title"] as? String,
            "body": json["tiny_summary"] as? String,
            "summary": json["summary"] as? String,
            "critical_analysis": json["critical_analysis"] as? String,
            "logical_fallacies": json["logical_fallacies"] as? String,
            "source_analysis": json["source_analysis"] as? String,
            "relation_to_topic": json["relation_to_topic"] as? String,
            "additional_insights": json["additional_insights"] as? String,
            "action_recommendations": actionRecommendations,
            "talking_points": talkingPoints
        ]
        
        for (name, content) in fieldsList {
            if let content = content, !content.isEmpty {
                let charCount = content.count
                let preview = content.prefix(min(30, charCount)).replacingOccurrences(of: "\n", with: " ")
                AppLogger.database.debug("✅ Field '\(name)' found: \(charCount) chars, preview: \"\(preview)...\"")
            } else {
                AppLogger.database.debug("❌ Field '\(name)' is missing or empty")
            }
        }
        
        // Keep previous specific logging
        if let actionRecs = actionRecommendations, !actionRecs.isEmpty {
            AppLogger.database.debug("Found action_recommendations in JSON: \(actionRecs.prefix(50))...")
        }
        if let talkingPts = talkingPoints, !talkingPts.isEmpty {
            AppLogger.database.debug("Found talking_points in JSON: \(talkingPts.prefix(50))...")
        }
    
    // Parse similar articles if available
    var parsedRelatedArticles: [RelatedArticle]? = nil
    if let similarArticlesArray = json["similar_articles"] as? [[String: Any]], !similarArticlesArray.isEmpty {
        do {
            AppLogger.database.debug("Found \(similarArticlesArray.count) related articles in API response")
            let data = try JSONSerialization.data(withJSONObject: similarArticlesArray)
            
            // First decode using the API model that handles ISO8601 string dates from the API
            let decoder = JSONDecoder()
            let apiRelatedArticles = try decoder.decode([APIRelatedArticle].self, from: data)
            
            // Convert API models to database models with proper date conversion
            parsedRelatedArticles = apiRelatedArticles.map { $0.toRelatedArticle() }
            
            AppLogger.database.debug("Successfully parsed \(parsedRelatedArticles?.count ?? 0) related articles from API")
            
            // Verify parsed data has valid content
            if let articles = parsedRelatedArticles, !articles.isEmpty {
                // Log the first article to help with debugging
                let firstArticle = articles[0]
                AppLogger.database.debug("Sample related article - ID: \(firstArticle.id), Title: '\(firstArticle.title)', URL: '\(firstArticle.jsonURL)'")
            }
        } catch {
            AppLogger.database.error("Failed to parse similar_articles: \(error)")
        }
    }
    
    return ArticleJSON(
        id: stringId, // Use the string ID we extracted
        // Required fields from above guard statement
        title: title, // Maps from local "title" to ArticleJSON.title (originally from "tiny_title")
        body: body, // Maps from local "body" to ArticleJSON.body (originally from "tiny_summary")
        jsonURL: jsonURL, // Maps from local "jsonURL" to ArticleJSON.jsonURL (originally from "json_url")

        url: url, // Store the raw URL value

        // Optional fields with no default value (will be nil if missing)
        topic: json["topic"] as? String, // Direct mapping, same name

        // FIELD MISMATCH: "title" in JSON becomes "articleTitle" in our model
        // Note that this is different from the "title" property which comes from "tiny_title"
        articleTitle: json["title"] as? String ?? "", // Default empty string if missing

        affected: json["affected"] as? String ?? "", // Default empty string if missing

        // FIELD MISMATCH: "url" in JSON becomes "domain" in our model
        domain: domain, // Calculated above

        // FIELD MISMATCH: "pub_date" in JSON becomes "pubDate" in our model (camelCase conversion)
        // Also includes date parsing from ISO8601 string
        pubDate: (json["pub_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },

        // Fields with snake_case in JSON mapped to camelCase in model
        sourcesQuality: sourcesQuality, // "sources_quality" → "sourcesQuality"
        argumentQuality: argumentQuality, // "argument_quality" → "argumentQuality"
        sourceType: sourceType, // "source_type" → "sourceType"
        sourceAnalysis: json["source_analysis"] as? String, // "source_analysis" → "sourceAnalysis"

        // Simple direct mappings of optional fields
        quality: json["quality"] as? Int, // Direct mapping, same name
        summary: json["summary"] as? String, // Direct mapping, same name

        // Remaining snake_case to camelCase conversions
        criticalAnalysis: json["critical_analysis"] as? String, // "critical_analysis" → "criticalAnalysis"
        logicalFallacies: json["logical_fallacies"] as? String, // "logical_fallacies" → "logicalFallacies"
        relationToTopic: json["relation_to_topic"] as? String, // "relation_to_topic" → "relationToTopic"
        additionalInsights: json["additional_insights"] as? String, // "additional_insights" → "additionalInsights"
        
        // Structured engine stats fields
        engineModel: engineModel,
        engineElapsedTime: engineElapsedTime,
        engineRawStats: engineRawStats,
        engineSystemInfo: engineSystemInfo,
        
        // Add structured related articles - use our parsed result
        relatedArticles: parsedRelatedArticles,
        
        // Add new R2 URL JSON fields
        actionRecommendations: actionRecommendations,
        talkingPoints: talkingPoints,
        
        // Add database ID
        databaseId: databaseId
    )
}

// Domain extraction function duplicated directly in this file for cloud build compatibility
/// Helper function to extract the domain from a URL
///
/// This extracts the domain portion from a URL string by:
/// 1. Removing the scheme (http://, https://)
/// 2. Removing any "www." prefix
/// 3. Keeping only the domain part (removing paths)
/// 4. Trimming whitespace
///
/// - Parameter urlString: The URL to extract domain from
/// - Returns: The domain string, or nil if the URL is invalid or malformed
func extractDomain(from urlString: String) -> String? {
    // Early check for empty or nil URLs
    guard !urlString.isEmpty else {
        return nil
    }

    // Try the URL-based approach first for properly formatted URLs
    if let url = URL(string: urlString), let host = url.host {
        return host.replacingOccurrences(of: "www.", with: "")
    }

    // Fallback manual parsing for URLs that might not parse with URL initializer
    var working = urlString.lowercased()

    // Strip scheme
    if working.hasPrefix("http://") {
        working.removeFirst("http://".count)
    } else if working.hasPrefix("https://") {
        working.removeFirst("https://".count)
    }

    // Strip any leading "www."
    if working.hasPrefix("www.") {
        working.removeFirst("www.".count)
    }

    // Now split on first slash to remove any path
    if let slashIndex = working.firstIndex(of: "/") {
        working = String(working[..<slashIndex])
    }

    // Trim whitespace
    working = working.trimmingCharacters(in: .whitespacesAndNewlines)

    // Return nil if we ended up with an empty string
    return working.isEmpty ? nil : working
}
