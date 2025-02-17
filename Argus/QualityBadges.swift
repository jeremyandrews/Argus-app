import SwiftUI

struct QualityBadges: View {
    let sourcesQuality: Int?
    let argumentQuality: Int?
    let sourceType: String?
    @Binding var scrollToSection: String?

    private func qualityText(_ quality: Int?) -> (String, Color) {
        guard let quality = quality else { return ("", .clear) }
        switch quality {
        case 1: return ("Weak", .red)
        case 2: return ("Fair", .yellow)
        case 3: return ("Strong", .green)
        default: return ("", .clear)
        }
    }

    private func sourceTypeText(_ type: String?) -> (String, Color) {
        guard let type = type else { return ("", .clear) }
        switch type {
        case "official": return ("Official", .blue)
        case "academic": return ("Academic", .purple)
        case "press": return ("Press", .green)
        case "corporate": return ("Corp", .orange)
        case "nonprofit": return ("NGO", .teal)
        case "questionable": return ("Quest", .red)
        default: return ("", .clear)
        }
    }

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
                        scrollToSection = "Critical Analysis"
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
                        scrollToSection = "Logical Fallacies"
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
                        scrollToSection = "Source Analysis"
                    }
            }
        }
        .padding(.horizontal, 4)
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
