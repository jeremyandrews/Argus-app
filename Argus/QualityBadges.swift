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
                    .background(color.opacity(0.2))
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
        case "official": return ("Official", .blue)
        case "academic": return ("Academic", Color(uiColor: .systemGray3))
        case "press": return ("Media", Color(uiColor: .systemGray3))
        case "corporate": return ("Business", Color(uiColor: .systemGray3))
        case "nonprofit": return ("NGO", Color(uiColor: .systemGray3))
        case "questionable": return ("Unreliable", Color(uiColor: .systemGray3))
        default: return ("", .clear)
        }
    }

    private func qualityText(_ quality: Int?) -> (String, Color) {
        guard let quality = quality else { return ("", .clear) }
        switch quality {
        case 1: return ("Weak", Color.red.opacity(0.7))
        case 2: return ("Fair", Color.yellow.opacity(0.7))
        case 3: return ("Strong", Color.green.opacity(0.6))
        default: return ("", .clear)
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
