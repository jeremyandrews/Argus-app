import SwiftUI

struct QualityBadges: View {
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    @Binding var scrollToSection: String?
    var onBadgeTap: ((String) -> Void)?
    var isDetailView: Bool = false

    var body: some View {
        // Source type has been moved up to be with the domain, so just show Proof, Logic, and Context
        HStack(spacing: 8) {
            // 1. Sources Quality (e.g., "Proof: Strong")
            if let sourcesQuality = sourcesQuality {
                QualityBadge(
                    label: "Proof: \(getQualityLabel(sourcesQuality))",
                    color: getQualityColor(sourcesQuality),
                    iconName: "checkmark.seal.fill"
                )
                .onTapGesture {
                    if let onBadgeTap = onBadgeTap {
                        onBadgeTap("Critical Analysis")
                    } else {
                        scrollToSection = "Critical Analysis"
                    }
                }
            }

            // 2. Argument Quality (e.g., "Logic: Fair")
            if let argumentQuality = argumentQuality {
                QualityBadge(
                    label: "Logic: \(getQualityLabel(argumentQuality))",
                    color: getQualityColor(argumentQuality),
                    iconName: "brain.fill"
                )
                .onTapGesture {
                    if let onBadgeTap = onBadgeTap {
                        onBadgeTap("Logical Fallacies")
                    } else {
                        scrollToSection = "Logical Fallacies"
                    }
                }
            }

            // 3. Context badge - always show in detail view, conditionally in list view
            if isDetailView || (sourcesQuality == nil || argumentQuality == nil) {
                QualityBadge(
                    label: "Context",
                    color: .purple,
                    iconName: "questionmark.circle.fill"
                )
                .onTapGesture {
                    if let onBadgeTap = onBadgeTap {
                        onBadgeTap("Context & Perspective")
                    } else {
                        scrollToSection = "Context & Perspective"
                    }
                }
            }
        }
        .frame(height: 28) // Fixed height to ensure badges don't expand vertically
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

    private func getQualityLabel(_ quality: Int) -> String {
        switch quality {
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Strong"
        default: return "Unknown"
        }
    }

    private func getQualityColor(_ quality: Int) -> Color {
        switch quality {
        case 1: return .red
        case 2: return .orange
        case 3: return .green
        case 4: return .blue
        default: return .gray
        }
    }
}

struct QualityBadge: View {
    let label: String
    let color: Color
    let iconName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1) // Prevent text wrapping
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .foregroundColor(color)
        .cornerRadius(8)
        .fixedSize(horizontal: true, vertical: false) // Critical fix: make the badge width accommodate content
    }
}
