import Foundation
import SwiftyMarkdown
import UIKit

/// Converts any given markdown string into an NSAttributedString with Dynamic Type.
/// textStyle should be something like "UIFontTextStyleBody" or "UIFontTextStyleHeadline".
func markdownToAccessibleAttributedString(
    _ markdown: String?,
    textStyle: String
) -> NSAttributedString? {
    guard let markdown = markdown, !markdown.isEmpty else { return nil }

    let swiftyMarkdown = SwiftyMarkdown(string: markdown)

    // 1. Get the preferred font for the specified text style (supports Dynamic Type).
    let bodyFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle(rawValue: textStyle))
    swiftyMarkdown.body.fontName = bodyFont.fontName
    swiftyMarkdown.body.fontSize = bodyFont.pointSize

    // 2. Style headings with appropriate Dynamic Type text styles
    let h1Font = UIFont.preferredFont(forTextStyle: .title1)
    swiftyMarkdown.h1.fontName = h1Font.fontName
    swiftyMarkdown.h1.fontSize = h1Font.pointSize

    let h2Font = UIFont.preferredFont(forTextStyle: .title2)
    swiftyMarkdown.h2.fontName = h2Font.fontName
    swiftyMarkdown.h2.fontSize = h2Font.pointSize

    let h3Font = UIFont.preferredFont(forTextStyle: .title3)
    swiftyMarkdown.h3.fontName = h3Font.fontName
    swiftyMarkdown.h3.fontSize = h3Font.pointSize

    // 3. Other styling
    swiftyMarkdown.link.color = .systemBlue

    // 4. Get bold and italic versions of the body font if possible
    if let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) {
        let boldFont = UIFont(descriptor: boldDescriptor, size: 0)
        swiftyMarkdown.bold.fontName = boldFont.fontName
    } else {
        swiftyMarkdown.bold.fontName = ".SFUI-Bold"
    }

    if let italicDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
        let italicFont = UIFont(descriptor: italicDescriptor, size: 0)
        swiftyMarkdown.italic.fontName = italicFont.fontName
    } else {
        swiftyMarkdown.italic.fontName = ".SFUI-Italic"
    }

    // 5. Generate the initial attributed string from SwiftyMarkdown
    let attributedString = swiftyMarkdown.attributedString()

    // 6. Create a mutable copy to add accessibility attributes
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
    let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")

    mutableAttributedString.addAttribute(
        textStyleKey,
        value: textStyle,
        range: NSRange(location: 0, length: mutableAttributedString.length)
    )

    return mutableAttributedString
}

/// A convenience wrapper that converts ArticleJSON fields (`title`, `body`) into archived Data blobs.
func makeAttributedStrings(from article: ArticleJSON) async -> [String: Data] {
    // Offload to a background task
    return await Task.detached(priority: .utility) { () -> [String: Data] in
        var results: [String: Data] = [:]

        // Title
        if let attributedTitle = markdownToAccessibleAttributedString(
            article.title,
            textStyle: "UIFontTextStyleHeadline"
        ),
            let titleData = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedTitle,
                requiringSecureCoding: false
            )
        {
            results["title"] = titleData
        }

        // Body
        if let attributedBody = markdownToAccessibleAttributedString(
            article.body,
            textStyle: "UIFontTextStyleBody"
        ),
            let bodyData = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedBody,
                requiringSecureCoding: false
            )
        {
            results["body"] = bodyData
        }

        return results
    }.value
}

/// Another convenience wrapper for NotificationData fields (`summary`, `critical_analysis`, etc.).
/// This duplicates the "markdown → NSAttributedString" logic, but does so for each field in NotificationData.
func makeAttributedStrings(from notification: NotificationData) async -> [String: Data] {
    return await Task.detached(priority: .utility) { () -> [String: Data] in
        var results: [String: Data] = [:]

        // Title
        if let attributedTitle = markdownToAccessibleAttributedString(
            notification.title,
            textStyle: "UIFontTextStyleHeadline"
        ),
            let titleData = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedTitle,
                requiringSecureCoding: false
            )
        {
            results["title"] = titleData
        }

        // Body
        if let attributedBody = markdownToAccessibleAttributedString(
            notification.body,
            textStyle: "UIFontTextStyleBody"
        ),
            let bodyData = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedBody,
                requiringSecureCoding: false
            )
        {
            results["body"] = bodyData
        }

        // Summary
        if let summaryText = notification.summary,
           let attributedSummary = markdownToAccessibleAttributedString(
               summaryText,
               textStyle: "UIFontTextStyleBody"
           ),
           let summaryData = try? NSKeyedArchiver.archivedData(
               withRootObject: attributedSummary,
               requiringSecureCoding: false
           )
        {
            results["summary"] = summaryData
        }

        // Critical Analysis
        if let criticalText = notification.critical_analysis,
           let attributedCrit = markdownToAccessibleAttributedString(
               criticalText,
               textStyle: "UIFontTextStyleBody"
           ),
           let critData = try? NSKeyedArchiver.archivedData(
               withRootObject: attributedCrit,
               requiringSecureCoding: false
           )
        {
            results["critical_analysis"] = critData
        }

        // etc. for logicalFallacies, sourceAnalysis, relationToTopic, additionalInsights...

        return results
    }.value
}

// Add this enum to MarkdownUtilities.swift
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

/// Gets rich text data from a NotificationData object
func getRichText(from notification: NotificationData, for field: RichTextField) -> NSAttributedString? {
    guard let data = getBlobData(from: notification, for: field) else { return nil }

    do {
        if let attributedString = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: data
        ) {
            return attributedString
        }
        return nil
    } catch {
        print("Error unarchiving rich text for \(field): \(error.localizedDescription)")
        return nil
    }
}

/// Gets blob data from a NotificationData object
func getBlobData(from notification: NotificationData, for field: RichTextField) -> Data? {
    switch field {
    case .title:
        return notification.title_blob
    case .body:
        return notification.body_blob
    case .summary:
        return notification.summary_blob
    case .criticalAnalysis:
        return notification.critical_analysis_blob
    case .logicalFallacies:
        return notification.logical_fallacies_blob
    case .sourceAnalysis:
        return notification.source_analysis_blob
    case .relationToTopic:
        return notification.relation_to_topic_blob
    case .additionalInsights:
        return notification.additional_insights_blob
    }
}

/// Converts a specific field from NotificationData into an NSAttributedString
func markdownFieldToAttributedString(
    notification: NotificationData,
    field: RichTextField
) -> NSAttributedString? {
    // First check if we have a stored blob
    if let storedAttributedString = getRichText(from: notification, for: field) {
        return storedAttributedString
    }

    // Otherwise, convert the markdown text directly
    let textStyle: String
    let markdownText: String?

    switch field {
    case .title:
        textStyle = "UIFontTextStyleHeadline"
        markdownText = notification.title
    case .body:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.body
    case .summary:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.summary
    case .criticalAnalysis:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.critical_analysis
    case .logicalFallacies:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.logical_fallacies
    case .sourceAnalysis:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.source_analysis
    case .relationToTopic:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.relation_to_topic
    case .additionalInsights:
        textStyle = "UIFontTextStyleBody"
        markdownText = notification.additional_insights
    }

    return markdownToAccessibleAttributedString(markdownText, textStyle: textStyle)
}

/// Saves an attributed string to the appropriate blob field in a NotificationData object
func saveAttributedString(
    _ attributedString: NSAttributedString,
    to notification: NotificationData,
    for field: RichTextField
) -> Bool {
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: attributedString,
        requiringSecureCoding: false
    ) else {
        return false
    }

    // Store the data in the appropriate blob field
    switch field {
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

    return true
}
