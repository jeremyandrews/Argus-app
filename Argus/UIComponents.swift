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

        // Configure text container to show all content
        uiView.textContainer.maximumNumberOfLines = 0  // Show all lines
        uiView.textContainer.lineBreakMode = .byWordWrapping
        uiView.textContainer.widthTracksTextView = true

        // Ensure we update the layout
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize {
        // Use the container's proposed width directly
        let availableWidth = proposal.width ?? UIScreen.main.bounds.width
        
        // Set up the text container to use the full width
        uiView.textContainer.size.width = availableWidth
        uiView.textContainer.maximumNumberOfLines = 0  // Ensure unlimited lines for sizing
        uiView.textContainer.lineBreakMode = .byWordWrapping
        
        // Ensure the text view uses the correct width for calculation
        uiView.bounds.size.width = availableWidth
        uiView.layoutIfNeeded()

        // Calculate height that fits all content with no height constraint
        let fittingSize = uiView.sizeThatFits(CGSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude  // Use max height to ensure all content is measured
        ))

        return CGSize(width: availableWidth, height: fittingSize.height)
    }
}

struct NonSelectableRichTextView: UIViewRepresentable {
    let attributedString: NSAttributedString
    var lineLimit: Int? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.textAlignment = .left
        
        // CRITICAL: Set up constraints for proper sizing - FIXED PRIORITIES
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical) // Changed back to defaultLow to prevent compression
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Process the attributed string to ensure consistent font sizing
        let mutableString = NSMutableAttributedString(attributedString: attributedString)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        
        mutableString.enumerateAttributes(in: NSRange(location: 0, length: mutableString.length)) { attributes, range, _ in
            if let existingFont = attributes[.font] as? UIFont {
                let newFont = existingFont.withSize(bodyFont.pointSize)
                mutableString.addAttribute(.font, value: newFont, range: range)
                
                // Preserve other attributes
                if let paragraphStyle = attributes[.paragraphStyle] {
                    mutableString.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
                }
                if let kerning = attributes[.kern] {
                    mutableString.addAttribute(.kern, value: kerning, range: range)
                }
            } else {
                mutableString.addAttribute(.font, value: bodyFont, range: range)
            }
        }

        uiView.attributedText = mutableString
        
        // CRITICAL: Configure text container for unlimited lines - FORCE SETTINGS
        uiView.textContainer.lineBreakMode = .byWordWrapping
        uiView.textContainer.widthTracksTextView = true
        uiView.textContainer.maximumNumberOfLines = 0 // Always unlimited
        
        // Additional forced settings to ensure expansion
        uiView.translatesAutoresizingMaskIntoConstraints = true
        
        // Force immediate layout calculation
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.sizeToFit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize {
        let availableWidth = proposal.width ?? UIScreen.main.bounds.width
        
        // AGGRESSIVE FIX: Force text container to unlimited height and proper width
        uiView.textContainer.size = CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        uiView.textContainer.maximumNumberOfLines = 0 // Force unlimited
        uiView.textContainer.lineBreakMode = .byWordWrapping
        uiView.textContainer.widthTracksTextView = true
        
        // Set frame explicitly to match available width
        uiView.frame = CGRect(x: 0, y: 0, width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        
        // Force layout update
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        
        // Get the actual used rect for the text
        let usedRect = uiView.layoutManager.usedRect(for: uiView.textContainer)
        let calculatedHeight = ceil(usedRect.height)
        
        // Debug logging
        print("🔍 NonSelectableRichTextView sizing:")
        print("  - Proposed width: \(availableWidth)")
        print("  - Used rect height: \(calculatedHeight)")
        print("  - Text length: \(attributedString.length)")
        print("  - Max lines: \(uiView.textContainer.maximumNumberOfLines)")
        
        // Return size with calculated height (minimum 20 for visibility)
        let finalHeight = max(calculatedHeight, 20)
        return CGSize(width: availableWidth, height: finalHeight)
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

        // Make sure text view expands to fit content
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)

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

// ArchivedPill removed - Archive functionality has been deprecated

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
    let article: ArticleModel
    var onBadgeTap: ((String) -> Void)?
    var isDetailView: Bool = false
    @State private var scrollToSection: String? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var isLoading = false
    @State private var loadError: Error? = nil

    var body: some View {
        Group {
            // First try to use the locally stored data
            if article.sourcesQuality != nil ||
                article.argumentQuality != nil ||
                article.sourceType != nil
            {
                QualityBadges(
                    sourcesQuality: article.sourcesQuality,
                    argumentQuality: article.argumentQuality,
                    sourceType: article.sourceType,
                    scrollToSection: $scrollToSection,
                    onBadgeTap: onBadgeTap,
                    isDetailView: isDetailView
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

// MARK: - Article Position Counter Component

struct ArticlePositionCounter: View {
    let currentPosition: Int
    let totalCount: Int
    var isCompact: Bool = false
    var onBulkAction: ((BulkMarkingAction) -> Void)? = nil
    
    @State private var isLongPressing = false
    @State private var showActionDialog = false
    @State private var selectedAction: BulkMarkingAction?
    
    /// Bulk marking actions available through long press
    enum BulkMarkingAction {
        case markAllRead
        case markAllUnread
        
        var title: String {
            switch self {
            case .markAllRead: return "Mark All as Read"
            case .markAllUnread: return "Mark All as Unread"
            }
        }
        
        var icon: String {
            switch self {
            case .markAllRead: return "envelope.open"
            case .markAllUnread: return "envelope.badge"
            }
        }
        
        var confirmationTitle: String {
            switch self {
            case .markAllRead: return "Mark All Read?"
            case .markAllUnread: return "Mark All Unread?"
            }
        }
        
        var confirmationMessage: String {
            switch self {
            case .markAllRead: return "This will mark all articles in the current filtered set as read."
            case .markAllUnread: return "This will mark all articles in the current filtered set as unread."
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text("\(currentPosition)")
                .font(isCompact ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("of")
                .font(isCompact ? .caption2 : .caption)
                .foregroundColor(.secondary)
            
            Text("\(totalCount)")
                .font(isCompact ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isLongPressing ? Color.blue.opacity(0.3) : Color(UIColor.secondarySystemBackground))
                .animation(.easeInOut(duration: 0.2), value: isLongPressing)
        )
        .cornerRadius(8)
        .opacity(0.9)
        .scaleEffect(isLongPressing ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isLongPressing)
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10, perform: {
            // Long press completed - show action selection
            performHapticFeedback(.heavy)
            showActionDialog = true
        }, onPressingChanged: { isPressing in
            // Provide immediate feedback when long press starts/stops
            withAnimation(.easeInOut(duration: 0.2)) {
                isLongPressing = isPressing
            }
            
            if isPressing {
                // Haptic feedback when long press begins
                performHapticFeedback(.light)
            }
        })
        .confirmationDialog("Bulk Actions", isPresented: $showActionDialog, titleVisibility: .visible) {
            Button(BulkMarkingAction.markAllRead.title) {
                selectedAction = .markAllRead
            }
            
            Button(BulkMarkingAction.markAllUnread.title) {
                selectedAction = .markAllUnread
            }
            
            Button("Cancel", role: .cancel) {
                selectedAction = nil
            }
        } message: {
            Text("Choose an action for all \(totalCount) articles in the current filtered set.")
        }
        .alert(
            selectedAction?.confirmationTitle ?? "",
            isPresented: Binding<Bool>(
                get: { selectedAction != nil },
                set: { if !$0 { selectedAction = nil } }
            ),
            presenting: selectedAction
        ) { action in
            Button("Cancel", role: .cancel) {
                selectedAction = nil
            }
            
            Button(action.title.replacingOccurrences(of: "Mark All as ", with: "Mark "), role: .destructive) {
                onBulkAction?(action)
                selectedAction = nil
            }
        } message: { action in
            Text(action.confirmationMessage)
        }
    }
    
    /// Performs haptic feedback using iOS standard patterns
    private func performHapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let impactFeedback = UIImpactFeedbackGenerator(style: style)
        impactFeedback.impactOccurred()
    }
}

// MARK: - Optimized Article Position Counter

/// Performance-optimized version of ArticlePositionCounter that caches calculations
/// and reduces UI blocking during navigation
struct ArticlePositionCounterOptimized: View {
    let currentPosition: Int
    let totalCount: Int
    var isCompact: Bool = false
    var onBulkAction: ((ArticlePositionCounter.BulkMarkingAction) -> Void)? = nil
    
    @State private var isLongPressing = false
    @State private var showActionDialog = false
    @State private var selectedAction: ArticlePositionCounter.BulkMarkingAction?
    
    // PERFORMANCE: Cache formatted strings to avoid recalculation
    private var cachedCurrentText: String {
        return "\(currentPosition)"
    }
    
    private var cachedTotalText: String {
        return "\(totalCount)"
    }
    
    // ACCESSIBILITY: Full position counter text for UI tests
    private var fullPositionText: String {
        return "\(currentPosition) of \(totalCount)"
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text(cachedCurrentText)
                .font(isCompact ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("of")
                .font(isCompact ? .caption2 : .caption)
                .foregroundColor(.secondary)
            
            Text(cachedTotalText)
                .font(isCompact ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isLongPressing ? Color.blue.opacity(0.3) : Color(UIColor.secondarySystemBackground))
        )
        .cornerRadius(8)
        .opacity(0.9)
        .scaleEffect(isLongPressing ? 1.05 : 1.0)
        // ACCESSIBILITY: Add identifiers for UI testing
        .accessibilityIdentifier("ArticlePositionCounter")
        .accessibilityLabel(fullPositionText)
        .accessibilityValue(fullPositionText)
        // PERFORMANCE: Remove animations during navigation to prevent blocking
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10, perform: {
            // Long press completed - show action selection
            performHapticFeedback(.heavy)
            showActionDialog = true
        }, onPressingChanged: { isPressing in
            // PERFORMANCE: Simplified state updates without heavy animations
            isLongPressing = isPressing
            
            if isPressing {
                // Haptic feedback when long press begins
                performHapticFeedback(.light)
            }
        })
        .confirmationDialog("Bulk Actions", isPresented: $showActionDialog, titleVisibility: .visible) {
            Button(ArticlePositionCounter.BulkMarkingAction.markAllRead.title) {
                selectedAction = .markAllRead
            }
            
            Button(ArticlePositionCounter.BulkMarkingAction.markAllUnread.title) {
                selectedAction = .markAllUnread
            }
            
            Button("Cancel", role: .cancel) {
                selectedAction = nil
            }
        } message: {
            Text("Choose an action for all \(totalCount) articles in the current filtered set.")
        }
        .alert(
            selectedAction?.confirmationTitle ?? "",
            isPresented: Binding<Bool>(
                get: { selectedAction != nil },
                set: { if !$0 { selectedAction = nil } }
            ),
            presenting: selectedAction
        ) { action in
            Button("Cancel", role: .cancel) {
                selectedAction = nil
            }
            
            Button(action.title.replacingOccurrences(of: "Mark All as ", with: "Mark "), role: .destructive) {
                onBulkAction?(action)
                selectedAction = nil
            }
        } message: { action in
            Text(action.confirmationMessage)
        }
    }
    
    /// Performs haptic feedback using iOS standard patterns
    private func performHapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let impactFeedback = UIImpactFeedbackGenerator(style: style)
        impactFeedback.impactOccurred()
    }
}

// MARK: - Domain Source Component

struct DomainSourceView: View {
    let domain: String
    let sourceType: String?
    var onTap: (() -> Void)? = nil
    var onSourceTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Source type icon first
            if let sourceType = sourceType, !sourceType.isEmpty {
                Button(action: {
                    onSourceTap?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: sourceTypeIcon(for: sourceType))
                            .font(.footnote)
                        Text(sourceType.capitalized)
                            .font(.footnote)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(getSourceTypeColor(sourceType).opacity(0.2))
                    .foregroundColor(getSourceTypeColor(sourceType))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Domain after source type
            Text(domain)
                .font(.headline)
                .foregroundColor(.blue)
                .lineLimit(1)
                .onTapGesture {
                    onTap?()
                }
        }
    }

    private func sourceTypeIcon(for sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "press", "news":
            return "newspaper"
        case "blog":
            return "text.bubble"
        case "academic":
            return "book"
        case "government":
            return "building.columns"
        case "social media":
            return "person.2"
        default:
            return "doc.text"
        }
    }

    private func getSourceTypeColor(_ sourceType: String) -> Color {
        switch sourceType.lowercased() {
        case "press", "news":
            return .blue
        case "blog":
            return .orange
        case "academic", "research":
            return .purple
        case "gov", "government":
            return .green
        case "opinion":
            return .red
        default:
            return .gray
        }
    }
}
