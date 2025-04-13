import Foundation

struct ArticleJSON {
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
    
    let similarArticles: String?
}

struct PreparedArticle {
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
    
    let similarArticles: String?
}

func convertToPreparedArticle(_ input: ArticleJSON) -> PreparedArticle {
    return PreparedArticle(
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
        
        similarArticles: input.similarArticles
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
    
    return ArticleJSON(
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
        
        similarArticles: json["similar_articles"] as? String // "similar_articles" → "similarArticles"
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
