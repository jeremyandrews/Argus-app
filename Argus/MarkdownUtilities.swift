import Foundation
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
        switch self {
        case .title: notification.title_blob = data
        case .body: notification.body_blob = data
        case .summary: notification.summary_blob = data
        case .criticalAnalysis: notification.critical_analysis_blob = data
        case .logicalFallacies: notification.logical_fallacies_blob = data
        case .sourceAnalysis: notification.source_analysis_blob = data
        case .relationToTopic: notification.relation_to_topic_blob = data
        case .additionalInsights: notification.additional_insights_blob = data
        }
    }
}

/// Converts any given markdown string into an NSAttributedString with Dynamic Type.
func markdownToAttributedString(
    _ markdown: String?,
    textStyle: String,
    customFontSize: CGFloat? = nil
) -> NSAttributedString? {
    guard let markdown = markdown, !markdown.isEmpty else { return nil }

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

    // Create a mutable copy to add accessibility attributes
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
    let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")

    mutableAttributedString.addAttribute(
        textStyleKey,
        value: textStyle,
        range: NSRange(location: 0, length: mutableAttributedString.length)
    )

    return mutableAttributedString
}

/// Primary function to get an attributed string for any field
/// This is the main function you should use everywhere in the app
func getAttributedString(
    for field: RichTextField,
    from notification: NotificationData,
    createIfMissing: Bool = true,
    customFontSize: CGFloat? = nil
) -> NSAttributedString? {
    // First try loading from blob if available
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
            return mutable
        }

        return attributedString
    }

    // If no blob or failed to load, create fresh if requested
    if createIfMissing {
        let markdownText = field.getMarkdownText(from: notification)
        let attributedString = markdownToAttributedString(
            markdownText,
            textStyle: field.textStyle,
            customFontSize: customFontSize
        )

        // Store for future use if we successfully created an attributed string
        if let attributedString = attributedString {
            _ = saveAttributedString(attributedString, for: field, in: notification)
        }

        return attributedString
    }

    return nil
}

/// Save an attributed string as a blob
func saveAttributedString(
    _ attributedString: NSAttributedString,
    for field: RichTextField,
    in notification: NotificationData
) -> Bool {
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: attributedString,
        requiringSecureCoding: false
    ) else {
        return false
    }

    field.setBlob(data, on: notification)
    return true
}

/// Create attributed strings for all fields in a notification
func createAllAttributedStrings(for notification: NotificationData) async {
    await Task.detached(priority: .utility) {
        // Process all fields consistently
        let fields: [RichTextField] = [
            .title, .body, .summary, .criticalAnalysis,
            .logicalFallacies, .sourceAnalysis, .relationToTopic, .additionalInsights,
        ]

        for field in fields {
            // Only convert if blob doesn't exist yet
            if field.getBlob(from: notification) == nil,
               let text = field.getMarkdownText(from: notification),
               let attributedString = markdownToAttributedString(text, textStyle: field.textStyle)
            {
                _ = saveAttributedString(attributedString, for: field, in: notification)
            }
        }
    }.value
}
