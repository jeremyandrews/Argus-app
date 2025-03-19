import SwiftData
import SwiftUI
import UIKit

// MARK: - Rich Text Components

struct AccessibleAttributedText: UIViewRepresentable {
    let attributedString: NSAttributedString
    var fontSize: CGFloat? = nil // Add optional font size parameter

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.attributedText = attributedString
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear

        // Important: Make sure we have zero padding
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        // Enable Dynamic Type
        textView.adjustsFontForContentSizeCategory = true

        // Make sure it expands to fit content
        textView.setContentCompressionResistancePriority(.required, for: .vertical)

        // CRITICAL: Set width explicitly to screen width minus padding
        let screenWidth = UIScreen.main.bounds.width - 32
        textView.textContainer.size.width = screenWidth

        // Disable scrolling indicators
        textView.showsHorizontalScrollIndicator = false
        textView.showsVerticalScrollIndicator = false

        return textView
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        // Apply font size adjustment if provided
        if let fontSize = fontSize {
            let mutableAttrString = NSMutableAttributedString(attributedString: attributedString)

            mutableAttrString.enumerateAttributes(in: NSRange(location: 0, length: mutableAttrString.length)) { attributes, range, _ in
                if let existingFont = attributes[.font] as? UIFont {
                    let newFont = UIFont(descriptor: existingFont.fontDescriptor, size: fontSize)
                    mutableAttrString.addAttribute(.font, value: newFont, range: range)
                } else {
                    let defaultFont = UIFont.systemFont(ofSize: fontSize)
                    mutableAttrString.addAttribute(.font, value: defaultFont, range: range)
                }
            }

            uiView.attributedText = mutableAttrString
        } else {
            uiView.attributedText = attributedString
        }

        let screenWidth = UIScreen.main.bounds.width - 32
        uiView.textContainer.size.width = screenWidth

        // Ensure we update the layout
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize {
        // If a width is provided, use that, otherwise use screen width minus padding
        let width = proposal.width ?? UIScreen.main.bounds.width - 32
        uiView.textContainer.size.width = width
        uiView.layoutIfNeeded()

        // Calculate height that fits all content
        let fittingSize = uiView.sizeThatFits(CGSize(
            width: width,
            height: UIView.layoutFittingExpandedSize.height
        ))

        return fittingSize
    }
}

struct NonSelectableRichTextView: UIViewRepresentable {
    let attributedString: NSAttributedString
    var lineLimit: Int? = nil

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false // Disable selection
        textView.backgroundColor = .clear

        // Remove default padding
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        // Enable Dynamic Type
        textView.adjustsFontForContentSizeCategory = true

        // Ensure the text always starts at the same left margin
        textView.textAlignment = .left

        // Force `UITextView` to wrap by constraining its width
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width - 40), // Ensures wrapping
        ])

        return textView
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        let mutableString = NSMutableAttributedString(attributedString: attributedString)

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        mutableString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: mutableString.length))

        uiView.attributedText = mutableString
        uiView.textAlignment = .left
        uiView.invalidateIntrinsicContentSize()
        uiView.layoutIfNeeded()
    }
}

struct RichTextView: UIViewRepresentable {
    let attributedString: NSAttributedString
    var lineLimit: Int? = nil

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear

        // Remove default padding
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        // Enable Dynamic Type
        textView.adjustsFontForContentSizeCategory = true

        // Ensure the text always starts at the same left margin
        textView.textAlignment = .left

        // Force `UITextView` to wrap by constraining its width
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width - 40), // Ensures wrapping
        ])

        return textView
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        let mutableString = NSMutableAttributedString(attributedString: attributedString)

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        mutableString.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: mutableString.length))

        uiView.attributedText = mutableString
        uiView.textAlignment = .left
        uiView.invalidateIntrinsicContentSize()
        uiView.layoutIfNeeded()
    }
}

// MARK: - Visual Label Components

struct ArchivedPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox.fill")
                .font(.caption2)
            Text("Archived")
                .font(.caption2)
                .bold()
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(uiColor: .systemOrange).opacity(0.3))
        .cornerRadius(8)
    }
}

struct TopicPill: View {
    let topic: String

    var body: some View {
        Text(topic)
            .font(.caption2)
            .bold()
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(uiColor: .systemGray5))
            .cornerRadius(8)
    }
}

// MARK: - Quality Badges Components

struct LazyLoadingQualityBadges: View {
    let notification: NotificationData
    var onBadgeTap: ((String) -> Void)?
    @State private var scrollToSection: String? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var isLoading = false
    @State private var loadError: Error? = nil

    var body: some View {
        Group {
            // First try to use the locally stored data
            if notification.sources_quality != nil ||
                notification.argument_quality != nil ||
                notification.source_type != nil
            {
                QualityBadges(
                    sourcesQuality: notification.sources_quality,
                    argumentQuality: notification.argument_quality,
                    sourceType: notification.source_type,
                    scrollToSection: $scrollToSection,
                    onBadgeTap: onBadgeTap
                )
            } else if isLoading {
                // Show loading indicator
                ProgressView()
                    .frame(height: 20)
            } else if loadError != nil {
                // Show error state
                Text("Failed to load content")
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                // No data available yet, but don't eagerly load - just show placeholder
                // Only fetch when explicitly needed (user interaction)
                Color.clear.frame(height: 20)
            }
        }
        .onChange(of: scrollToSection) { _, newSection in
            if let section = newSection, let onBadgeTap = onBadgeTap {
                onBadgeTap(section)
                scrollToSection = nil
            }
        }
    }
}

// MARK: - Utility Extensions

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

extension String {
    var nilIfEmpty: String? {
        return isEmpty ? nil : self
    }
}

extension Date {
    var dayOnly: Date {
        Calendar.current.startOfDay(for: self)
    }
}
