# Quality Filter Implementation Plan

## Overview

This plan implements client-side quality filtering for articles based on proof quality (sourcesQuality) and logic quality (argumentQuality). The server cannot filter articles, so all filtering happens client-side in the SwiftData database queries.

## Quality Scale Understanding

- **sourcesQuality & argumentQuality**: 1-4 scale
  - 1 = "Poor" (red)
  - 2 = "Fair" (orange) 
  - 3 = "Good" (green)
  - 4 = "Strong" (blue)

## Filter Options

- **"All"** - No quality filtering (current behavior)
- **"Fair+"** - Articles with sourcesQuality ≥ 2 OR argumentQuality ≥ 2
- **"Good+"** - Articles with sourcesQuality ≥ 3 OR argumentQuality ≥ 3

## Files to Modify

### 1. `Argus/UserDefaultsExtensions.swift` - ADD CODE
**Changes**: Add quality filter UserDefaults support
```swift
// ADD to Keys enum:
static let qualityFilter = "qualityFilter"

// ADD computed property:
@objc var qualityFilter: String {
    get { string(forKey: Keys.qualityFilter) ?? "All" }
    set { set(newValue, forKey: Keys.qualityFilter) }
}
```

### 2. `Argus/NewsViewModel.swift` - ADD/MODIFY CODE
**Changes**: Add quality filter state and logic
```swift
// ADD property:
@Published var qualityFilter: String = "All"

// MODIFY loadUserPreferences() - ADD line:
qualityFilter = defaults.qualityFilter

// MODIFY saveUserPreferences() - ADD line:
defaults.qualityFilter = qualityFilter

// MODIFY setupUserDefaultsObservers() - ADD observer:
// Observer for qualityFilter changes

// ADD method:
func applyQualityFilter(_ filter: String) async {
    self.qualityFilter = filter
    saveUserPreferences()
    await refreshArticles()
}

// MODIFY refreshArticles() calls to pass qualityFilter parameter
```

### 3. `Argus/ArticleOperations.swift` - MODIFY CODE
**Changes**: Add quality filter parameter and logic
```swift
// MODIFY fetchArticles method signature - ADD parameter:
qualityFilter: String = "All"

// ADD helper function:
private func meetsQualityThreshold(_ article: ArticleModel, filter: String) -> Bool {
    switch filter {
    case "Fair+":
        return (article.sourcesQuality ?? 0) >= 2 || (article.argumentQuality ?? 0) >= 2
    case "Good+": 
        return (article.sourcesQuality ?? 0) >= 3 || (article.argumentQuality ?? 0) >= 3
    default: // "All"
        return true
    }
}

// MODIFY fetchArticles implementation:
// Add quality filtering to SwiftData predicates or in-memory filtering after fetch
// Apply quality filter in combination with existing filters
```

### 4. `Argus/DatabaseCoordinator.swift` - MODIFY CODE  
**Changes**: Add quality filter to article fetching
```swift
// MODIFY fetchArticlesForTopic method signature - ADD parameter:
qualityFilter: String = "All"

// MODIFY implementation to include quality filtering in predicates
// Add quality predicate logic similar to existing topic/unread/bookmarked filters
```

### 5. `Argus/ArticleService.swift` - MODIFY CODE
**Changes**: Update unread count calculation to respect quality filter
```swift
// MODIFY countUnviewedArticles method - ADD parameter:
qualityFilter: String = "All"

// MODIFY implementation to apply quality filter to count query
// Ensure badge count reflects quality-filtered articles only
```

### 6. `Argus/NotificationUtils.swift` - MODIFY CODE
**Changes**: Apply quality filter to badge count calculation
```swift
// MODIFY performBadgeUpdate() method:
// Get current quality filter from UserDefaults
// Pass quality filter to ArticleService.countUnviewedArticles()

// Example:
let qualityFilter = UserDefaults.standard.qualityFilter
let unviewedCount = try await ArticleService.shared.countUnviewedArticles(qualityFilter: qualityFilter)
```

### 7. `Argus/NewsView.swift` - ADD CODE
**Changes**: Add quality filter UI component
```swift
// ADD quality filter picker to the filter section
// Position near existing unread/bookmarked filters
// Use segmented control or menu with options:
// - "All articles"
// - "Fair or better" 
// - "Good or better"

// ADD binding to NewsViewModel.qualityFilter
// ADD action to call viewModel.applyQualityFilter()
```

## Implementation Strategy

### Client-Side Filtering Approach
Since the server cannot filter articles by quality, we implement filtering at the SwiftData database level:

1. **Database Query Filtering**: Add quality predicates to SwiftData FetchDescriptor
2. **Predicate Logic**: Combine quality filter with existing topic/unread/bookmarked predicates using AND logic
3. **Performance**: Database-level filtering ensures good performance vs in-memory filtering

### Quality Filter Logic
```swift
// Quality predicate for SwiftData
if qualityFilter == "Fair+" {
    qualityPredicate = #Predicate<ArticleModel> { article in
        (article.sourcesQuality ?? 0) >= 2 || (article.argumentQuality ?? 0) >= 2
    }
} else if qualityFilter == "Good+" {
    qualityPredicate = #Predicate<ArticleModel> { article in
        (article.sourcesQuality ?? 0) >= 3 || (article.argumentQuality ?? 0) >= 3
    }
}
```

### Badge Count Integration
- Badge count queries must apply the same quality filter as the main article list
- User sees consistent numbers between badge and article count
- Quality filter affects both main view and app icon badge

## UI Integration Points

### Filter Bar Layout
```
[Topic Selector] [Unread Toggle] [Bookmarked Toggle] [Quality Filter Picker]
```

### Quality Filter Picker Options
- **Segmented Control** with 3 options
- **Menu Button** with descriptive labels
- Clear visual indication of active filter

## Testing Scenarios

1. **Filter Combinations**: Quality + Topic + Unread + Bookmarked
2. **Badge Count Accuracy**: Verify badge matches filtered article count  
3. **Performance**: Large article datasets with quality filtering
4. **Persistence**: Quality filter setting survives app restart
5. **Empty States**: Handle cases where quality filter returns no articles

## Migration Considerations

- **Backward Compatibility**: Default "All" filter maintains current behavior
- **Nil Quality Values**: Articles without quality scores are excluded from Fair+/Good+ filters
- **UserDefaults**: New setting with sensible default

## Success Criteria

1. ✅ Users can filter articles by quality level
2. ✅ Badge count reflects quality-filtered unread articles
3. ✅ Quality filter persists across app sessions
4. ✅ Filter works in combination with existing filters
5. ✅ Performance remains good with large article datasets
6. ✅ UI clearly indicates active quality filter
