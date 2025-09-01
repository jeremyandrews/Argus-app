import Combine
import Foundation
import SwiftUI

// MARK: - Preset Combinations

struct TextDisplayPreset {
    let name: String
    let description: String
    let settings: TextDisplaySettings
    
    static let presets: [TextDisplayPreset] = [
        TextDisplayPreset(
            name: "Original Default",
            description: "The original app appearance",
            settings: TextDisplaySettings(
                fontFamily: .headline,
                fontSize: .defaultSize,
                fontWeight: .regular,
                backgroundColor: .systemBackground,
                fontColor: .systemPrimary
            )
        ),
        TextDisplayPreset(
            name: "Large & Clear",
            description: "Larger text for better readability",
            settings: TextDisplaySettings(
                fontFamily: .body,
                fontSize: .large,
                fontWeight: .medium,
                backgroundColor: .systemBackground,
                fontColor: .systemPrimary
            )
        ),
        TextDisplayPreset(
            name: "High Contrast",
            description: "Maximum contrast for accessibility",
            settings: TextDisplaySettings(
                fontFamily: .title,
                fontSize: .extraLarge,
                fontWeight: .bold,
                backgroundColor: .highContrastWhite,
                fontColor: .highContrastBlack
            )
        ),
        TextDisplayPreset(
            name: "Dark Mode",
            description: "Easy on the eyes in low light",
            settings: TextDisplaySettings(
                fontFamily: .body,
                fontSize: .medium,
                fontWeight: .regular,
                backgroundColor: .highContrastBlack,
                fontColor: .highContrastWhite
            )
        ),
        TextDisplayPreset(
            name: "Sepia Reading",
            description: "Warm, comfortable reading experience",
            settings: TextDisplaySettings(
                fontFamily: .serif,
                fontSize: .medium,
                fontWeight: .regular,
                backgroundColor: .cream,
                fontColor: .darkBlue
            )
        ),
        TextDisplayPreset(
            name: "Code Style",
            description: "Monospace font for technical content",
            settings: TextDisplaySettings(
                fontFamily: .monospace,
                fontSize: .defaultSize,
                fontWeight: .medium,
                backgroundColor: .lightGray,
                fontColor: .systemPrimary
            )
        ),
        TextDisplayPreset(
            name: "Cyberpunk",
            description: "Neon-inspired terminal aesthetic",
            settings: TextDisplaySettings(
                fontFamily: .monospace,
                fontSize: .medium,
                fontWeight: .medium,
                backgroundColor: .highContrastBlack,
                fontColor: .cyberpunkCyan
            )
        ),
        TextDisplayPreset(
            name: "Minimal",
            description: "Clean, Apple-inspired design",
            settings: TextDisplaySettings(
                fontFamily: .system,
                fontSize: .defaultSize,
                fontWeight: .regular,
                backgroundColor: .minimalGray,
                fontColor: .systemPrimary
            )
        ),
        TextDisplayPreset(
            name: "Academic",
            description: "Professional reading experience",
            settings: TextDisplaySettings(
                fontFamily: .serif,
                fontSize: .large,
                fontWeight: .regular,
                backgroundColor: .cream,
                fontColor: .academicBrown
            )
        ),
        TextDisplayPreset(
            name: "Accessibility Max",
            description: "Maximum accessibility features",
            settings: TextDisplaySettings(
                fontFamily: .title,
                fontSize: .maximum,
                fontWeight: .bold,
                backgroundColor: .highContrastWhite,
                fontColor: .highContrastBlack
            )
        ),
        TextDisplayPreset(
            name: "Night Reader",
            description: "Optimized for night reading",
            settings: TextDisplaySettings(
                fontFamily: .body,
                fontSize: .large,
                fontWeight: .regular,
                backgroundColor: .nightDark,
                fontColor: .nightAmber
            )
        ),
        TextDisplayPreset(
            name: "Retro Terminal",
            description: "Classic computer terminal look",
            settings: TextDisplaySettings(
                fontFamily: .monospace,
                fontSize: .medium,
                fontWeight: .regular,
                backgroundColor: .terminalBlack,
                fontColor: .terminalGreen
            )
        )
    ]
}

// MARK: - Text Display Settings Model

struct TextDisplaySettings {
    var fontFamily: FontFamily
    var fontSize: FontSize
    var fontWeight: FontWeight
    var backgroundColor: BackgroundColorOption
    var fontColor: FontColorOption
    
    static let `default` = TextDisplaySettings(
        fontFamily: .headline,  // Original default
        fontSize: .medium,      // Changed to medium as the new default
        fontWeight: .regular,
        backgroundColor: .systemBackground,
        fontColor: .systemPrimary
    )
    
    // Computed property for the complete font
    var font: Font {
        let size = fontSize.pointSize
        let weight = fontWeight.swiftUIWeight
        
        switch fontFamily {
        // Semantic fonts - always apply explicit size and weight
        case .headline:
            return .system(size: size, weight: weight, design: .default)
        case .body:
            return .system(size: size, weight: weight, design: .default)
        case .title:
            return .system(size: size, weight: weight, design: .default)
        case .subheadline:
            return .system(size: size, weight: weight, design: .default)
        case .callout:
            return .system(size: size, weight: weight, design: .default)
        case .caption:
            return .system(size: size, weight: weight, design: .default)
        
        // Custom system fonts with explicit size
        case .system:
            return .system(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .monospace:
            return .system(size: size, weight: weight, design: .monospaced)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        }
    }
    
    // Computed property for description font (slightly smaller)
    var descriptionFont: Font {
        let size = fontSize.pointSize * 0.85
        let weight: Font.Weight = fontWeight == .bold ? .medium : .regular
        
        switch fontFamily {
        // For semantic fonts, always apply explicit size and weight
        case .headline:
            return .system(size: size, weight: weight, design: .default)
        case .body:
            return .system(size: size, weight: weight, design: .default)
        case .title:
            return .system(size: size, weight: weight, design: .default)
        case .subheadline:
            return .system(size: size, weight: weight, design: .default)
        case .callout:
            return .system(size: size, weight: weight, design: .default)
        case .caption:
            return .system(size: size, weight: weight, design: .default)
        
        // Custom system fonts with explicit size
        case .system:
            return .system(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .monospace:
            return .system(size: size, weight: weight, design: .monospaced)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        }
    }
}

enum FontFamily: String, CaseIterable {
    case headline = "headline"        // Original default - semantic font
    case body = "body"               // Body text style
    case title = "title"             // Title style
    case subheadline = "subheadline" // Subheadline style
    case callout = "callout"         // Callout style
    case caption = "caption"         // Caption style
    case system = "system"           // Custom system font
    case serif = "serif"             // Serif design
    case monospace = "monospace"     // Monospace design
    case rounded = "rounded"         // Rounded design
    
    var displayName: String {
        switch self {
        case .headline: return "Headline (Original)"
        case .body: return "Body"
        case .title: return "Title"
        case .subheadline: return "Subheadline"
        case .callout: return "Callout"
        case .caption: return "Caption"
        case .system: return "System"
        case .serif: return "Serif"
        case .monospace: return "Monospace"
        case .rounded: return "Rounded"
        }
    }
    
    var isSemanticFont: Bool {
        switch self {
        case .headline, .body, .title, .subheadline, .callout, .caption:
            return true
        case .system, .serif, .monospace, .rounded:
            return false
        }
    }
}

enum FontSize: String, CaseIterable {
    case small = "small"
    case defaultSize = "default"
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"
    case maximum = "maximum"
    
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .defaultSize: return "Default"
        case .medium: return "Medium (Default)"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .maximum: return "Maximum"
        }
    }
    
    var pointSize: CGFloat {
        switch self {
        case .small: return 14
        case .defaultSize: return 17
        case .medium: return 20
        case .large: return 24
        case .extraLarge: return 28
        case .maximum: return 34
        }
    }
}

enum FontWeight: String, CaseIterable {
    case regular = "regular"
    case medium = "medium"
    case bold = "bold"
    
    var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .bold: return "Bold"
        }
    }
    
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }
}

// MARK: - Legacy FontOption for Backward Compatibility

enum FontOption: String, CaseIterable {
    case defaultSystem = "default"
    case largeText = "large"
    case extraLarge = "extraLarge"
    case accessibilityXL = "accessibilityXL"
    case accessibilityXXL = "accessibilityXXL"
    case boldStandard = "boldStandard"
    case boldLarge = "boldLarge"
    
    var displayName: String {
        switch self {
        case .defaultSystem: return "Default"
        case .largeText: return "Large Text"
        case .extraLarge: return "Extra Large"
        case .accessibilityXL: return "Accessibility XL"
        case .accessibilityXXL: return "Accessibility XXL"
        case .boldStandard: return "Bold Standard"
        case .boldLarge: return "Bold Large"
        }
    }
    
    var font: Font {
        switch self {
        case .defaultSystem:
            return .headline
        case .largeText:
            return .system(size: 18, weight: .medium)
        case .extraLarge:
            return .system(size: 22, weight: .medium)
        case .accessibilityXL:
            return .system(size: 28, weight: .medium)
        case .accessibilityXXL:
            return .system(size: 34, weight: .medium)
        case .boldStandard:
            return .system(size: 17, weight: .bold)
        case .boldLarge:
            return .system(size: 18, weight: .bold)
        }
    }
    
    var fontSize: CGFloat {
        switch self {
        case .defaultSystem, .boldStandard:
            return 17
        case .largeText, .boldLarge:
            return 18
        case .extraLarge:
            return 22
        case .accessibilityXL:
            return 28
        case .accessibilityXXL:
            return 34
        }
    }
    
    var descriptionFont: Font {
        let size = fontSize * 0.85
        let weight: Font.Weight = self == .boldStandard || self == .boldLarge ? .medium : .regular
        return .system(size: size, weight: weight)
    }
    
    // Convert legacy FontOption to new TextDisplaySettings components
    var modernEquivalent: (FontFamily, FontSize, FontWeight) {
        switch self {
        case .defaultSystem:
            return (.headline, .defaultSize, .regular)  // Map to original headline
        case .largeText:
            return (.system, .medium, .medium)
        case .extraLarge:
            return (.system, .large, .medium)
        case .accessibilityXL:
            return (.system, .extraLarge, .medium)
        case .accessibilityXXL:
            return (.system, .maximum, .medium)
        case .boldStandard:
            return (.system, .defaultSize, .bold)
        case .boldLarge:
            return (.system, .medium, .bold)
        }
    }
}

enum BackgroundColorOption: String, CaseIterable {
    case systemBackground = "systemBackground"
    case lightGray = "lightGray"
    case darkGray = "darkGray"
    case cream = "cream"
    case highContrastWhite = "highContrastWhite"
    case highContrastBlack = "highContrastBlack"
    case minimalGray = "minimalGray"
    case nightDark = "nightDark"
    case terminalBlack = "terminalBlack"
    
    var displayName: String {
        switch self {
        case .systemBackground: return "System Background"
        case .lightGray: return "Light Gray"
        case .darkGray: return "Dark Gray"
        case .cream: return "Cream/Sepia"
        case .highContrastWhite: return "High Contrast White"
        case .highContrastBlack: return "High Contrast Black"
        case .minimalGray: return "Minimal Gray"
        case .nightDark: return "Night Dark"
        case .terminalBlack: return "Terminal Black"
        }
    }
    
    var color: Color {
        switch self {
        case .systemBackground:
            return Color(.systemBackground)
        case .lightGray:
            return Color(.systemGray6)
        case .darkGray:
            return Color(.systemGray2)
        case .cream:
            return Color(red: 0.96, green: 0.93, blue: 0.88)
        case .highContrastWhite:
            return Color.white
        case .highContrastBlack:
            return Color.black
        case .minimalGray:
            return Color(.systemGray6).opacity(0.5)
        case .nightDark:
            return Color(red: 0.05, green: 0.05, blue: 0.1)
        case .terminalBlack:
            return Color(red: 0.0, green: 0.0, blue: 0.0)
        }
    }
}

enum FontColorOption: String, CaseIterable {
    case systemPrimary = "systemPrimary"
    case black = "black"
    case white = "white"
    case highContrastBlack = "highContrastBlack"
    case highContrastWhite = "highContrastWhite"
    case darkBlue = "darkBlue"
    case cyberpunkCyan = "cyberpunkCyan"
    case academicBrown = "academicBrown"
    case nightAmber = "nightAmber"
    case terminalGreen = "terminalGreen"
    
    var displayName: String {
        switch self {
        case .systemPrimary: return "System Primary"
        case .black: return "Black"
        case .white: return "White"
        case .highContrastBlack: return "High Contrast Black"
        case .highContrastWhite: return "High Contrast White"
        case .darkBlue: return "Dark Blue"
        case .cyberpunkCyan: return "Cyberpunk Cyan"
        case .academicBrown: return "Academic Brown"
        case .nightAmber: return "Night Amber"
        case .terminalGreen: return "Terminal Green"
        }
    }
    
    var color: Color {
        switch self {
        case .systemPrimary:
            return Color(.label)
        case .black:
            return Color.black
        case .white:
            return Color.white
        case .highContrastBlack:
            return Color.black
        case .highContrastWhite:
            return Color.white
        case .darkBlue:
            return Color(red: 0.0, green: 0.2, blue: 0.6)
        case .cyberpunkCyan:
            return Color.cyan
        case .academicBrown:
            return Color(red: 0.4, green: 0.2, blue: 0.1)
        case .nightAmber:
            return Color(red: 1.0, green: 0.75, blue: 0.0)
        case .terminalGreen:
            return Color(red: 0.0, green: 1.0, blue: 0.0)
        }
    }
}

// MARK: - UserDefaults Keys

// Define static keys to avoid stringly-typed programming
extension UserDefaults {
    enum Keys {
        static let sortOrder = "sortOrder"
        static let groupingStyle = "groupingStyle"
        static let showUnreadOnly = "showUnreadOnly"
        static let showBookmarkedOnly = "showBookmarkedOnly"
        static let showBadge = "showBadge"
        static let selectedTopic = "selectedTopic"
        static let useReaderMode = "useReaderMode"
        static let allowCellularSync = "allowCellularSync"
        static let autoDeleteDays = "autoDeleteDays"
        static let qualityFilter = "qualityFilter"
        
        // Text Display Settings - Legacy
        static let textDisplayFontOption = "textDisplayFontOption"
        static let textDisplayBackgroundColor = "textDisplayBackgroundColor"
        static let textDisplayFontColor = "textDisplayFontColor"
        
        // Text Display Settings - New Structure
        static let textDisplayFontFamily = "textDisplayFontFamily"
        static let textDisplayFontSize = "textDisplayFontSize"
        static let textDisplayFontWeight = "textDisplayFontWeight"
    }
}

// MARK: - UserDefaults Computed Properties

extension UserDefaults {
    @objc var sortOrder: String {
        get { string(forKey: Keys.sortOrder) ?? "newest" }
        set { set(newValue, forKey: Keys.sortOrder) }
    }

    @objc var groupingStyle: String {
        get { string(forKey: Keys.groupingStyle) ?? "date" } // Standardized default to "date"
        set { set(newValue, forKey: Keys.groupingStyle) }
    }

    @objc var showUnreadOnly: Bool {
        get { object(forKey: Keys.showUnreadOnly) == nil ? true : bool(forKey: Keys.showUnreadOnly) }
        set { set(newValue, forKey: Keys.showUnreadOnly) }
    }

    @objc var showBookmarkedOnly: Bool {
        get { bool(forKey: Keys.showBookmarkedOnly) }
        set { set(newValue, forKey: Keys.showBookmarkedOnly) }
    }

    @objc var showBadge: Bool {
        get { bool(forKey: Keys.showBadge) }
        set { set(newValue, forKey: Keys.showBadge) }
    }

    @objc var selectedTopic: String {
        get { string(forKey: Keys.selectedTopic) ?? "All" }
        set { set(newValue, forKey: Keys.selectedTopic) }
    }

    @objc var useReaderMode: Bool {
        get { bool(forKey: Keys.useReaderMode) }
        set { set(newValue, forKey: Keys.useReaderMode) }
    }

    @objc var allowCellularSync: Bool {
        get { bool(forKey: Keys.allowCellularSync) }
        set { set(newValue, forKey: Keys.allowCellularSync) }
    }

    @objc var autoDeleteDays: Int {
        get { object(forKey: Keys.autoDeleteDays) == nil ? 3 : integer(forKey: Keys.autoDeleteDays) }
        set { set(newValue, forKey: Keys.autoDeleteDays) }
    }

    @objc var qualityFilter: String {
        get { string(forKey: Keys.qualityFilter) ?? "Fair+" }
        set { set(newValue, forKey: Keys.qualityFilter) }
    }
    
    // MARK: - Text Display Settings
    var textDisplaySettings: TextDisplaySettings {
        get {
            // Check if new structure exists
            if let fontFamilyRaw = string(forKey: Keys.textDisplayFontFamily),
               let fontSizeRaw = string(forKey: Keys.textDisplayFontSize),
               let fontWeightRaw = string(forKey: Keys.textDisplayFontWeight) {
                
                // Use new structure
                let backgroundColorRaw = string(forKey: Keys.textDisplayBackgroundColor) ?? BackgroundColorOption.systemBackground.rawValue
                let fontColorRaw = string(forKey: Keys.textDisplayFontColor) ?? FontColorOption.systemPrimary.rawValue
                
                return TextDisplaySettings(
                    fontFamily: FontFamily(rawValue: fontFamilyRaw) ?? .system,
                    fontSize: FontSize(rawValue: fontSizeRaw) ?? .defaultSize,
                    fontWeight: FontWeight(rawValue: fontWeightRaw) ?? .regular,
                    backgroundColor: BackgroundColorOption(rawValue: backgroundColorRaw) ?? .systemBackground,
                    fontColor: FontColorOption(rawValue: fontColorRaw) ?? .systemPrimary
                )
            } else {
                // Migrate from legacy structure
                let fontOptionRaw = string(forKey: Keys.textDisplayFontOption) ?? FontOption.defaultSystem.rawValue
                let backgroundColorRaw = string(forKey: Keys.textDisplayBackgroundColor) ?? BackgroundColorOption.systemBackground.rawValue
                let fontColorRaw = string(forKey: Keys.textDisplayFontColor) ?? FontColorOption.systemPrimary.rawValue
                
                let legacyFontOption = FontOption(rawValue: fontOptionRaw) ?? .defaultSystem
                let (family, size, weight) = legacyFontOption.modernEquivalent
                
                let settings = TextDisplaySettings(
                    fontFamily: family,
                    fontSize: size,
                    fontWeight: weight,
                    backgroundColor: BackgroundColorOption(rawValue: backgroundColorRaw) ?? .systemBackground,
                    fontColor: FontColorOption(rawValue: fontColorRaw) ?? .systemPrimary
                )
                
                // Save in new format for future use
                self.textDisplaySettings = settings
                
                return settings
            }
        }
        set {
            // Save in new structure
            set(newValue.fontFamily.rawValue, forKey: Keys.textDisplayFontFamily)
            set(newValue.fontSize.rawValue, forKey: Keys.textDisplayFontSize)
            set(newValue.fontWeight.rawValue, forKey: Keys.textDisplayFontWeight)
            set(newValue.backgroundColor.rawValue, forKey: Keys.textDisplayBackgroundColor)
            set(newValue.fontColor.rawValue, forKey: Keys.textDisplayFontColor)
        }
    }
}

// MARK: - Publisher for UserDefaults

extension UserDefaults {
    /// Creates a publisher that emits when the specified key's value changes
    func publisher<T>(for keyPath: KeyPath<UserDefaults, T>) -> AnyPublisher<T, Never> {
        return NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { [weak self] _ in
                self?[keyPath: keyPath]
            }
            .removeDuplicates(by: { first, second in
                // Custom equality check using string representation
                // This avoids the need for T to conform to Equatable
                String(describing: first) == String(describing: second)
            })
            .eraseToAnyPublisher()
    }
}
