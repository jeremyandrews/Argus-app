# Progress Tracker: Argus iOS App

## Current Status
**Overall Status**: Beta - Core functionality implemented and all known issues resolved
**Development Phase**: Stabilization and Refinement Phase
**Last Updated**: April 14, 2025

## Modernization Milestones

- ✅ **SwiftData Model Definition** (Completed):
  - `ArticleModel`, `SeenArticleModel`, and `TopicModel` classes properly annotated with `@Model` macro
  - All models defined with appropriate relationships and cascade rules
  - CloudKit compatibility implemented with default values for required properties
  - API compatibility extensions bridge between old `NotificationData` and new `ArticleModel`
  - Proper Equatable conformance for Swift 6 compatibility

- ✅ **Repository Layer Implementation** (Completed):
  - Complete implementation of `ArticleServiceProtocol` with modern Swift concurrency
  - Thread-safety using serial dispatch queue for cache operations
  - Comprehensive error handling with proper error types and propagation
  - Blob storage and retrieval with three-phase loading approach
  - Robust caching strategy with proper invalidation

- ✅ **UI Refactoring to MVVM** (Completed):
  - Well-structured ViewModels with `@MainActor` annotations
  - Reactive UI updates using `@Published` properties
  - Combine integration for settings observation
  - Proper dependency injection patterns
  - Clean separation of UI logic from business logic

- ✅ **Background Processing Modernization** (Completed):
  - Modern Swift concurrency with async/await
  - Structured concurrency with task groups
  - Proper timeout and cancellation handling
  - Network-aware scheduling with proper power requirements
  - BGTaskScheduler implementation with proper expiration handling

- ✅ **Legacy Code Removal** (Complete):
  - ✅ MigrationAwareArticleService properly marked with deprecation notices
  - ✅ All write operations in MigrationAwareArticleService correctly forward to ArticleService
  - ✅ MigrationService properly isolated and using the deprecated service appropriately
  - ✅ Core data collections in NewsViewModel and NewsDetailViewModel fully converted to use ArticleModel
  - ✅ Comprehensive compatibility extensions in ArticleModel to facilitate smooth transition
  - ✅ UI components audited and verified to use ArticleModel (LazyLoadingQualityBadges updated)
  - ✅ ShareSelectionView confirmed to already use ArticleModel properly
  - ✅ Removed unnecessary NotificationData extension as ArticleModel provides same functionality
  - ✅ Documented migration components for future clean removal

## What's Next

To complete the remaining work in the **Stabilization and Refinement** phase:

1. **Additional Performance Optimizations**:
   - Consider batched loading for large article collections
   - Implement more aggressive caching for frequently accessed UI components
   - Profile and optimize CPU-intensive tasks

2. **User Experience Improvements**:
   - Add tutorial overlays for new users
   - Enhance accessibility features
   - Improve offline mode experience
   - Streamline first-run experience

3. **Final Testing Phase**:
   - Complete end-to-end testing on all supported iOS versions
   - Verify performance with large article collections
   - Test migration path from earliest app versions
   - Validate all edge cases in offline/online transitions

## What Works

### Core Features
- ✅ **Topic Subscription System**
  - Users can subscribe to topics
  - Priority flags for notifications are functional
  
- ✅ **Markdown to Rich Text Conversion**
  - Articles are successfully converted from Markdown to rich text
  - Formatting is preserved in the conversion process
  
- ✅ **Basic Article Organization**
  - Articles can be sorted by various criteria
  - Read/unread tracking is implemented
  
- ✅ **Article Storage**
  - Articles are available offline after download
  - Background fetching of new content works

- ✅ **Push Notifications**
  - High-priority article notifications are delivered
  - Notification tapping opens the correct article

- ✅ **AI Insights**
  - Critical and logical analyses are displayed with articles
  - Quality indicators are functional

## Recently Completed

- ✅ **Fixed UI Update Issue for Empty Topics and Filters** (Completed):
  - Resolved multiple related issues with UI updates:
    - When reading the only article in a topic and closing it, the view didn't refresh to "All"
    - Enabling/disabling filters didn't update the article list properly
    - Background syncs required manual topic switching to see new articles
  - Root cause: Disconnected UI components didn't properly update the ViewModel
  - Implementation details:
    - Added a dedicated auto-redirect method in NewsViewModel
    - Implemented callback-based filter updates in FilterView
    - Added notification posting in BackgroundTaskManager to signal UI updates
    - Fixed Swift 6 compliance issues with explicit self references
  - Benefits:
    - User experience is more intuitive with automatic redirection from empty topics
    - UI promptly reflects filter changes without requiring manual refresh
    - New articles appear automatically after background sync completes
    - Better Swift 6 compatibility with explicit self references and proper error handling

- ✅ **Fixed Related Articles Display Issue** (Completed):
  - Resolved issue where related articles weren't displaying properly with the error:
    ```
    Failed to decode relatedArticlesData: Swift.DecodingError.typeMismatch(Swift.String, 
    Swift.DecodingError.Context(..., debugDescription: "Expected to decode String but found number instead.")
    ```
  - Root cause: Date format mismatch between API data and stored data
    - API provides dates as ISO8601 strings
    - JSONEncoder converts these to numeric timestamps when storing
    - RelatedArticle decoder was still trying to parse timestamps as strings
  - Implementation details:
    - Modified RelatedArticle decoder to expect and handle timestamps instead of strings:
      ```swift
      // When loaded from database, published_date is stored as a timestamp
      let timestamp = try container.decodeIfPresent(Double.self, forKey: .publishedDate)
      if let timestamp = timestamp {
          publishedDate = Date(timeIntervalSince1970: timestamp)
      }
      ```
    - Enhanced the initial API JSON parsing to use explicit ISO8601 date strategy
    - Added useful logging to track data format throughout the pipeline
  - Benefits:
    - Related articles now display correctly in detail view
    - Clean implementation with exact format expectations
    - Consistent approach that respects our controlled data flow
    - Fixed without complex format detection or conversion logic

- ✅ **Implemented Auto-Redirect for Empty Topics** (Completed):
  - Fixed UX issue where users were shown an empty state with "No news is good news" when selecting a topic with no content
  - Implementation details:
    - Added auto-redirect logic in `applyTopicFilter` method in NewsViewModel:
      - Checks if filtered articles are empty after topic selection
      - Automatically reverts to "All" topic if the selected topic has no content
      - Saves the updated preference to UserDefaults
      - Refreshes articles to show content from all topics
    - Updated empty state message in NewsView+Extensions.swift
  - Benefits:
    - Users always see content when available, even if their selected topic is empty
    - Eliminates confusion caused by empty state suggesting there's no news at all
    - Provides a more intuitive experience by intelligently adapting to content availability

- ✅ **Simplified Related Content Implementation** (Completed):
  - Streamlined and simplified the Related Content implementation using the same pattern as Engine Stats
  - Replaced complex implementation using raw dictionaries with structured data types
  - Created a clean `RelatedArticlesView` component with clear responsibility separation
  - Added proper article selection and navigation with `loadRelatedArticle` function
  - Improved type safety and maintainability with strongly-typed models

- ✅ **Fixed Article Navigation Flicker Issue** (Completed):
  - Resolved visual issue when navigating between articles using chevron buttons
  - Modified `navigateToArticle(direction:)` in NewsDetailViewModel to use a content-first approach
  - Extracted all blob content first, then updated UI only once with fully formatted content
  - Significantly improved user experience with smoother, more professional transitions

- ✅ **Fixed Argus Engine Stats Display** (Completed):
  - Resolved issues with engine stats display in NewsDetailView
  - Fixed JSON field parsing for proper data extraction from API responses
  - Enhanced UI components to display engine statistics in a user-friendly format
  - Created specialized components for displaying engine metrics

- ✅ **Fixed Database Duplicate Content Issue** (Completed):
  - Resolved issue where duplicate articles were being added to database during sync operations
  - Refactored `processRemoteArticles` in ArticleService to use batched transaction management
  - Implemented explicit context.save() after each batch to prevent race conditions
  - Added comprehensive logging to track transaction boundaries and batch progress

- ✅ **Improved Sync Status Indicator with Real-Time Feedback** (Completed):
  - Enhanced the article download process to provide per-article progress updates
  - Modified `APIClient.fetchArticles` to accept a progressHandler parameter
  - Added detailed progress updates at each stage of the download process
  - Eliminated the issue where "Checking for new articles..." would display for 99% of the sync time

- ✅ **Fixed Rich Text Formatting and Size Issue** (Completed):
  - Resolved issue where article content was displayed either as raw markdown or with text too small
  - Modified NonSelectableRichTextView to normalize font size while preserving formatting attributes
  - Ensured all text is rendered at the system's preferred body text size for readability
  - Preserved all formatting attributes like bold, italic, and headers while normalizing font size

- ✅ **Fixed Swift 6 Equatable Conformance Issue** (Completed):
  - Resolved Equatable conformance issues with SwiftData models in Swift 6
  - Identified and fixed interactions between SwiftData's `@Model` macro and Swift 6
  - Cleaned up NewsDetailViewModel.swift by removing obsolete comments
  - Updated ArgusApp.swift to use ArticleModel instead of NotificationData in all FetchDescriptors

- ✅ **Fixed Cloud Build String Extension Issue** (Completed):
  - Resolved build error that occurred in Apple's cloud build but not in local Xcode build
  - Modified code to use standalone functions instead of String extensions
  - Ensured code builds successfully in both local Xcode and cloud environments

- ✅ **Fixed Cloud Build Domain Extraction Scope Error** (Completed):
  - Duplicated the `extractDomain(from:)` function in both files that need it
  - Made the function private to each file to avoid potential naming conflicts
  - Ensured app builds successfully in both local Xcode and Apple's cloud build environment

- ✅ **Implemented R2 URL JSON New Fields** (Completed):
  - Added support for two new fields in the JSON payload:
    - `action_recommendations`: Concrete, actionable steps based on article content
    - `talking_points`: Thought-provoking discussion points to facilitate sharing
  - Implementation details:
    - Added fields to `ArticleJSON` and `PreparedArticle` structs in ArticleModels.swift
    - Added properties and blob storage fields in ArticleDataModels.swift
    - Created API compatibility extensions for snake_case to camelCase conversion
    - Updated MarkdownUtilities.swift to handle the new fields as rich text
    - Added section naming mappings and text style configuration
    - Included the fields in verification and regeneration functions
  - Key improvements:
    - Users can now receive practical, actionable recommendations for each article
    - Facilitates deeper engagement with content through curated talking points
    - Transforms passive news consumption into opportunities for action and discussion
    - Maintains consistent rich text rendering across all content types

- ✅ **Fixed Article Content Display Issue in NewsView** (Completed):
  - Resolved display issue where text formatting was inconsistent between views
  - Modified NewsView to use the same UI component (NonSelectableRichTextView) as NewsDetailView
  - Ensured consistent text rendering across the entire application

- ✅ **Fixed Swift 6 String Interpolation Issues with RichTextField** (Completed):
  - Added explicit String conversion using `String(describing:)` for RichTextField in strings
  - Fixed multiple similar issues throughout ArticleService.swift
  - Made RichTextField enum conform to CaseIterable to enable iteration in diagnostic functions

- ✅ **Fixed Rich Text Blob Architectural Issue** (Completed):
  - Fixed core issue where NewsDetailView was creating its own ViewModel, losing SwiftData model context
  - Modified NewsDetailView to accept pre-configured ViewModel via constructor pattern
  - Improved MVVM architecture through proper view model injection

- ✅ **Fixed Rich Text Blob Storage Issue** (Completed):
  - Resolved issue with rich text blobs not being properly saved to database
  - Added `getArticleWithContext` method to ArticleOperations
  - Restructured rich text generation and blob saving process in NewsDetailViewModel

- ✅ **Fixed ArticleService Thread-Safety Issue** (Completed):
  - Resolved app crash caused by concurrent access to `cacheKeys`
  - Added dedicated serial dispatch queue for cache operations
  - Implemented comprehensive thread-safety improvements

- ✅ **Enhanced Article Section Loading System** (Completed):
  - Resolved significant issues with section loading in NewsDetailView
  - Implemented a robust sequential loading process with improved diagnostics
  - Created a clear three-phase loading approach for content retrieval

- ✅ **Removed Archive Functionality** (Completed):
  - Removed the archive concept completely from the codebase
  - Implemented backward compatibility strategy for existing installations
  - Simplified the article lifecycle and user interface

- ✅ **Fixed API Sync Error by Optimizing seen_articles List** (Completed):
  - Modified `fetchArticleURLs()` method to only include articles from the last 12 hours
  - Limited entries to maximum 200 to prevent oversized requests
  - Prevented timeouts during syncing by reducing server load

- ✅ **Made Debug Tools Accessible to Testers** (Completed):
  - Renamed the "Development" section in SettingsView to "Debug"
  - Removed conditional compilation directive (`#if DEBUG`) for tester access
  - Maintained all existing functionality including Topic Statistics

- ✅ **Topic Bar Filtering Improvement** (Completed):
  - Fixed issue where only the selected topic would show in topic bar
  - Implemented dual article collection approach in NewsViewModel
  - Improved user experience by showing all available topics at all times
