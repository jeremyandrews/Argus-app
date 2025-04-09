import Foundation
import SwiftData
import SwiftyMarkdown
import UIKit

// Field types we can process
enum RichTextField {
    case title
    case body
    case summary
    case criticalAnalysis
    case logicalFallacies
    case sourceAnalysis
    case relationToTopic
    case additionalInsights
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

    // Gets the markdown text for this field from an object
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

    // Gets the blob data for this field from an object
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

    // Sets the blob data for this field on an object
    func setBlob(_ data: Data?, on notification: NotificationData) {
        // Just set the blob directly, without forcing DispatchQueue.main
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

/// Primary function to get an attributed string for any field
/// This is the main function you should use everywhere in the app
@MainActor
func getAttributedString(
    for field: RichTextField,
    from notification: NotificationData,
    createIfMissing: Bool = true,
    customFontSize: CGFloat? = nil,
    completion: ((NSAttributedString?) -> Void)? = nil
) -> NSAttributedString? {
    // First check if the source text exists for this field
    let markdownText = field.getMarkdownText(from: notification)
    guard let unwrappedText = markdownText, !unwrappedText.isEmpty else {
        completion?(nil)
        return nil
    }

    // Try to use existing blob data if available
    if let blobData = field.getBlob(from: notification),
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
        // Now always on main thread thanks to @MainActor
        let attributedString = markdownToAttributedString(
            unwrappedText,
            textStyle: field.textStyle,
            customFontSize: customFontSize
        )
        if let attributedString = attributedString {
            do {
                try notification.setRichText(attributedString, for: field, saveContext: true)
            } catch {
                print("Error saving rich text for \(String(describing: field)): \(error)")
            }
            completion?(attributedString)
            return attributedString
        }
    }

    completion?(nil)
    return nil
}

/// Save an attributed string as a blob
func saveAttributedString(
    _ attributedString: NSAttributedString,
    for field: RichTextField,
    in notification: NotificationData
) -> Bool {
    // Use the model's built-in method
    do {
        // Ensure we're on the main thread
        if Thread.isMainThread {
            try notification.setRichText(attributedString, for: field, saveContext: true)
        } else {
            // Dispatch to main thread
            DispatchQueue.main.async {
                do {
                    try notification.setRichText(attributedString, for: field, saveContext: true)
                } catch {
                    AppLogger.database.error("Error saving rich text on background thread: \(error)")
                }
            }
        }
        return true
    } catch {
        AppLogger.database.error("Error saving rich text: \(error)")
        return false
    }
}

@Model
class NotificationData {
    @Attribute var id: UUID = UUID()
    @Attribute var date: Date = Date()
    @Attribute var title: String = ""
    @Attribute var body: String = ""
    @Attribute var isViewed: Bool = false
    @Attribute var isBookmarked: Bool = false
    @Attribute var isArchived: Bool = false // Archive functionality removed - keeping property for backward compatibility
    // @Attribute(.unique) var json_url: String = ""
    @Attribute var json_url: String = ""
    @Attribute var article_url: String? = nil
    @Attribute var topic: String?
    @Attribute var article_title: String = ""
    @Attribute var affected: String = ""
    @Attribute var domain: String?
    @Attribute var pub_date: Date?

    // New fields for analytics and content
    @Attribute var sources_quality: Int?
    @Attribute var argument_quality: Int?
    @Attribute var source_type: String?
    @Attribute var quality: Int?

    // Text fields for source content
    @Attribute var summary: String?
    @Attribute var critical_analysis: String?
    @Attribute var logical_fallacies: String?
    @Attribute var source_analysis: String?
    @Attribute var relation_to_topic: String?
    @Attribute var additional_insights: String?

    // BLOB fields for rich text versions
    @Attribute var title_blob: Data?
    @Attribute var body_blob: Data?
    @Attribute var summary_blob: Data?
    @Attribute var critical_analysis_blob: Data?
    @Attribute var logical_fallacies_blob: Data?
    @Attribute var source_analysis_blob: Data?
    @Attribute var relation_to_topic_blob: Data?
    @Attribute var additional_insights_blob: Data?

    // Engine statistics and similar articles stored as JSON strings
    @Attribute var engine_stats: String?
    @Attribute var similar_articles: String?

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

    // Convenience methods to convert between NSAttributedString and Data

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

        // Save the context if requested and we can access it
        if saveContext, let modelContext = modelContext {
            try modelContext.save()
        }
    }

    private func getBlobData(for field: RichTextField) -> Data? {
        switch field {
        case .title:
            return title_blob
        case .body:
            return body_blob
        case .summary:
            return summary_blob
        case .criticalAnalysis:
            return critical_analysis_blob
        case .logicalFallacies:
            return logical_fallacies_blob
        case .sourceAnalysis:
            return source_analysis_blob
        case .relationToTopic:
            return relation_to_topic_blob
        case .additionalInsights:
            return additional_insights_blob
        }
    }

    /// Get blobs for a specific field - used by the ViewModel
    /// - Parameter field: The rich text field to get blobs for
    /// - Returns: An array of blob data, or nil if no blobs are found
    func getBlobsForField(_ field: RichTextField) -> [Data]? {
        if let blob = field.getBlob(from: self), !blob.isEmpty {
            AppLogger.database.debug("📦 Found blob for \(String(describing: field)) (\(blob.count) bytes)")
            return [blob]
        }
        AppLogger.database.debug("⚠️ No blob found for \(String(describing: field))")
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

        AppLogger.database.debug("🔍 VERIFYING ALL BLOBS for article \(id):")

        var allValid = true
        for field in fields {
            if let blob = field.getBlob(from: self) {
                do {
                    if let _ = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSAttributedString.self,
                        from: blob
                    ) {
                        AppLogger.database.debug("✅ \(String(describing: field)) blob is valid (\(blob.count) bytes)")
                    } else {
                        AppLogger.database.error("❌ \(String(describing: field)) blob unarchived to nil")
                        allValid = false
                    }
                } catch {
                    AppLogger.database.error("❌ \(String(describing: field)) blob failed to unarchive: \(error)")
                    allValid = false
                }
            } else {
                // Missing blob is not an error - the content may not have been converted yet
                AppLogger.database.debug("⚪️ No blob exists for \(String(describing: field))")
            }
        }

        return allValid
    }

    /// Regenerates all blobs for this article
    /// - Parameter force: Whether to force regeneration even if blobs exist
    /// - Returns: Number of blobs regenerated
    @MainActor
    func regenerateAllBlobs(force: Bool = false) -> Int {
        let fields: [RichTextField] = [
            .title, .body, .summary, .criticalAnalysis,
            .logicalFallacies, .sourceAnalysis, .relationToTopic,
            .additionalInsights,
        ]

        var regeneratedCount = 0

        for field in fields {
            // Skip if blob exists and we're not forcing regeneration
            if !force && field.getBlob(from: self) != nil {
                continue
            }

            // Skip if no source text
            guard let text = field.getMarkdownText(from: self), !text.isEmpty else {
                continue
            }

            // Generate attributed string
            if let attributedString = markdownToAttributedString(text, textStyle: field.textStyle) {
                do {
                    try setRichText(attributedString, for: field, saveContext: false)
                    regeneratedCount += 1
                } catch {
                    AppLogger.database.error("❌ Failed to regenerate blob for \(String(describing: field)): \(error)")
                }
            }
        }

        // Save once at the end instead of for each field
        if regeneratedCount > 0, let context = modelContext {
            do {
                try context.save()
                AppLogger.database.debug("✅ Saved \(regeneratedCount) regenerated blobs")
            } catch {
                AppLogger.database.error("❌ Failed to save regenerated blobs: \(error)")
            }
        }

        return regeneratedCount
    }
}

// Extension to provide computed property for effective date
extension NotificationData {
    var effectiveDate: Date {
        return pub_date ?? date
    }
}

@Model
class SeenArticle {
    @Attribute var id: UUID = UUID()
    @Attribute var json_url: String = ""
    @Attribute var date: Date = Date()

    init(id: UUID, json_url: String, date: Date) {
        self.id = id
        self.json_url = json_url
        self.date = date
    }
}
