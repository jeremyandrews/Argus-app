import SwiftData
import SwiftUI
import UIKit

// MARK: - Rich Text Components

struct AccessibleAttributedText: UIViewRepresentable {
    let attributedString: NSAttributedString

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.attributedText = attributedString
        textView.isEditable = false
        textView.isSelectable = false // Disable selection
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear

        // Remove default padding
        textView.textContainerInset = UIEdgeInsets.zero
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
        uiView.attributedText = attributedString

        // Ensure it updates its layout
        uiView.layoutIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize {
        // Set width constraint if available
        if let width = proposal.width {
            uiView.textContainer.size.width = width
            uiView.layoutIfNeeded()
        }

        // Get the natural size after layout
        let fittingSize = uiView.sizeThatFits(CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
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
    @State private var hasFetchedMetadata = false

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
        .onAppear {
            // Check if we've already tried to fetch metadata for this notification
            if !hasFetchedMetadata &&
                notification.sources_quality == nil &&
                notification.argument_quality == nil &&
                notification.source_type == nil
            {
                // Query database for metadata instead of making a network request
                fetchLocalMetadataOnly()
            }
        }
    }

    private func fetchLocalMetadataOnly() {
        // Mark that we've tried to fetch metadata to avoid repeated attempts
        hasFetchedMetadata = true

        // Only query the local database to see if we have any metadata already stored
        Task {
            // Check if there's any metadata in the database for this notification ID
            // without making a network request
            do {
                // Query the database for this notification by ID to ensure we have the latest data
                // Using string-based predicate to avoid macro expansion issues
                let descriptor = FetchDescriptor<NotificationData>()

                // Perform a simple fetch and filter manually
                let allNotifications = try modelContext.fetch(descriptor)
                if let updatedNotification = allNotifications.first(where: { $0.id == notification.id }) {
                    // If database has metadata that our current reference doesn't, update our view
                    await MainActor.run {
                        if updatedNotification.sources_quality != nil ||
                            updatedNotification.argument_quality != nil ||
                            updatedNotification.source_type != nil
                        {
                            // No need to trigger loadFullContent as the database already has the metadata
                            // Just force a view refresh with the latest data
                        }
                    }
                }
            } catch {
                print("Error fetching metadata from database: \(error)")
            }
        }
    }

    // This method should now only be called when explicitly needed (e.g., user taps on content)
    private func loadFullContent() {
        guard !isLoading else { return }

        isLoading = true
        Task {
            do {
                // Use SyncManager to fetch and update the notification
                _ = try await SyncManager.fetchFullContentIfNeeded(for: notification)

                // Update UI state
                await MainActor.run {
                    isLoading = false
                    loadError = nil
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadError = error
                    print("Failed to load content for \(notification.json_url): \(error)")
                }
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
