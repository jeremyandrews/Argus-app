# NewsDetailView Content Limitation Fix

## Issue Description

**User Report**: "This optimization is very fast, but when we go to NodeDetailView we're not seeing all content, we see at max around 43 even if there's >1,000. And we don't see all content types, only the types that happen to exist in those 43. We need to maintain the performance, but actually see ALL the content, and even be able to pager through all the content."

## Root Cause Analysis

The performance optimizations implemented in Phase 1 and Phase 2 included memory-aware fetch limits in `ArticleOperations.fetchArticles()`:

```swift
// Dynamic limit based on memory pressure and dataset size
let memoryPressure = getCurrentMemoryPressure()
if memoryPressure > 0.8 { // High memory pressure
    effectiveLimit = 50  // Reduced limit
} else if memoryPressure > 0.6 { // Medium memory pressure
    effectiveLimit = 75  // Moderate limit
} else {
    effectiveLimit = 100 // Normal limit for large datasets
}
descriptor.fetchLimit = effectiveLimit
```

This optimization was designed to improve NewsView performance with large datasets, but it inadvertently affects NewsDetailView when it tries to access the full dataset for navigation.

## Data Flow Analysis

1. **NewsView** → **NewsViewModel** → **ArticleOperations.fetchArticles()** → Limited to 50-100 articles
2. **NewsDetailView** receives this limited dataset from NewsView
3. **NewsDetailView** can only navigate through the limited articles, not the full 1,000+
4. Content types are limited to those present in the first ~43-100 articles

## Solution Strategy

The fix needs to distinguish between:
- **List View Performance**: Keep memory-aware limits for NewsView scrolling performance
- **Detail View Comprehensive Access**: Allow full dataset access for complete navigation

### Implementation Approach

1. **Add context parameter** to `fetchArticles()` to indicate the usage context
2. **Bypass memory limits** when fetching for detail view navigation
3. **Maintain performance optimizations** for list view scenarios
4. **Implement proper pagination** in NewsDetailView for large datasets

## Technical Requirements

- Maintain Swift 6 and iOS 18+ compliance
- Preserve existing performance optimizations for NewsView
- Enable full dataset access for NewsDetailView
- Implement efficient pagination for detail view navigation
- Ensure no compilation errors or warnings

## Files to Modify

1. **ArticleOperations.swift**: Add context-aware fetching
2. **NewsDetailViewModel.swift**: Update to request full dataset access
3. **NewsView.swift**: Update to pass appropriate context
4. **NewsViewModel.swift**: Update to use context-aware fetching

## Expected Outcome

- NewsDetailView can access and navigate through all 1,000+ articles
- All content types are visible (not just those in first 43 articles)
- Performance optimizations remain intact for NewsView
- Proper pagination allows browsing through all content
- Build compiles successfully with no warnings
