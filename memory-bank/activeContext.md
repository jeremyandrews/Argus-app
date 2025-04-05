# Active Context: Argus iOS App

## Current Work Focus
- **Active Development Phase**: Modernization planning and implementation
- **Primary Focus Areas**: MVVM architecture adoption, SwiftData migration, async/await implementation
- **User Experience Improvements**: Improving UI responsiveness, eliminating sync jitter, and enhancing offline capabilities

## Recent Changes
- Implemented SwiftData models to support the modernization plan:
  - Created Article, SeenArticle, and Topic models with proper SwiftData annotations
  - Added proper unique constraints to prevent duplicates (ID and jsonURL for articles)
  - Set up appropriate relationships between models with cascade delete rules
  - Ensured field alignment with backend API structure for seamless integration
  - Designed models to support the upcoming MVVM architecture
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
1. **Initialize SwiftData Container**:
   - Configure ModelContainer in ArgusApp
   - Set up proper dependency injection via .modelContainer()
   - Implement verification process for SwiftData persistence

2. **Migrate Existing Data**:
   - Create migration routine to convert existing stored data to SwiftData models
   - Implement fallback mechanism to fetch fresh data if local data is incompatible
   - Test migration with various data scenarios

### Phase 2: Networking and API Refactor
4. **Create Article API Client**:
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

## Recent Feedback
- Need for improved UI performance, especially during sync operations
- Concerns about duplicate content that should be addressed in new architecture
- Requests for more consistent error handling and recovery mechanisms

## Immediate Priorities
1. Finalize detailed implementation plan for each modernization phase
2. Create SwiftData models aligned with current data structures
3. Begin refactoring APIClient to use async/await
4. Develop and test initial ViewModel prototypes
