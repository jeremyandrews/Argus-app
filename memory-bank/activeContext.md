# Active Context: Argus iOS App

## Current Work Focus
- **Active Development Phase**: Modernization implementation in progress
- **Primary Focus Areas**: SwiftData migration active, preparing for MVVM architecture adoption, async/await implementation, CloudKit compatibility
- **User Experience Improvements**: Improving UI responsiveness, eliminating sync jitter, and enhancing offline capabilities
- **Cross-Device Capabilities**: Preparing SwiftData models for future CloudKit integration to enable iPhone/iPad syncing

## Recent Changes
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

## Next Steps

### Phase 1: Setup and Model Migration
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

### Phase 2: Networking and API Refactor
3. **Create Article API Client**:
   - Refactor APIClient to use async/await for all API calls
   - Implement key API methods for article fetching and device authentication
   - Ensure proper error handling and response validation

5. **Build ArticleService (Repository Layer)**:
   - Create bridge between API and SwiftData
   - Implement methods for syncing, retrieving, and updating articles
   - Set up proper concurrency handling with async/await

### Phase 3: MVVM Implementation and UI Refactor
6. **Create ViewModels and Refactor UI Components**:
   - Create NewsViewModel, ArticleDetailViewModel, and other required ViewModels
   - Implement proper @Published properties and state management
   - Refactor SwiftUI views to use ViewModels instead of direct data access
   - Move business logic from views to corresponding ViewModels

### Phase 4: Syncing and Background Tasks
7. **Implement Robust Background Processing**:
   - Replace current syncing with modern background tasks approach
   - Implement push notification handling with async/await
   - Set up periodic syncing using .backgroundTask or BGTaskScheduler
   - Ensure proper task cancellation and expiration handling

## Active Decisions and Considerations
- **Architectural Approach**: 
  - MVVM pattern chosen for clear separation of concerns and better testability
  - SwiftData selected for modern persistence with Swift-native syntax
  - Swift concurrency (async/await) for improved readability and performance

- **Migration Strategy**: 
  - Phased implementation to ensure continuous app functionality
  - Testing each phase thoroughly before moving to next
  - Keeping compatibility with existing systems during transition

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
- Ensuring seamless user experience during automatic migration at app startup
- Preparing for future removal of migration code once all users have been migrated

## Performance Insights
- **SwiftData Batch Processing**: Testing confirms SwiftData's ability to efficiently handle batched article creation in background contexts. Batching operations (creating 5-10 articles at once) with intermediate saves provides significant performance benefits.
- **Background Processing**: Moving database operations off the main thread using Task.detached eliminates UI jitter and improves perceived performance.
- **Scaling Considerations**: Performance metrics suggest that handling hundreds of articles in real-world syncing is feasible with proper implementation patterns.
- **Concurrency Management**: Using Swift actor isolation and proper MainActor boundaries ensures thread safety while maintaining performance.

## Recent Feedback
- Need for improved UI performance, especially during sync operations
- Concerns about duplicate content that should be addressed in new architecture
- Requests for more consistent error handling and recovery mechanisms

## Immediate Priorities
1. ✅ Implement persistent storage for SwiftData testing
2. ✅ Complete migration testing with persistent storage
3. Begin refactoring APIClient to use async/await
4. Implement application-level uniqueness validation logic
5. Develop and test initial ViewModel prototypes
