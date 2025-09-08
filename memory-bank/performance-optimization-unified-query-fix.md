# Performance Optimization: Unified Query System Fix

## Problem Analysis

**Issue**: The unified query system implemented to fix missing topics is causing performance degradation by fetching ALL articles (potentially thousands) for topic bar generation.

**Root Cause**: 
- `fetchArticlesUnified()` uses `.detailView` context with no limits
- `refreshArticles()` fetches ALL articles for topic bar generation: `topic: nil` with no limits
- This causes memory pressure and UI lag with large datasets (1,000+ articles)

**Current Performance Impact**:
- Slow article refresh operations
- Memory pressure from loading thousands of articles
- UI lag during topic switching
- Poor user experience with large datasets

## Solution Strategy

Implement a **Smart Topic Caching System** that maintains functionality while optimizing performance:

1. **Separate Topic Discovery from Article Display**
   - Use lightweight topic-only queries for topic bar generation
   - Cache topic lists separately from article data
   - Update topic cache only when new articles are added

2. **Hybrid Query Approach**
   - Keep unified queries for consistency but add smart limits
   - Use statistical sampling for topic diversity
   - Implement background topic cache warming

3. **Performance-Aware Context System**
   - Add new `.topicDiscovery` context for lightweight topic queries
   - Optimize `.topicBar` context with intelligent sampling
   - Maintain `.detailView` context for navigation completeness

## Implementation Plan

### Phase 1: Smart Topic Caching
- Create `TopicCacheManager` for lightweight topic discovery
- Implement topic-only queries that fetch minimal data
- Cache topic lists with timestamps for invalidation

### Phase 2: Optimized Query Contexts
- Add `.topicDiscovery` context with minimal data fetching
- Enhance `.topicBar` context with statistical sampling
- Implement intelligent topic diversity algorithms

### Phase 3: Background Processing
- Move topic cache updates to background threads
- Implement progressive topic discovery during sync
- Add topic cache warming during idle periods

## Expected Performance Improvements

- **Topic Bar Generation**: 90% faster (from ~2s to ~200ms)
- **Memory Usage**: 70% reduction in peak memory
- **UI Responsiveness**: Eliminate lag during topic switching
- **Functionality**: Maintain complete topic visibility

## Technical Requirements

- Maintain Swift 6 and iOS 18+ compliance
- Preserve functionality that prevents topics from disappearing
- Ensure build succeeds with no warnings or errors
- Implement comprehensive performance monitoring

## Status: READY FOR IMPLEMENTATION
