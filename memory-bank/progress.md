# Progress Tracker: Argus iOS App

## Current Status
**Overall Status**: Beta - Core functionality implemented with known issues
**Development Phase**: Stabilization and bug fixing
**Last Updated**: March 26, 2025

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

## What's In Progress

- 🔶 **Sync Process Optimization**
  - Background sync process improvements underway using DatabaseCoordinator 
  - UI jitter during sync operations still needs to be addressed

- 🔶 **Data Consistency**
  - Improving validation of synchronized content
  - Testing fixes for data integrity issues

## Recently Completed

- ✅ **Topic Switching Optimization**
  - Implemented direct database access path for topics using DatabaseCoordinator
  - Added two-tier caching approach for immediate visual feedback during topic changes
  - Created specialized database query that combines all filter criteria in a single operation
  - Eliminated redundant in-memory filtering by moving filter logic to database level
  - Significantly reduced topic switching time especially with large datasets

- ✅ **Duplicate Content Resolution**
  - Fixed issue where articles appeared twice in lists (with and without rich text)
  - Made rich text generation synchronous during article save/update
  - Ensured all articles are stored with rich text already processed
  - Eliminated race conditions in content processing pipeline

- ✅ **Swift 6 Concurrency Compliance**
  - Fixed critical issues with NSAttributedString crossing actor boundaries
  - Added @MainActor constraints to LazyLoadingContentView in NewsDetailView
  - Eliminated "getAttributedString called from background thread" warnings
  - Ensured proper handling of non-Sendable types in async contexts

- ✅ **Error Handling Improvements**
  - Enhanced article fetching with better HTTP status code detection
  - Added more comprehensive error messages for failed article retrievals
  - Fixed duplicate notification ID errors in logs

- ✅ **DatabaseCoordinator Implementation**
  - Completed full implementation with Swift 6 concurrency safety
  - Fixed all actor-isolation and variable capture warnings
  - Eliminated redundant code to avoid conflicts with existing utilities
  - Added proper handling of concurrent database operations

- ✅ **Thread Safety Enhancements**
  - Improved handling of shared state in background tasks
  - Added safeguards against race conditions in database operations

## What's Left To Build

### Modernization Plan Implementation

#### Phase 1: Setup and Model Migration
- ✅ **Define SwiftData Models**
  - Created Article, SeenArticle, and Topic models with SwiftData annotations
  - Ensured fields align with backend API structure 
  - Applied unique constraints to prevent duplicates
  - Designed model relationships with proper cascade rules
- ✅ **Initialize SwiftData Container**
  - Created dedicated SwiftDataContainer class to isolate new models during transition
  - Configured ModelContainer with proper schema and persistence options
  - Added test interface (SwiftDataTestView) to verify SwiftData operations 
  - Integrated with Settings view for developer testing

- 🔲 **Migrate Existing Data (Optional)**
  - Create migration routine for converting old data to SwiftData models
  - Implement fallback to fetch fresh data if local data is incompatible

#### Phase 2: Networking and API Refactor
- 🔲 **Create Article API Client**
  - Refactor APIClient to use async/await for all API calls
  - Implement fetchArticles(), fetchArticle(by id:), and authenticateDevice(token:)
  - Enhance error handling with proper status code detection

- 🔲 **Build ArticleService**
  - Create bridge between API and SwiftData
  - Implement updateArticlesFromServer(), fetchArticles(), and saveArticle(_:)
  - Set up proper concurrency handling

#### Phase 3: MVVM Implementation and UI Refactor
- 🔲 **Refactor NewsView to Use ViewModel**
  - Create NewsViewModel with observable articles, loading state, and refresh method
  - Update NewsView to use StateObject ViewModel pattern
  - Replace manual fetches with ViewModel properties

- 🔲 **Implement ArticleDetailViewModel**
  - Handle article body Markdown rendering
  - Manage read/bookmark state
  - Refactor ArticleDetailView to use ViewModel

- 🔲 **Refactor SubscriptionsView and SettingsView**
  - Add ViewModels for topic preferences and settings
  - Migrate UI logic out of SwiftUI views

#### Phase 4: Syncing and Background Tasks
- 🔲 **Implement Periodic Sync Using .backgroundTask**
  - Schedule periodic sync with modern background task API
  - Set up ArticleService integration for background updates
  - Handle proper task expiration with cancellation

- 🔲 **Handle Push Notifications for New Articles**
  - Refactor AppDelegate for async push notification handling
  - Set up ArticleService integration for push-triggered fetches
  - Implement proper UI refresh on push receipt

#### Phase 5: Testing and Cleanup
- 🔲 **Test Data Migration and Persistence**
  - Verify SwiftData migration or fallback logic
  - Test offline behavior and article consistency

- 🔲 **Validate Syncing and Push Behavior**
  - Test background sync and push notification handling
  - Ensure proper article updates in all scenarios

- 🔲 **Performance and Battery Profiling**
  - Use Instruments to verify optimal resource usage
  - Ensure UI responsiveness during sync operations

- 🔲 **Remove Legacy Code**
  - Remove SyncManager, DatabaseCoordinator, and NotificationCenter-based state
  - Ensure all functionality is handled by new architecture

### Previous Planned Features
- 🔲 **Enhanced Social Sharing**
  - More comprehensive sharing options
  - Share with comments functionality
  
- 🔲 **Content Feedback**
  - Like/dislike functionality for articles
  - Feedback mechanisms for AI analysis
  
- 🔲 **Improved Error Handling**
  - More user-friendly error messages
  - Better recovery mechanisms for failed operations

## Known Issues

1. **UI Performance**
   - Interface becomes jittery during synchronization
   - Status: Will be addressed by MVVM refactoring and async/await implementation
   - Priority: High
   
2. **Database Limitations**
   - Current database design is difficult to modify
   - Status: Will be resolved by migration to SwiftData
   - Priority: High

## Testing Status

- ✅ **Unit Tests**
  - Core business logic tests passing
  - Coverage: ~70% of non-UI code
  
- 🔶 **UI Tests**
  - Basic navigation tests implemented
  - Detailed feature tests in progress
  
- 🔶 **Performance Testing**
  - Basic performance tests for DatabaseCoordinator planned
  - Manual testing reveals sync performance issues

## Next Milestone Goals

1. **Architecture Modernization (Target: May 2025)**
   - Complete Phases 1-2 of modernization plan
   - Implement SwiftData models and container
   - Refactor API client for async/await
   - Build ArticleService as repository layer

2. **UI Modernization (Target: June 2025)**
   - Complete Phases 3-4 of modernization plan
   - Implement ViewModels for all major views
   - Refactor UI to use MVVM pattern
   - Set up modern background task handling

3. **Cleanup and Performance (Target: July 2025)**
   - Complete Phase 5 of modernization plan
   - Remove legacy code components
   - Conduct performance profiling
   - Resolve any remaining issues

## Progress Metrics

- **Features Completed**: 6/9 core features fully implemented
- **Swift 6 Compatibility**: Major milestone reached with latest NSAttributedString fixes
- **Known Bugs**: 2 high-priority issues, both potentially affected by recent changes
- **Test Coverage**: ~70% of non-UI code
