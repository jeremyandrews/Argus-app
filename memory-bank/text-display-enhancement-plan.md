# Text Display Enhancement Plan

## Current Issues Identified
1. **Missing smaller font sizes** - Current smallest is "Default" at 17pt, no options below that
2. **No font family variations** - Only size/weight variations, no different typefaces
3. **Sprawling UI** - Takes up significant vertical space with radio buttons and grids

## Proposed Solution: Compact Multi-Category Interface

### UI Design Strategy
Replace the current sprawling interface with a more compact design using:

1. **Segmented Controls** for main categories
2. **Dropdown/Picker style** for options within categories
3. **Tabbed interface** within the Text Display section
4. **Consolidated preview** that updates for all changes

### Enhanced Font Options

#### Font Families (New)
- **System** (SF Pro) - Default iOS font
- **Serif** (New York) - iOS serif font for readability
- **Monospace** (SF Mono) - Fixed-width font
- **Rounded** (SF Pro Rounded) - Friendly rounded variant

#### Font Sizes (Enhanced)
- **Small** (14pt) - Compact reading
- **Default** (17pt) - Current default
- **Medium** (20pt) - Slightly larger
- **Large** (24pt) - Large text
- **Extra Large** (28pt) - Accessibility
- **Maximum** (34pt) - Maximum accessibility

#### Font Weights
- **Regular** - Standard weight
- **Medium** - Slightly bolder
- **Bold** - Bold text

### Compact UI Structure

```
Text Display
├── Preview Area (always visible)
├── Font Settings (Picker/Segmented)
│   ├── Family: System | Serif | Mono | Rounded
│   ├── Size: Small | Default | Medium | Large | XL | Max
│   └── Weight: Regular | Medium | Bold
├── Colors (Compact Grid)
│   ├── Background: [6 color swatches]
│   └── Text: [6 color swatches]
```

### Implementation Strategy

1. **Create new enums** for font families and separate size/weight
2. **Redesign SettingsView** with compact interface
3. **Update TextDisplaySettings** model to support new structure
4. **Maintain backward compatibility** with existing settings
5. **Test all combinations** for readability and performance

### Technical Approach

#### New Model Structure
```swift
enum FontFamily: String, CaseIterable {
    case system, serif, monospace, rounded
}

enum FontSize: String, CaseIterable {
    case small, default, medium, large, extraLarge, maximum
}

enum FontWeight: String, CaseIterable {
    case regular, medium, bold
}
```

#### Compact UI Components
- Use `Picker` with `.segmentedPickerStyle()` for main categories
- Use compact grids for color selection
- Single preview area that updates in real-time
- Collapsible sections if needed

### Benefits
1. **More options** - 4 families × 6 sizes × 3 weights = 72 combinations
2. **Smaller UI footprint** - Compact pickers vs. long radio button lists
3. **Better organization** - Logical grouping of related options
4. **Enhanced accessibility** - Smaller sizes for compact reading, more font families
5. **Professional appearance** - More polished, iOS-native interface

### Success Criteria
- ✅ Add smaller font sizes (14pt option)
- ✅ Add different font families (System, Serif, Mono, Rounded)
- ✅ Reduce UI vertical space by 50%+
- ✅ Maintain live preview functionality
- ✅ Preserve all existing functionality
- ✅ Clean compilation without warnings
- ✅ Backward compatibility with existing settings
