import Foundation
import SwiftyMarkdown
import UIKit

func makeAttributedString(from articleJSON: ArticleJSON) async -> [String: Data] {
    // Generate rich text blobs - detached in background
    let richTextBlobs = await Task.detached(priority: .utility) { () -> [String: Data] in
        // Rich text conversion code remains the same...
        var result = [String: Data]()

        // Create function to convert markdown to NSAttributedString with Dynamic Type support
        func markdownToAccessibleAttributedString(_ markdown: String?, textStyle: String) -> NSAttributedString? {
            guard let markdown = markdown, !markdown.isEmpty else { return nil }

            let swiftyMarkdown = SwiftyMarkdown(string: markdown)

            // Get the preferred font for the specified text style (supports Dynamic Type)
            let bodyFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle(rawValue: textStyle))
            swiftyMarkdown.body.fontName = bodyFont.fontName
            swiftyMarkdown.body.fontSize = bodyFont.pointSize

            // Style headings with appropriate Dynamic Type text styles
            let h1Font = UIFont.preferredFont(forTextStyle: .title1)
            swiftyMarkdown.h1.fontName = h1Font.fontName
            swiftyMarkdown.h1.fontSize = h1Font.pointSize

            let h2Font = UIFont.preferredFont(forTextStyle: .title2)
            swiftyMarkdown.h2.fontName = h2Font.fontName
            swiftyMarkdown.h2.fontSize = h2Font.pointSize

            let h3Font = UIFont.preferredFont(forTextStyle: .title3)
            swiftyMarkdown.h3.fontName = h3Font.fontName
            swiftyMarkdown.h3.fontSize = h3Font.pointSize

            // Other styling
            swiftyMarkdown.link.color = .systemBlue

            // Get bold and italic versions of the body font if possible
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

            // Get the initial attributed string from SwiftyMarkdown
            let attributedString = swiftyMarkdown.attributedString()

            // Create a mutable copy
            let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)

            // Add accessibility trait to indicate the text style
            let textStyleKey = NSAttributedString.Key(rawValue: "NSAccessibilityTextStyleStringAttribute")
            mutableAttributedString.addAttribute(
                textStyleKey,
                value: textStyle,
                range: NSRange(location: 0, length: mutableAttributedString.length)
            )

            return mutableAttributedString
        }

        // Process title with headline style
        if let attributedTitle = markdownToAccessibleAttributedString(articleJSON.title, textStyle: "UIFontTextStyleHeadline"),
           let titleData = try? NSKeyedArchiver.archivedData(withRootObject: attributedTitle, requiringSecureCoding: false)
        {
            result["title"] = titleData
        }

        // Process body with body style
        if let attributedBody = markdownToAccessibleAttributedString(articleJSON.body, textStyle: "UIFontTextStyleBody"),
           let bodyData = try? NSKeyedArchiver.archivedData(withRootObject: attributedBody, requiringSecureCoding: false)
        {
            result["body"] = bodyData
        }

        return result
    }.value

    return richTextBlobs
}
