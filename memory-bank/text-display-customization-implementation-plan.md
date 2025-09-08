# Text Display Customization Implementation Plan

## Overview
Adding comprehensive text display customization to Argus Settings, allowing users to adjust font type, size, background color, and font color with a live preview system.

## Requirements Analysis
- **Font Options**: At least 6 different options with accessibility focus
- **Live Preview**: Real-time preview of settings changes  
- **Persistent Settings**: Settings saved across app sessions
- **Universal Application**: Applied consistently throughout app
- **iOS 18+ Standard Methods**: Using native SwiftUI and iOS patterns
- **Accessibility Focus**: Options for aging eyes with larger, clearer text
- **Clean Implementation**: No unnecessary complexity or abstraction

## Font Options Design (7 total - exceeds requirement)
1. **Default** - System font, medium weight, 16pt (current)
2. **Large Text** - System font, medium weight, 18pt 
3. **Extra Large** - System font, medium weight, 22pt
4. **Accessibility XL** - System font, medium weight, 28pt
5. **Accessibility XXL** - System font, medium weight, 34pt
6. **Bold Standard** - System font, bold weight, 16pt
7. **Bold Large** - System font, bold weight, 18pt

## Color Options Design
### Background Colors (6 options)
- System Background (default)
- Light Gray
- Dark Gray  
- Cream/Sepia
- High Contrast White
- High Contrast Black

### Font Colors (6 options)
- System Primary (default)
- Black
- White
- High Contrast Black
- High Contrast White
- Dark Blue

## Implementation Strategy

### Phase 1: Settings Infrastructure
1. Add text display settings model to UserDefaultsExtensions
2. Create enums for font, background, and color options
3. Add UserDefaults computed properties for persistence

### Phase 2: Settings UI
1. Add new "Text Display" section to SettingsView
2. Implement live preview area with sample text
3. Create option selection UI with visual indicators
4. Add real-time preview updates

### Phase 3: Application Integration
1. Apply settings to NewsView article list
2. Apply settings to NewsDetailView
3. Apply settings to RelatedArticlesComponents
4. Add settings refresh mechanisms

### Phase 4: Testing & Polish
1. Test all combinations
2. Verify accessibility compliance
3. Ensure no code duplication
4. Performance optimization
5. Final compilation verification

## File Modifications
- `UserDefaultsExtensions.swift` - Add text display settings model and persistence
- `SettingsView.swift` - Add text display customization UI section
- `NewsView.swift` - Apply text display settings to article list
- `NewsDetailView.swift` - Apply text display settings to article detail view
- `RelatedArticlesComponents.swift` - Apply settings for consistency

## Technical Implementation Details
- Use `@AppStorage` pattern via UserDefaults extensions
- Enum-based type-safe options
- Computed properties for font calculations
- SwiftUI standard color and font APIs
- Performance-optimized state management

## Success Criteria
- ✅ 6+ distinct font options (targeting 7)
- ✅ Live preview functionality
- ✅ Persistent settings across sessions
- ✅ Applied consistently throughout app
- ✅ No compilation errors or warnings
- ✅ Accessibility compliant
- ✅ Clean, maintainable code
- ✅ Standard iOS development patterns
