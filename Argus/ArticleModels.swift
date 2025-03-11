import Foundation

struct ArticleJSON {
    let title: String // tiny_title
    let body: String // tiny_summary
    let jsonURL: String
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
    let engineStats: String?
    let similarArticles: String?
}

struct PreparedArticle {
    let title: String // tiny_title
    let body: String // tiny_summary
    let jsonURL: String
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
    let engineStats: String?
    let similarArticles: String?
}

func convertToPreparedArticle(_ input: ArticleJSON) -> PreparedArticle {
    return PreparedArticle(
        title: input.title, // tiny_title
        body: input.body, // tiny_summary
        jsonURL: input.jsonURL,
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
        engineStats: input.engineStats,
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

    let url = json["url"] as? String ?? ""
    let domain = extractDomain(from: url)

    // Include quality badge information in the first pass
    let sourcesQuality = json["sources_quality"] as? Int
    let argumentQuality = json["argument_quality"] as? Int
    let sourceType = json["source_type"] as? String

    return ArticleJSON(
        // Required fields from above guard statement
        title: title, // Maps from local "title" to ArticleJSON.title (originally from "tiny_title")
        body: body, // Maps from local "body" to ArticleJSON.body (originally from "tiny_summary")
        jsonURL: jsonURL, // Maps from local "jsonURL" to ArticleJSON.jsonURL (originally from "json_url")

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
        engineStats: json["engine_stats"] as? String, // "engine_stats" → "engineStats"
        similarArticles: json["similar_articles"] as? String // "similar_articles" → "similarArticles"
    )
}

func extractDomain(from urlString: String) -> String {
    // 1) Remove scheme (e.g. http://, https://)
    // 2) Remove leading "www."
    // 3) Return the rest (the domain)
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

    // Trim whitespace, just in case
    return working.trimmingCharacters(in: .whitespacesAndNewlines)
}
