# Active Context: Argus iOS App

## Current Work Focus
- **Active Development Phase**: Modernization implementation in progress
- **Primary Focus Areas**: SwiftData migration active, implementing shared MVVM architecture, async/await implementation, CloudKit compatibility
- **Architecture Refinement**: Implemented shared components for code reuse between NewsView and NewsDetailView
- **User Experience Improvements**: Improving UI responsiveness, eliminating sync jitter, enhancing offline capabilities, and refining automatic migration process
- **Cross-Device Capabilities**: Preparing SwiftData models for future CloudKit integration to enable iPhone/iPad syncing
- **Migration System Refinement**: Enhancing visual feedback during automatic database migration, removing redundant controls
- **SwiftData Container Connection Issue**: Addressed disconnect between SwiftData Test container and main application container

## Recent Changes
- **Fixed Article Read Status and Navigation Formatting Issues** (Completed):
  - Fixed issue where opening an article wasn't marking it as read (background stayed in unread state)
  - Fixed problem with articles appearing unformatted and unread when navigating between them using chevrons
  - Updated ArticleOperations.toggleReadStatus() to force immediate in-memory UI state updates using MainActor.run
  - Enhanced NewsDetailView.toggleReadStatus() to refresh UI immediately with contentTransitionID updates
  - Improved NewsDetailViewModel.markAsViewed() to ensure UI updates even for already-read articles
  - Added explicit objectWillChange.send() calls to properly trigger SwiftUI state updates
  - Fixed race condition between database updates and UI rendering for read status
  - Ensured consistent behavior between direct article viewing and chevron navigation

- **Fixed Chevron Color and Article Read Status in NewsDetailView** (Completed):
  - Restored blue color for clickable navigation chevrons that had reverted to the default primary color
  - Fixed article read status updating by properly implementing the markAsViewed() method to use the ViewModel's async method
  - Addressed compile errors in LazyLoadingContentView by fixing incorrect parent view method references
  - Corrected onAppear handling in nested views to ensure proper content loading
  - Ensured articles are properly marked as read when viewed, maintaining correct read status throughout the app
  - Made minimal changes to preserve existing functionality while fixing specific issues

- **Fixed Navigation Chevrons in NewsDetailView** (Completed):
  - Identified type incompatibility between NewsDetailView.NavigationDirection and NewsDetailViewModel.NavigationDirection
  - Added proper conversion between view and ViewModel enum types in navigateToArticle() method
  - Fixed button disabling logic in the topBar to properly use ViewModel state
  - Added explicit foregroundColor states to improve visual feedback when buttons are disabled
  - Ensured proper sync between view state and ViewModel after navigation
  - Resolved issue where chevrons were always gray and non-functional

- **Fixed Missing Detail View Sections** (Completed):
  - Identified missing data transfer in ArticleModelAdapter for engine stats and related articles
  - Updated ArticleModelAdapter.from() method to transfer engineStats and similarArticles fields
  - Modified updateBlobs() method to ensure bidirectional data transfer
  - Fixed "Argus Engine Stats" and "Related Articles" sections in NewsDetailView
  - No changes to the view itself were needed as display code was already correctly implemented
  - Ensured proper data flow through the adapter pattern for specialized JSON data
- **Fixed Rich Text Blob Generation** (Completed):
  - Identified missing rich text blob transfer during sync and migration
  - Added blob storage fields (titleBlob, bodyBlob, etc.) to ArticleModel class 
  - Updated ArticleModelAdapter to transfer blobs in both directions
  - Added updateBlobs method to ArticleModel to copy blobs from NotificationData
  - Modified MigrationService to preserve existing blob data during migration
  - Fixed ArticleService.processRemoteArticles to transfer generated blobs to ArticleModel before saving
  - Ensured all newly downloaded content has rich text blobs properly populated without requiring user interaction
  - Addressed UI issue where article previews showed "Formatting..." overlay due to missing blobs
- **Fixed Topic Display Issue** (Completed):
  - Implemented dual article collection approach in NewsViewModel (allArticles and filteredArticles)
  - Ensured all topics remain visible in topic bar regardless of which topic is selected
  - Modified NewsViewModel.refreshArticles() to fetch all articles matching non-topic filters for topic bar
  - Simplified topic filtering in NewsView by using allArticles directly
  - Preserved "All" topic cache when specific topic is selected
  - Improved user experience by showing all available topics at all times

- **Fixed SwiftData Content Display Issue** (Completed):
  - Identified and addressed disconnect between two separate SwiftData containers
  - Created ArticleModelAdapter to bridge between ArticleModel and NotificationData
  - Updated ArticleService to query ArticleModel entities instead of NotificationData
  - Implemented model conversion to maintain backward compatibility in the UI layer
  - Ensured correct object transformation for all article operations (CRUD)
  - Modified rich text generation to work with the adapter pattern
  - Maintained proper MainActor isolation for NSAttributedString handling

- **Fixed Swift 6 Concurrency Issues** (Completed):
  - Added @MainActor annotations to protocol methods and implementations
  - Created dedicated MainActor-isolated methods for NSAttributedString handling
  - Added @discardableResult to batch operations to prevent Swift 6 warnings
  - Fixed unused return value warnings in NewsViewModel batch operations
  - Ensured proper handling of non-Sendable types across actor boundaries
  - Implemented thread-safe rich text generation with MainActor isolation
  - Maintained proper separation of UI code and background operations

- **Implemented Shared Architecture Components** (Completed):
  - Created ArticleServiceProtocol as interface for data operations
  - Implemented ArticleService to handle SwiftData operations with proper error handling and caching
  - Developed ArticleOperations shared business logic layer
  - Built NewsViewModel and NewsDetailViewModel that leverage shared components
  - Followed modern Swift concurrency practices with proper @MainActor isolation
  - Applied robust error handling throughout the architecture
  - Used async/await for all asynchronous operations
  - Implemented proper caching strategies for improved performance
  - Added comprehensive documentation with detailed method comments

- **Migration System UI Enhancements** (Completed):
  - Enhanced visual feedback with sophisticated animations (animated database icon, gradient progress bar, glowing effects)
  - Improved real-time metrics displays with dedicated counter views for articles processed and speed
  - Implemented time remaining indicator with live countdown
  - Added clear completion state with smooth transitions
  - Consolidated UI components for consistency across the app
  - Removed non-functional buttons from migration screens
  - Improved developer view with clearer labeling and informational section
  - Enhanced auto-dismissal behavior with proper timing and animations
  - Restructured code to better separate concerns and improve maintainability

- **Enhanced Database Migration System**:
  - Implemented automatic migration that runs at app launch without manual triggering
  - Created full-screen iOS-standard modal that blocks all app interaction during migration
  - Developed temporary migration mode that re-runs on each app start to keep databases in sync
  - Added state synchronization to update article attributes (read/unread, bookmarked)
  - Implemented resilient progression tracking to handle app termination and restart
  - Designed self-contained architecture for easy removal in a future update
  - Optimized for 2-8 second performance target on typical article collections
- **Implemented persistent storage for SwiftData testing**:
  - Transitioned from in-memory to persistent storage using a dedicated test database file
  - Created a specific test database ("ArgusTestDB.store") in the documents directory to avoid production data interference
  - Simplified architecture by removing dual-mode (in-memory/persistent) support and test mode toggle
  - Enhanced reset functionality to specifically target test database files for reliable cleanup
  - Updated UI to display storage location with clear visual indicators
- **Removed in-memory fallback mechanism**:
  - Eliminated fallback to in-memory storage to simplify the codebase
  - Removed all conditional code paths that dealt with in-memory mode
  - Updated error handling to properly propagate failures instead of silently falling back
  - Removed UI warnings and indicators related to in-memory storage
  - Made persistent storage a hard requirement for the app to function
- Implemented SwiftData models to support the modernization plan:
  - Created Article, SeenArticle, and Topic models with proper SwiftData annotations
  - Reconfigured models to be CloudKit-compatible by adding default values to all required properties
  - Removed unique constraints from model definitions (for CloudKit compatibility)
  - Set up appropriate relationships between models with cascade delete rules
  - Ensured field alignment with backend API structure for seamless integration
  - Designed models to support the upcoming MVVM architecture and future cross-device syncing
- Implemented and tested the Data Migration infrastructure:
  - Created MigrationService class that orchestrates the migration process
  - Implemented batched processing (50 articles at a time) for efficient migration
  - Added progress tracking and state persistence for resilience against interruptions
  - Added test mode capability to allow migration testing with in-memory storage
  - UI implementation with progress indicators and status reporting
  - Enhanced migration UI with comprehensive improvements:
    - Fixed dark mode readability issues with proper system color adaption
    - Implemented reset capability to test multiple migrations without rebuilding
    - Added detailed migration summary with statistics (articles, topics, speed)
    - Improved state management with Swift actor isolation (@MainActor compliance)
    - Enhanced error handling and cancellation logic
- Verified SwiftData performance for batch operations:
  - Enhanced test interface with batch creation capabilities (1-10 articles at a time)
  - Implemented performance metrics to measure and analyze creation speed
  - Verified that SwiftData is capable of handling hundreds of articles efficiently
  - Confirmed that batched operations with background processing significantly improve performance
  - Documented optimal patterns for batch processing (Task.detached, background contexts, intermediate saves)
- Solved SwiftData relationship deletion challenges:
  - Implemented robust deletion pattern that prevents EXC_BAD_ACCESS crashes
  - Added relationship nullification step to break circular references before deletion
  - Created dedicated ModelContext isolation pattern for deletion operations
  - Implemented batched processing with intermediate saves for reliable entity deletion
  - Added comprehensive diagnostic logging to track SwiftData operations
  - Documented patterns for safe cascade deletion in relationship-heavy models
- Defined comprehensive modernization plan with phased implementation approach:
  - Created detailed task breakdown for model migration, networking refactor, MVVM implementation, and background processing
  - Planned transition from current architecture to SwiftData and MVVM
  - Defined clear migration path that addresses existing pain points
- Prepared for implementation of Swift concurrency with async/await:
  - Mapped out API client refactoring strategy
  - Planned replacement of completion handler-based code with modern Swift concurrency
  - Identified components requiring async/await upgrades (SyncManager, DatabaseCoordinator, API Client)
- Designed new ViewModels to separate business logic from Views:
  - Outlined NewsViewModel for article list management
  - Planned ArticleDetailViewModel for article rendering logic
  - Structured SubscriptionsViewModel and SettingsViewModel for preference management

## Recent Changes

- **Implemented Modern Background Task System** (Completed):
  - Created dedicated BackgroundTaskManager class to replace the callback-based SyncManager
  - Implemented proper BGTaskScheduler registration with separate handlers for app refresh and processing tasks
  - Added intelligent network condition checking with checked continuations
  - Implemented timeout handling using Swift task groups and cancellation
  - Enhanced ArticleService with performQuickMaintenance method for background operations
  - Added processArticleData method to ArticleService to expose public article processing API 
  - Updated AppDelegate to use modern async/await for push notification handling
  - Fixed all compiler warnings including unreachable catch blocks and unused results
  - Ensured proper error propagation with structured error handling
  - Improved logging of background operations with detailed success/failure tracking
  - Maintained full compatibility with existing API while modernizing implementation
  - Completed Phase 4 (Background Tasks) of the modernization plan

## Next Steps

### Phase 1: Setup and Model Migration ✅
1. **✅ Implement Persistent SwiftData Container for Testing**:
   - Completed: SwiftDataContainer now uses persistent storage by default
   - Created dedicated "ArgusTestDB.store" test database in documents directory
   - Enhanced resetStore() function to specifically target test database files
   - Updated UI to show storage location and persistent/in-memory status
   - Removed test mode toggle from MigrationService and MigrationView

2. **✅ Complete Migration Testing with Persistent Storage**:
   - Completed: Migration with fully persistent storage verified
   - Fixed timing issue in migration summary reporting
   - Successfully migrated 2,543 articles to SwiftData
   - Confirmed excellent performance with persistent storage

### Phase 2: Networking and API Refactor ✅
3. **✅ Create Article API Client**:
   - Completed: APIClient fully refactored to use async/await for all API calls
   - Implemented JWT token authentication with automatic refresh
   - Created comprehensive error handling with domain-specific ApiError types
   - Added robust HTTP response validation with specific status code handling
   - Implemented key API methods: fetchArticles(), fetchArticle(by:), fetchArticleByURL(), syncArticles()
   - Ensured thread-safety with proper self-capture in closures

4. **✅ Build ArticleService (Repository Layer)**:
   - Completed: Implemented ArticleService as bridge between API and SwiftData
   - Created key methods for article data operations:
     - fetchArticles(topic:isRead:isBookmarked:isArchived:): Retrieves filtered articles
     - fetchArticle(byId:): Gets single article by ID
     - syncArticlesFromServer(topic:limit:): Syncs with backend, only adding new articles
     - markArticle(id:asRead/asBookmarked:): Updates user preferences
     - performBackgroundSync(): Handles full background synchronization
   - Implemented immutable article pattern with application-level uniqueness validation
   - Used efficient batch processing with intermediate saves
   - Incorporated proper error handling with specific ArticleServiceError types
   - Implemented modern Swift 6 concurrency with async/await and Task cancellation
   - Designed for gradual adoption with existing components during transition

### Phase 3: MVVM Implementation and UI Refactor ✅
5. **✅ Develop Shared Architecture Components**:
   - Completed: Created ArticleServiceProtocol as interface for dependency injection
   - Completed: Implemented ArticleOperations for shared business logic
   - Completed: Added rich text processing utilities in shared component
   - Completed: Implemented consistent error handling and state management
   - Completed: Created shared methods for article state toggling (read, bookmarked, archived)

6. **✅ Implement ViewModels**:
   - Completed: Created NewsViewModel with proper ObservableObject implementation
   - Completed: Implemented NewsDetailViewModel with section management
   - Completed: Added async loading and caching strategies for performance
   - Completed: Implemented proper @MainActor isolation for UI updates
   - Completed: Added comprehensive API for views to interact with

### Phase 4: UI Refactoring
7. **✅ Refactor NewsView to Use ViewModel**:
   - Completed: Updated NewsView to use NewsViewModel instead of direct database access
   - Fixed property visibility to allow extension access to ViewModel
   - Properly implemented extension methods to delegate to ViewModel
   - Fixed SwiftUI/UIKit integration for presenting detail views
   - Corrected environment value passing between views
   - Updated pagination to use ViewModel-based article filtering
   - Removed unused variables to fix Swift compiler warnings
   - Implemented proper MVVM separation between view and business logic

8. **✅ Connect ArticleModel with NotificationData**:
   - Completed: Created ArticleModelAdapter to bridge between data models
   - Completed: Updated ArticleService to query ArticleModel but return NotificationData
   - Completed: Implemented bidirectional conversion between model types
   - Completed: Modified rich text generation to work with the adapter pattern
   - Completed: Ensured all CRUD operations work with the correct model types

9. **✅ Refactor NewsDetailView to Use ViewModel**:
   - Completed: Updated NewsDetailView to use NewsDetailViewModel
   - Completed: Moved article operations to ViewModel (read/bookmark/archive/delete)
   - Completed: Implemented proper state management with ObservableObject pattern
   - Completed: Enhanced navigation between articles with better state preservation
   - Completed: Improved section loading with task cancellation for better performance
   - Completed: Fixed rich text handling to work without direct access to ArticleOperations
   - Completed: Implemented custom getAttributedString method for text formatting
   - Completed: Added helper methods for RichTextField enum conversion to readable strings
   - Completed: Fixed nested LazyLoadingContentView implementation with customFontSize support
   - Completed: Ensured proper separation of view-specific formatting from business logic

### Phase 5: Testing and Cleanup
10. **✅ Implement Modern Background Tasks**:
   - Completed: Created BackgroundTaskManager to replace SyncManager
   - Completed: Implemented proper task cancellation and expiration handling
   - Completed: Set up periodic syncing using BGTaskScheduler
   - Completed: Enhanced push notification handling with async/await
   
11. **Test Data Migration and Persistence**:
   - Verify SwiftData migration resilience
   - Test offline behavior and article consistency
   - Validate proper state preservation 

12. **Validate Syncing and Push Behavior**:
   - Test background sync functionality under various conditions
   - Verify push notification handling
   - Ensure proper article updates in all scenarios 

13. **Performance and Battery Profiling**:
   - Use Instruments to verify optimal resource usage
   - Analyze memory and CPU patterns during extended use
   - Ensure UI responsiveness during sync operations
   - Measure battery impact of background operations

14. **Legacy Code Removal Plan**:
   - **Phase 1: Dependency Analysis** (In Progress)
     - Create a comprehensive dependency map for all legacy components
     - Verify modern replacements fully implement required functionality
     - Document necessary preservation for migration system
     - Identify components with no remaining dependencies
   
   - **Phase 2: SyncManager Removal**
     - Verify BackgroundTaskManager implements all SyncManager functionality
     - Create adapter for any edge cases discovered in dependency analysis
     - Update all code references to use BackgroundTaskManager instead
     - Create versioned migration path to ensure older app versions still work with backend
     - Add comprehensive logging during transition period
     - Remove SyncManager class and related helper methods
     - Refactor remaining code to use proper Swift 6 concurrency
   
   - **Phase 3: Notification Center Cleanup**
     - Identify all NotificationCenter observers in the codebase
     - Replace with @Published properties and ObservableObject pattern
     - Update view refresh mechanisms to use SwiftUI state system
     - Remove redundant observers and notification posts
     - Add defensive measures for potential missed updates
     - Verify UI updates properly with state changes
   
   - **Phase 4: DatabaseCoordinator Transition**
     - Create MigrationAwareArticleService that supports both models
     - Implement migration-preserving path for persistent data
     - Ensure proper data flow through migration coordinator
     - Update all database access to use MigrationAwareArticleService
     - Move one-time migration responsibility to startup sequence
     - Reduce DatabaseCoordinator to minimal implementation
     - Add version detection to support existing users
   
   - **Phase 5: Final Verification**
     - Comprehensive testing of all app functionality
     - Performance analysis to verify improved responsiveness
     - Memory usage validation with Instruments
     - Migration path verification (fresh install vs. upgrade)
     - Verify proper cleanup of legacy components

## Legacy Code Removal Special Considerations

- **Migration Protection Strategy**:
  - Migration system must be preserved as dozens of users will take weeks to upgrade
  - Implement one-time migration at startup with improved visual feedback
  - Use version detection to determine if migration is necessary
  - Maintain migration coordinator as isolated module with minimal dependencies
  - Create versioned migration path for transitioning from legacy to modern code
  - Add robust error handling for migration failures

- **Critical Implementation Paths**:
  - Current implementation uses MigrationCoordinator as the entry point
  - Must preserve the coordinator pattern while removing unnecessary dependencies
  - Keep the modal UI to prevent user interaction during migration
  - Maintain migration state persistence to handle app termination
  - Ensure recovery mechanisms for interrupted migrations
  - Verify full database integrity after migration completes

- **Transition Timeline**:
  - Migration system must remain functional for at least 8 weeks
  - After sufficient user base has upgraded, we can remove migration code entirely
  - Self-contained architecture of migration module will facilitate future removal
  - Final app update can safely remove migration components after transition period

## Active Decisions and Considerations
- **Architectural Approach**: 
  - Three-tier architecture with shared business logic:
    - Data Layer: ArticleService (API + SwiftData)
    - Business Logic Layer: ArticleOperations (shared functionality)
    - View Models: NewsViewModel and NewsDetailViewModel (view-specific logic)
  - MVVM pattern with shared components for code reuse between views
  - SwiftData selected for modern persistence with Swift-native syntax
  - Swift concurrency (async/await) for improved readability and performance
  - Adapter pattern to bridge between ArticleModel and NotificationData during transition

- **Migration Strategy**: 
  - Phased implementation to ensure continuous app functionality
  - Testing each phase thoroughly before moving to next
  - Keeping compatibility with existing systems during transition
  - Using adapters to maintain compatibility with existing UI while modernizing data layer

- **Performance Focus**: 
  - Implementing optimized database access patterns from the start
  - Ensuring background processes don't impact UI responsiveness
  - Planning for efficient memory usage with proper task management

## Current Challenges
- Coordinating the transition from current architecture to MVVM+SwiftData
- Ensuring data integrity during migration to SwiftData
- Managing complexity of background task implementation
- Maintaining offline functionality throughout the modernization process
- Implementing application-level uniqueness checks to replace schema-level constraints
- Preparing for future cross-device syncing with CloudKit
- Maintaining data consistency between old and new databases during the transition period
- Improving user perception during automatic migration at app startup with better visual feedback
- Preparing for future removal of migration code once all users have been migrated
- Resolving data model mismatches between different components during modernization

## Performance Insights
- **SwiftData Batch Processing**: Testing confirms SwiftData's ability to efficiently handle batched article creation in background contexts. Batching operations (creating 5-10 articles at once) with intermediate saves provides significant performance benefits.
- **Background Processing**: Moving database operations off the main thread using Task.detached eliminates UI jitter and improves perceived performance.
- **Scaling Considerations**: Performance metrics suggest that handling hundreds of articles in real-world syncing is feasible with proper implementation patterns.
- **Concurrency Management**: Using Swift actor isolation and proper MainActor boundaries ensures thread safety while maintaining performance.
- **Adapter Pattern Overhead**: Converting between ArticleModel and NotificationData adds minimal overhead while providing better maintainability during transition.

## Recent Feedback
- Need for improved UI performance, especially during sync operations
- Concerns about duplicate content that should be addressed in new architecture
- Requests for more consistent error handling and recovery mechanisms
- Report of no articles showing despite database containing content due to container mismatch

## Recent Architectural Decisions

- **Data Model Adapter Pattern**:
  - Implemented ArticleModelAdapter to bridge between ArticleModel and NotificationData
  - Decoupled UI layer from database implementation details
  - Allows for gradual transition from legacy model to new SwiftData model
  - Provides clean conversion between model types without UI changes
  - Will eventually be phased out when UI is fully migrated to ArticleModel

- **Shared Components Architecture**:
  - Implemented three-tier architecture to enable code sharing:
    1. **ArticleService (Data Layer)**: API + SwiftData operations
    2. **ArticleOperations (Business Logic)**: Shared operations for article management
    3. **ViewModels (View-Specific Logic)**: NewsViewModel and NewsDetailViewModel
  - Common operations extracted to ArticleOperations:
    - Toggle read/bookmarked/archived status
    - Article deletion
    - Rich text processing
    - Batch operations
  - Benefits: Reduced duplication, improved maintainability, consistent behavior

## Immediate Priorities
1. ✅ Implement persistent storage for SwiftData testing
2. ✅ Complete migration testing with persistent storage
3. ✅ Improve migration UI with animation and remove non-functional buttons
4. ✅ Begin refactoring APIClient to use async/await
5. ✅ Implement application-level uniqueness validation logic
6. ✅ Create ArticleServiceProtocol for dependency injection and testing
7. ✅ Implement ArticleOperations for shared business logic
8. ✅ Develop NewsViewModel using ArticleOperations
9. ✅ Develop NewsDetailViewModel using ArticleOperations
10. ✅ Refactor NewsView to use NewsViewModel
11. ✅ Create ArticleModelAdapter to connect SwiftData Test and main app containers
12. ✅ Refactor NewsDetailView to use NewsDetailViewModel
13. ✅ Implement Modern Background Tasks

## Recent Changes

- **Added SyncManager Deprecation and Forwarding Implementation** (Completed):
  - Added comprehensive deprecation annotations to SyncManager class and methods:
    - Applied `@available(*, deprecated, message: "Use MigrationAdapter instead")` to SyncManager class
    - Added individual deprecation annotations to each public method with specific migration paths
    - Implemented consistent logDeprecationWarning method for runtime warnings
  - Created forwarding implementation in SyncManager:
    - Updated all public methods to forward to their MigrationAdapter counterparts
    - Fixed proper method signatures and return type conversions
    - Maintained backward compatibility while encouraging migration to modern components
    - Added method-specific deprecation messages with clear migration instructions
  - Fixed Swift closure capture semantics in MigrationService:
    - Added explicit `self.` references to backgroundTaskID property in closures
    - Resolved compiler warnings about implicit self capture in closures
  - Verified compiler generates appropriate deprecation warnings on SyncManager usage
  - Successfully integrated with existing MigrationAdapter and BackgroundTaskManager

- **Legacy Code Removal Plan - Phase 2: SyncManager Removal** (In Progress):
  - Implemented adapter pattern for legacy code migration:
    - Created MigrationAdapter with compatibility methods matching SyncManager's API
    - Developed MigrationAwareArticleService to support both legacy and modern data systems
    - Modified MigrationService to use MigrationAwareArticleService instead of direct dependencies
    - Created proper migration path that preserves existing functionality
  - Decoupled migration from direct SyncManager dependencies:
    - Redirected article processing through ArticleService
    - Redirected background task scheduling through BackgroundTaskManager
    - Added proper error handling and logging in adapter components
    - Ensured state synchronization between legacy and modern storage
  - Enabled gradual removal of legacy components:
    - Created versioned API that maintains compatibility with existing code
    - Added comprehensive documentation of adapter interfaces
    - Implemented defensive programming in transition components
    - Set up framework for complete SyncManager removal
  
- **Legacy Code Removal Plan - Phase 1: Dependency Analysis** (Completed):
  - Created comprehensive dependency map for all legacy components
  - Identified SyncManager dependencies and replacement pathways:
    - Background task scheduling → BackgroundTaskManager (completed)
    - Article sync operations → ArticleService.performBackgroundSync (completed)
    - Article processing → ArticleService.processArticleData (completed)
    - Network connectivity checking → BackgroundTaskManager.shouldAllowSync (completed)
  - Identified DatabaseCoordinator dependencies:
    - Database transactions → ArticleService direct SwiftData operations
    - Batch operations → ArticleService with SwiftData batch methods
    - Article existence checking → ArticleService with FetchDescriptor
  - Identified NotificationCenter usages requiring replacement:
    - articleProcessingCompleted → ViewModel @Published properties
    - syncStatusChanged → ViewModel @Published properties
    - State updates → ObservableObject pattern
  - Analyzed migration system dependencies:
    - MigrationCoordinator still requires DatabaseCoordinator
    - MigrationService needs SyncManager for processing articles
    - Migration UI requires notification system for progress updates
  - Documented complete migration preservation requirements
  - Created MigrationAwareArticleService design for transition period

- **Implemented Modern Background Task System** (Completed):
  - Created dedicated BackgroundTaskManager class to handle all background processing
  - Implemented proper task cancellation and scheduling with modern Swift concurrency
  - Added performQuickMaintenance method to ArticleService for optimized background operations
  - Modernized AppDelegate's executeDeferredStartupTasks with Task.detached and async/await
  - Updated push notification handling with comprehensive error management
  - Maintained API compatibility with backend while modernizing client implementation
  - Implemented proper timeout handling for background operations
  - Ensured concurrency-safe operations with Task groups and checked continuations
  - Set up proper power and network requirement handling for background tasks
