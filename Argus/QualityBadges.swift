import SwiftUI

struct QualityBadges: View {
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    @Binding var scrollToSection: String?
    var onBadgeTap: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let sourcesQuality = sourcesQuality {
                let (text, color) = qualityText(sourcesQuality)
                Text("Proof: \(text)")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15))
                    .foregroundColor(color)
                    .cornerRadius(4)
                    .onTapGesture {
                        if let onBadgeTap = onBadgeTap {
                            onBadgeTap("Critical Analysis")
                        } else {
                            scrollToSection = "Critical Analysis"
                        }
                    }
            }

            if let argumentQuality = argumentQuality {
                let (text, color) = qualityText(argumentQuality)
                Text("Logic: \(text)")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .foregroundColor(color)
                    .cornerRadius(4)
                    .onTapGesture {
                        if let onBadgeTap = onBadgeTap {
                            onBadgeTap("Logical Fallacies")
                        } else {
                            scrollToSection = "Logical Fallacies"
                        }
                    }
            }

            if let sourceType = sourceType, sourceType != "none" {
                let (text, color) = sourceTypeText(sourceType)
                Text(text)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .foregroundColor(color)
                    .cornerRadius(4)
                    .onTapGesture {
                        if let onBadgeTap = onBadgeTap {
                            onBadgeTap("Source Analysis")
                        } else {
                            scrollToSection = "Source Analysis"
                        }
                    }
            }
        }
        .padding(.horizontal, 4)
    }

    private func sourceTypeText(_ type: String?) -> (String, Color) {
        guard let type = type else { return ("", .clear) }
        switch type {
        case "official":
            return ("Official", .blue)
        case "academic", "press", "corporate", "nonprofit":
            return (
                type.capitalized,
                Color(uiColor: .systemGray)
            )
        case "questionable":
            return ("Unreliable", Color(uiColor: .systemGray))
        default:
            return ("", .clear)
        }
    }

    private func qualityText(_ quality: Int?) -> (String, Color) {
        guard let quality = quality else { return ("", .clear) }
        switch quality {
        case 1:
            return ("Weak", Color(red: 0.8, green: 0.2, blue: 0.2))
        case 2:
            return ("Fair", Color(red: 0.8, green: 0.6, blue: 0.0))
        case 3:
            return ("Strong", Color(red: 0.2, green: 0.6, blue: 0.2))
        default:
            return ("", .clear)
        }
    }

    private func expandSourcesSection(quality _: Int) {
        scrollToSection = "Critical Analysis"
    }

    private func expandLogicSection(quality _: Int) {
        scrollToSection = "Logical Fallacies"
    }

    private func expandSourceTypeSection(type _: String) {
        scrollToSection = "Source Analysis"
    }
}
