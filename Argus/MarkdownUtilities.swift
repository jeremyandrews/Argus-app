import Foundation
import SwiftData
import SwiftyMarkdown
import UIKit

// Field types we can process
enum RichTextField: String, CaseIterable {
    case title
    case body
    case summary
    case criticalAnalysis
    case logicalFallacies
    case sourceAnalysis
    case relationToTopic
    case additionalInsights
}

// Centralized section naming system to ensure consistency
public enum SectionNaming {
    /// Converts a section name to the corresponding RichTextField enum
    static func fieldForSection(_ section: String) -> RichTextField {
        switch section {
        case "Summary": return .summary
        case "Critical Analysis": return .criticalAnalysis
        case "Logical Fallacies": return .logicalFallacies
        case "Source Analysis": return .sourceAnalysis
        case "Relevance": return .relationToTopic
        case "Context & Perspective": return .additionalInsights
        default: return .body
        }
    }

    /// Converts a RichTextField enum to a human-readable section name
    static func nameForField(_ field: RichTextField) -> String {
        switch field {
        case .title: return "Title"
        case .body: return "Body"
        case .summary: return "Summary"
        case .criticalAnalysis: return "Critical Analysis"
        case .logicalFallacies: return "Logical Fallacies"
        case .sourceAnalysis: return "Source Analysis"
        case .relationToTopic: return "Relevance"
        case .additionalInsights: return "Context & Perspective"
        }
    }

    /// Normalizes a section name to a database field key
    static func normalizedKey(_ section: String) -> String {
        switch section {
        case "Summary": return "summary"
        case "Critical Analysis": return "criticalAnalysis"
        case "Logical Fallacies": return "logicalFallacies"
        case "Source Analysis": return "sourceAnalysis"
        case "Relevance": return "relationToTopic"
        case "Context & Perspective": return "additionalInsights"
        default: return section.lowercased()
        }
    }
}

// Defines text configuration for each field type
extension RichTextField {
    var textStyle: String {
        switch self {
        case .title:
            return "UIFontTextStyleHeadline"
        case .body, .summary, .criticalAnalysis,
             .logicalFallacies, .sourceAnalysis,
             .relationToTopic, .additionalInsights:
            return "UIFontTextStyleBody"
        }
    }

    // MARK: - ArticleModel Extensions (Primary Usage)

    // Gets the markdown text for this field from an ArticleModel
    func getMarkdownText(from article: ArticleModel) -> String? {
        switch self {
        case .title: return article.title
        case .body: return article.body
        case .summary: return article.summary
        case .criticalAnalysis: return article.criticalAnalysis
        case .logicalFallacies: return article.logicalFallacies
        case .sourceAnalysis: return article.sourceAnalysis
        case .relationToTopic: return article.relationToTopic
        case .additionalInsights: return article.additionalInsights
        }
    }

    // Gets the blob data for this field from an ArticleModel
    func getBlob(from article: ArticleModel) -> Data? {
        switch self {
        case .title: return article.titleBlob
        case .body: return article.bodyBlob
        case .summary: return article.summaryBlob
        case .criticalAnalysis: return article.criticalAnalysisBlob
        case .logicalFallacies: return article.logicalFallaciesBlob
        case .sourceAnalysis: return article.sourceAnalysisBlob
        case .relationToTopic: return article.relationToTopicBlob
        case .additionalInsights: return article.additionalInsightsBlob
        }
    }

    // Sets the blob data for this field on an ArticleModel
    func setBlob(_ data: Data?, on article: ArticleModel) {
        switch self {
        case .title:
            article.titleBlob = data
        case .body:
            article.bodyBlob = data
        case .summary:
            article.summaryBlob = data
        case .criticalAnalysis:
            article.criticalAnalysisBlob = data
        case .logicalFallacies:
            article.logicalFallaciesBlob = data
        case .sourceAnalysis:
            article.sourceAnalysisBlob = data
        case .relationToTopic:
            article.relationToTopicBlob = data
        case .additionalInsights:
            article.additionalInsightsBlob = data
        }
    }

    // MARK: - Legacy NotificationData Extensions (Only For Migration)

    // Gets the markdown text for this field from a NotificationData
    func getMarkdownText(from notification: NotificationData) -> String? {
        switch self {
        case .title: return notification.title
        case .body: return notification.body
        case .summary: return notification.summary
        case .criticalAnalysis: return notification.critical_analysis
        case .logicalFallacies: return notification.logical_fallacies
        case .sourceAnalysis: return notification.source_analysis
        case .relationToTopic: return notification.relation_to_topic
        case .additionalInsights: return notification.additional_insights
        }
    }

    // Gets the blob data for this field from a NotificationData
    func getBlob(from notification: NotificationData) -> Data? {
        switch self {
        case .title: return notification.title_blob
        case .body: return notification.body_blob
        case .summary: return notification.summary_blob
        case .criticalAnalysis: return notification.critical_analysis_blob
        case .logicalFallacies: return notification.logical_fallacies_blob
        case .sourceAnalysis: return notification.source_analysis_blob
        case .relationToTopic: return notification.relation_to_topic_blob
        case .additionalInsights: return notification.additional_insights_blob
        }
    }

    // Sets the blob data for this field on a NotificationData
    func setBlob(_ data: Data?, on notification: NotificationData) {
        switch self {
        case .title:
            notification.title_blob = data
        case .body:
            notification.body_blob = data
        case .summary:
            notification.summary_blob = data
        case .criticalAnalysis:
            notification.critical_analysis_blob = data
        case .logicalFallacies:
            notification.logical_fallacies_blob = data
        case .sourceAnalysis:
            notification.source_analysis_blob = data
        case .relationToTopic:
            notification.relation_to_topic_blob = data
        case .additionalInsights:
            notification.additional_insights_blob = data
        }
    }
}

/// Converts any given markdown string into an NSAttributedString with Dynamic Type.
func markdownToAttributedString(
    _ markdown: String?,
    textStyle: String,
    customFontSize: CGFloat? = nil
) -> NSAttributedString? {
    guard let markdown = markdown, !markdown.isEmpty else {
        AppLogger.database.debug("❌ Empty or nil markdown content provided to converter")
        return nil
    }

    // Log start of conversion for diagnostics
    let startTime = Date()
    let contentPreview = markdown.count > 50 ? String(markdown.prefix(50)) + "..." : markdown
    AppLogger.database.debug("⚙️ Converting markdown to attributed string (length: \(markdown.count), preview: \"\(contentPreview)\")")

    // Special case: malformed markdown or empty string with just whitespace
    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        AppLogger.database.debug("⚠️ Markdown content contains only whitespace")
        // Return simple attributed string instead of nil
        return NSAttributedString(string: markdown)
    }

    // Create SwiftyMarkdown instance
    let swiftyMarkdown = SwiftyMarkdown(string: markdown)

    // Get the preferred font for the text style (supports Dynamic Type)
    let bodyFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle(rawValue: textStyle))
    swiftyMarkdown.body.fontName = bodyFont.fontName

    // Use custom font size if provided, otherwise use default with a slight boost
    if let customFontSize = customFontSize {
        swiftyMarkdown.body.fontSize = customFontSize
    } else {
        // Apply a slight size boost (10%) to improve readability
        swiftyMarkdown.body.fontSize = bodyFont.pointSize * 1.1
    }

    // Style headings with appropriate Dynamic Type text styles
    let h1Font = UIFont.preferredFont(forTextStyle: .title1)
    swiftyMarkdown.h1.fontName = h1Font.fontName
    swiftyMarkdown.h1.fontSize = customFontSize ?? (h1Font.pointSize * 1.1)

    let h2Font = UIFont.preferredFont(forTextStyle: .title2)
    swiftyMarkdown.h2.fontName = h2Font.fontName
    swiftyMarkdown.h2.fontSize = customFontSize ?? (h2Font.pointSize * 1.1)

    let h3Font = UIFont.preferredFont(forTextStyle: .title3)
    swiftyMarkdown.h3.fontName = h3Font.fontName
    swiftyMarkdown.h3.fontSize = customFontSize ?? (h3Font.pointSize * 1.1)

    // Other styling
    swiftyMarkdown.link.color = .systemBlue

    // Get bold and italic versions of the body font if possible
    if let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) {
        let boldFont = UIFont(descriptor: boldDescriptor, size: 0)
        swiftyMarkdown.bold.fontName = boldFont.fontName
        swiftyMarkdown.bold.fontSize = customFontSize ?? (bodyFont.pointSize * 1.1)
    } else {
        swiftyMarkdown.bold.fontName = ".SFUI-Bold"
        swiftyMarkdown.bold.fontSize = customFontSize ?? (bodyFont.pointSize * 1.1)
    }

    if let italicDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
        let italicFont = UIFont(descriptor: italicDescriptor, size: 0)
        swiftyMarkdown.italic.fontName = italicFont.fontName
        swiftyMarkdown.italic.fontSize = customFontSize ?? (bodyFont.pointSize * 1.1)
    } else {
        swiftyMarkdown.italic.fontName = ".SFUI-Italic"
        swiftyMarkdown.italic.fontSize = customFontSize ?? (bodyFont.pointSize * 1.1)
    }

    // Generate the attributed string from SwiftyMarkdown
    let attributedString = swiftyMarkdown.attributedString()

    // Validate the attributed string has content
    if attributedString.length == 0 {
        AppLogger.database.warning("⚠️ SwiftyMarkdown generated empty attributed string")
        // Return plain text as fallback
        return NSAttributedString(string: markdown)
    }

    // Create a mutable copy to add accessibility attributes
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
    let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")

    mutableAttributedString.addAttribute(
        textStyleKey,
        value: textStyle,
        range: NSRange(location: 0, length: mutableAttributedString.length)
    )

    // Log completion time for performance monitoring
    let conversionTime = Date().timeIntervalSince(startTime)
    AppLogger.database.debug("✅ Markdown conversion completed in \(String(format: "%.4f", conversionTime))s (result length: \(mutableAttributedString.length))")

    return mutableAttributedString
}

// MARK: - Primary ArticleModel Functions

/// Primary function to get an attributed string for any field from an ArticleModel
/// This is the main function to use throughout the app
@MainActor
func getAttributedString(
    for field: RichTextField,
    from article: ArticleModel,
    createIfMissing: Bool = true,
    customFontSize: CGFloat? = nil,
    completion: ((NSAttributedString?) -> Void)? = nil
) -> NSAttributedString? {
    return getAttributedStringInternal(for: field, from: article, createIfMissing: createIfMissing, customFontSize: customFontSize, completion: completion)
}

/// Overload to handle NotificationData objects
/// This function allows getAttributedString to work with legacy NotificationData objects
@MainActor
func getAttributedString(
    for field: RichTextField,
    from notification: NotificationData,
    createIfMissing: Bool = true,
    customFontSize: CGFloat? = nil,
    completion: ((NSAttributedString?) -> Void)? = nil
) -> NSAttributedString? {
    return getAttributedStringInternal(for: field, from: notification, createIfMissing: createIfMissing, customFontSize: customFontSize, completion: completion)
}

/// Internal implementation that handles both ArticleModel and NotificationData
@MainActor
private func getAttributedStringInternal<T>(
    for field: RichTextField,
    from source: T,
    createIfMissing: Bool = true,
    customFontSize: CGFloat? = nil,
    completion: ((NSAttributedString?) -> Void)? = nil
) -> NSAttributedString? {
    // Get the markdown text using the appropriate extension method
    let markdownText: String?
    if let article = source as? ArticleModel {
        markdownText = field.getMarkdownText(from: article)
    } else if let notification = source as? NotificationData {
        markdownText = field.getMarkdownText(from: notification)
    } else {
        AppLogger.database.error("❌ Invalid source type for getAttributedStringInternal")
        completion?(nil)
        return nil
    }

    guard let unwrappedText = markdownText, !unwrappedText.isEmpty else {
        completion?(nil)
        return nil
    }

    // Try to use existing blob data if available
    var blobData: Data?
    if let article = source as? ArticleModel {
        blobData = field.getBlob(from: article)
    } else if let notification = source as? NotificationData {
        blobData = field.getBlob(from: notification)
    }

    if let blobData = blobData,
       let attributedString = try? NSKeyedUnarchiver.unarchivedObject(
           ofClass: NSAttributedString.self,
           from: blobData
       )
    {
        // If we have a custom font size, adjust the stored attributed string
        if let fontSize = customFontSize {
            let mutable = NSMutableAttributedString(attributedString: attributedString)
            mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { font, range, _ in
                if let originalFont = font as? UIFont {
                    let newFont = originalFont.withSize(fontSize)
                    mutable.addAttribute(.font, value: newFont, range: range)
                }
            }
            completion?(mutable)
            return mutable
        }

        completion?(attributedString)
        return attributedString
    }

    // If no blob or failed to load, create fresh if requested
    if createIfMissing {
        // Generate the attributed string
        let attributedString = markdownToAttributedString(
            unwrappedText,
            textStyle: field.textStyle,
            customFontSize: customFontSize
        )

        if let attributedString = attributedString {
            // Archive to data
            do {
                let blobData = try NSKeyedArchiver.archivedData(
                    withRootObject: attributedString,
                    requiringSecureCoding: false
                )

                // Set the blob on the appropriate source object
                if let article = source as? ArticleModel {
                    field.setBlob(blobData, on: article)

                    // Save the context if possible
                    if let context = article.modelContext {
                        do {
                            try context.save()
                            AppLogger.database.debug("✅ Saved blob for \(String(describing: field)) to ArticleModel (\(blobData.count) bytes)")
                        } catch {
                            AppLogger.database.error("❌ Failed to save context for \(String(describing: field)) blob: \(error)")
                        }
                    } else {
                        AppLogger.database.warning("⚠️ ArticleModel has no context to save blob for \(String(describing: field))")
                    }
                } else if let notification = source as? NotificationData {
                    field.setBlob(blobData, on: notification)
                    AppLogger.database.debug("✅ Set blob for \(String(describing: field)) on NotificationData")
                }
            } catch {
                AppLogger.database.error("❌ Failed to create blob data for \(String(describing: field)): \(error)")
            }

            completion?(attributedString)
            return attributedString
        }
    }

    completion?(nil)
    return nil
}

// MARK: - Helper functions for ArticleModel

/// Save an attributed string as a blob to an ArticleModel
@MainActor
func saveAttributedString(
    _ attributedString: NSAttributedString,
    for field: RichTextField,
    in article: ArticleModel
) -> Bool {
    // Archive to data
    do {
        let blobData = try NSKeyedArchiver.archivedData(
            withRootObject: attributedString,
            requiringSecureCoding: false
        )

        // Set the blob on the article model
        field.setBlob(blobData, on: article)

        // Save the context if possible
        if let context = article.modelContext {
            try context.save()
            AppLogger.database.debug("✅ Saved blob for \(String(describing: field)) to ArticleModel (\(blobData.count) bytes)")
            return true
        } else {
            AppLogger.database.warning("⚠️ ArticleModel has no context to save blob for \(String(describing: field))")
            return false
        }
    } catch {
        AppLogger.database.error("❌ Failed to save blob for \(String(describing: field)): \(error)")
        return false
    }
}

/// Get blobs for a specific field in an ArticleModel
/// - Parameters:
///   - field: The rich text field to get blobs for
///   - article: The ArticleModel to get blobs from
/// - Returns: An array of blob data, or nil if no blobs are found
func getBlobsForField(_ field: RichTextField, from article: ArticleModel) -> [Data]? {
    let fieldName = SectionNaming.nameForField(field)
    let normalizedKey = SectionNaming.normalizedKey(fieldName)

    if let blob = field.getBlob(from: article), !blob.isEmpty {
        AppLogger.database.debug("📦 Found blob for \(fieldName) (normalized key: \(normalizedKey)) (\(blob.count) bytes)")
        return [blob]
    }
    AppLogger.database.debug("⚠️ No blob found for \(fieldName) (normalized key: \(normalizedKey))")
    return nil
}

/// Verifies all blobs in an ArticleModel and logs their status
/// - Parameter article: The ArticleModel to verify blobs for
/// - Returns: True if all blobs are valid, false otherwise
func verifyAllBlobs(in article: ArticleModel) -> Bool {
    let fields: [RichTextField] = [
        .title, .body, .summary, .criticalAnalysis,
        .logicalFallacies, .sourceAnalysis, .relationToTopic,
        .additionalInsights,
    ]

    AppLogger.database.debug("🔍 VERIFYING ALL BLOBS for article \(article.id):")

    var allValid = true
    for field in fields {
        // Use human-readable name for better logs
        let fieldName = SectionNaming.nameForField(field)
        let normalizedKey = SectionNaming.normalizedKey(fieldName)

        if let blob = field.getBlob(from: article) {
            do {
                if let _ = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSAttributedString.self,
                    from: blob
                ) {
                    AppLogger.database.debug("✅ \(fieldName) blob is valid (\(blob.count) bytes)")
                } else {
                    AppLogger.database.error("❌ \(fieldName) blob unarchived to nil")
                    allValid = false
                }
            } catch {
                AppLogger.database.error("❌ \(fieldName) blob failed to unarchive: \(error)")
                allValid = false
            }
        } else {
            // Missing blob is not an error - the content may not have been converted yet
            AppLogger.database.debug("⚪️ No blob exists for \(fieldName) (normalized key: \(normalizedKey))")
        }
    }

    return allValid
}

/// Regenerates all blobs for an ArticleModel
/// - Parameters:
///   - article: The ArticleModel to regenerate blobs for
///   - force: Whether to force regeneration even if blobs exist
/// - Returns: Number of blobs regenerated
@MainActor
func regenerateAllBlobs(for article: ArticleModel, force: Bool = false) -> Int {
    let fields: [RichTextField] = [
        .title, .body, .summary, .criticalAnalysis,
        .logicalFallacies, .sourceAnalysis, .relationToTopic,
        .additionalInsights,
    ]

    var regeneratedCount = 0

    for field in fields {
        // Skip if blob exists and we're not forcing regeneration
        if !force && field.getBlob(from: article) != nil {
            continue
        }

        // Skip if no source text
        guard let text = field.getMarkdownText(from: article), !text.isEmpty else {
            continue
        }

        // Generate attributed string
        if let attributedString = markdownToAttributedString(text, textStyle: field.textStyle) {
            if saveAttributedString(attributedString, for: field, in: article) {
                regeneratedCount += 1
            }
        }
    }

    if regeneratedCount > 0 {
        AppLogger.database.debug("✅ Regenerated \(regeneratedCount) blobs for article \(article.id)")
    }

    return regeneratedCount
}

// MARK: - Legacy NotificationData Implementation for Migration ONLY

/// Legacy class that should ONLY be used during migration
/// This is NOT a SwiftData model anymore - do not use it for persistence
class NotificationData {
    var id: UUID = .init()
    var date: Date = .init()
    var title: String = ""
    var body: String = ""
    var isViewed: Bool = false
    var isBookmarked: Bool = false
    var isArchived: Bool = false // Archive functionality removed - keeping property for backward compatibility
    var json_url: String = ""
    var article_url: String?
    var topic: String?
    var article_title: String = ""
    var affected: String = ""
    var domain: String?
    var pub_date: Date?

    // New fields for analytics and content
    var sources_quality: Int?
    var argument_quality: Int?
    var source_type: String?
    var quality: Int?

    // Text fields for source content
    var summary: String?
    var critical_analysis: String?
    var logical_fallacies: String?
    var source_analysis: String?
    var relation_to_topic: String?
    var additional_insights: String?

    // BLOB fields for rich text versions
    var title_blob: Data?
    var body_blob: Data?
    var summary_blob: Data?
    var critical_analysis_blob: Data?
    var logical_fallacies_blob: Data?
    var source_analysis_blob: Data?
    var relation_to_topic_blob: Data?
    var additional_insights_blob: Data?

    // Engine statistics and similar articles stored as JSON strings
    var engine_stats: String?
    var similar_articles: String?

    // Now a regular property for backward compatibility during migration only
    var modelContext: Any?

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        body: String,
        json_url: String,
        article_url: String? = nil,
        topic: String? = nil,
        article_title: String,
        affected: String,
        domain: String? = nil,
        pub_date: Date? = nil,
        isViewed: Bool = false,
        isBookmarked: Bool = false,
        isArchived: Bool = false,
        sources_quality: Int? = nil,
        argument_quality: Int? = nil,
        source_type: String? = nil,
        source_analysis: String? = nil,
        quality: Int? = nil,
        summary: String? = nil,
        critical_analysis: String? = nil,
        logical_fallacies: String? = nil,
        relation_to_topic: String? = nil,
        additional_insights: String? = nil,
        title_blob: Data? = nil,
        body_blob: Data? = nil,
        summary_blob: Data? = nil,
        critical_analysis_blob: Data? = nil,
        logical_fallacies_blob: Data? = nil,
        source_analysis_blob: Data? = nil,
        relation_to_topic_blob: Data? = nil,
        additional_insights_blob: Data? = nil,
        engine_stats: String? = nil,
        similar_articles: String? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
        self.json_url = json_url
        self.article_url = article_url
        self.topic = topic
        self.article_title = article_title
        self.affected = affected
        self.domain = domain
        self.pub_date = pub_date
        self.isViewed = isViewed
        self.isBookmarked = isBookmarked
        self.isArchived = isArchived
        self.sources_quality = sources_quality
        self.argument_quality = argument_quality
        self.source_type = source_type
        self.source_analysis = source_analysis
        self.quality = quality
        self.summary = summary
        self.critical_analysis = critical_analysis
        self.logical_fallacies = logical_fallacies
        self.relation_to_topic = relation_to_topic
        self.additional_insights = additional_insights
        self.title_blob = title_blob
        self.body_blob = body_blob
        self.summary_blob = summary_blob
        self.critical_analysis_blob = critical_analysis_blob
        self.logical_fallacies_blob = logical_fallacies_blob
        self.source_analysis_blob = source_analysis_blob
        self.relation_to_topic_blob = relation_to_topic_blob
        self.additional_insights_blob = additional_insights_blob
        self.engine_stats = engine_stats
        self.similar_articles = similar_articles
    }

    // Legacy convenience methods for compatibility during migration ONLY

    func setRichText(_ attributedString: NSAttributedString, for field: RichTextField,
                     saveContext: Bool = true) throws
    {
        let data = try NSKeyedArchiver.archivedData(withRootObject: attributedString, requiringSecureCoding: false)

        switch field {
        case .title:
            title_blob = data
        case .body:
            body_blob = data
        case .summary:
            summary_blob = data
        case .criticalAnalysis:
            critical_analysis_blob = data
        case .logicalFallacies:
            logical_fallacies_blob = data
        case .sourceAnalysis:
            source_analysis_blob = data
        case .relationToTopic:
            relation_to_topic_blob = data
        case .additionalInsights:
            additional_insights_blob = data
        }

        // No context saving anymore since this is not a SwiftData model
        if saveContext {
            // Log that we're not actually saving
            AppLogger.database.debug("ℹ️ NotificationData setRichText called with saveContext=true, but this is not a SwiftData model anymore")
        }
    }

    /// Get blobs for a specific field - streamlined for direct field access
    /// - Parameter field: The rich text field to get blobs for
    /// - Returns: An array of blob data, or nil if no blobs are found
    func getBlobsForField(_ field: RichTextField) -> [Data]? {
        let fieldName = SectionNaming.nameForField(field)
        let normalizedKey = SectionNaming.normalizedKey(fieldName)

        if let blob = field.getBlob(from: self), !blob.isEmpty {
            AppLogger.database.debug("📦 Found blob for \(fieldName) (normalized key: \(normalizedKey)) (\(blob.count) bytes)")
            return [blob]
        }
        AppLogger.database.debug("⚠️ No blob found for \(fieldName) (normalized key: \(normalizedKey))")
        return nil
    }

    /// Verifies all blobs in this article and logs their status
    /// - Returns: True if all blobs are valid, false otherwise
    func verifyAllBlobs() -> Bool {
        let fields: [RichTextField] = [
            .title, .body, .summary, .criticalAnalysis,
            .logicalFallacies, .sourceAnalysis, .relationToTopic,
            .additionalInsights,
        ]

        AppLogger.database.debug("🔍 VERIFYING ALL BLOBS for article \(self.id):")

        var allValid = true
        for field in fields {
            // Use human-readable name for better logs
            let fieldName = SectionNaming.nameForField(field)
            let normalizedKey = SectionNaming.normalizedKey(fieldName)

            if let blob = field.getBlob(from: self) {
                do {
                    if let _ = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: blob
                    ) {
                        AppLogger.database.debug("✅ \(fieldName) blob is valid (\(blob.count) bytes)")
                    } else {
                        AppLogger.database.error("❌ \(fieldName) blob unarchived to nil")
                        allValid = false
                    }
                } catch {
                    AppLogger.database.error("❌ \(fieldName) blob failed to unarchive: \(error)")
                    allValid = false
                }
            } else {
                // Missing blob is not an error - the content may not have been converted yet
                AppLogger.database.debug("⚪️ No blob exists for \(fieldName) (normalized key: \(normalizedKey))")
            }
        }

        return allValid
    }
}

// Legacy extension for migration compatibility only
extension NotificationData {
    var effectiveDate: Date {
        return pub_date ?? date
    }

    /// Creates a NotificationData instance from an ArticleModel
    /// Used for migration and compatibility with legacy code
    static func from(articleModel: ArticleModel) -> NotificationData {
        let notification = NotificationData(
            id: articleModel.id,
            date: articleModel.addedDate,
            title: articleModel.title,
            body: articleModel.body,
            json_url: articleModel.jsonURL,
            article_url: articleModel.url,
            topic: articleModel.topic,
            article_title: articleModel.articleTitle,
            affected: articleModel.affected,
            domain: articleModel.domain,
            pub_date: articleModel.publishDate,
            isViewed: articleModel.isViewed,
            isBookmarked: articleModel.isBookmarked,
            isArchived: false, // Archive functionality removed
            sources_quality: articleModel.sourcesQuality,
            argument_quality: articleModel.argumentQuality,
            source_type: articleModel.sourceType,
            source_analysis: articleModel.sourceAnalysis,
            quality: articleModel.quality,
            summary: articleModel.summary,
            critical_analysis: articleModel.criticalAnalysis,
            logical_fallacies: articleModel.logicalFallacies,
            relation_to_topic: articleModel.relationToTopic,
            additional_insights: articleModel.additionalInsights,
            title_blob: articleModel.titleBlob,
            body_blob: articleModel.bodyBlob,
            summary_blob: articleModel.summaryBlob,
            critical_analysis_blob: articleModel.criticalAnalysisBlob,
            logical_fallacies_blob: articleModel.logicalFallaciesBlob,
            source_analysis_blob: articleModel.sourceAnalysisBlob,
            relation_to_topic_blob: articleModel.relationToTopicBlob,
            additional_insights_blob: articleModel.additionalInsightsBlob,
            engine_stats: articleModel.engine_stats,
            similar_articles: articleModel.similar_articles
        )

        return notification
    }
}

// Legacy SeenArticle definition now moved to MigrationService
