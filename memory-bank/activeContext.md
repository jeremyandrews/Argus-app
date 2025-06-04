# Active Context: Argus iOS App

## Current Development Status

After thorough code review, we've confirmed the following modernization steps have already been completed:

- **SwiftData Model Definition** (Completed):
  - `ArticleModel`, `SeenArticleModel`, and `TopicModel` properly defined with `@Model` annotations
  - Relationships defined with appropriate cascade rules
  - CloudKit compatibility implemented with default values for required properties
  - API compatibility extensions bridging old and new models
  - Proper Equatable conformance for Swift 6 compatibility

- **Repository Layer / ArticleService Implementation** (Completed):
  - Complete and robust implementation of `ArticleServiceProtocol`
  - Thread-safety using serial dispatch queue for cache operations
  - Comprehensive error handling and error propagation
  - Blob storage and retrieval functionality
  - Three-phase loading approach for rich text content

- **UI Refactoring to MVVM** (Completed):
  - Well-structured ViewModels with `@MainActor` annotations
  - Reactive UI updates using `@Published` properties
  - Combine integration for settings observations
  - Proper dependency injection patterns
  - Clean separation of UI logic from business logic

- **Background Processing Modernization** (Completed):
  - Modern Swift concurrency with async/await
  - Implementation of structured concurrency with task groups
  - Proper timeout and cancellation handling
  - Network-aware scheduling with proper power requirements

## Legacy Code Removal Status

After careful code review of the transition process, we've confirmed the following status for the legacy code removal:

- **MigrationAwareArticleService Transition** (Complete):
  - ✅ Already properly marked with deprecation notices (`@available(*, deprecated, message: "Use ArticleService directly")`)
  - ✅ All write operations (markArticle, deleteArticle) correctly forward to ArticleService
  - ✅ No longer updates the legacy database, only forwards calls
  - ✅ Legacy database access correctly limited to migration-specific methods
  - ✅ MigrationService is properly isolated and uses the deprecated service appropriately
  - ✅ Verified no other components directly use MigrationAwareArticleService outside migration system

- **ArticleModel Adoption** (Complete):
  - ✅ NewsViewModel fully converted to use ArticleModel (not NotificationData)
  - ✅ NewsDetailViewModel fully converted to use ArticleModel
  - ✅ All core data collections (filteredArticles, groupedArticles) use ArticleModel
  - ✅ ArticleModel provides comprehensive compatibility extensions for smooth transition
  - ✅ UI components audited and confirmed to use ArticleModel (LazyLoadingQualityBadges updated)
  - ✅ ShareSelectionView verified to be using ArticleModel directly
  - ✅ NotificationData extension in NewsDetailView removed as ArticleModel provides same functionality

- **One-Time Migration Architecture** (Complete and Protected):
  - ✅ MigrationCoordinator is properly self-contained
  - ✅ One-time migration tracking through UserDefaults is correctly implemented
  - ✅ Migration system is properly isolated with minimal touch points
  - ✅ Architecture supports future clean removal after all users have migrated

## Current Work Focus

- **Fixed Sync Article Count Issue** (Completed):
  - Resolved critical issue where sync was only downloading ~30 articles instead of the intended ~50
  - Root cause analysis identified two key files where sync limits were constrained:
    1. **ArticleService.swift** - `performBackgroundSync` method had hardcoded limits of 30 for general articles and 20 for topic-specific articles
    2. **ArticleOperations.swift** - `syncContent` method had a default limit parameter of 30

  - **Implementation Details**:
    - **Updated ArticleService.swift**:
      - Changed general articles sync limit from `30` to `50`
      - Changed topic-specific sync limit from `20` to `25` (balanced for multiple topics)
      - This affects the `performBackgroundSync` method that handles automatic background syncing
    
    - **Updated ArticleOperations.swift**:
      - Changed default sync limit parameter from `30` to `50`
      - This affects manual sync operations initiated through the UI
    
    - **Key Behavior Changes**:
      - **Before**: Background sync limited to 30 general articles + 20 per topic
      - **After**: Background sync allows up to 50 general articles + 25 per topic
      - **Before**: Manual sync defaulted to 30 articles maximum
      - **After**: Manual sync defaults to 50 articles maximum
    
    - **Maintains Target-Based Logic**: The underlying target-based processing logic (implemented earlier) remains intact and continues to:
      - Process articles until the target number of NEW articles is reached
      - Stop early when the target is met to save processing time
      - Handle duplicate articles correctly without counting them toward the limit
      - Provide proper progress reporting during sync operations

  - **Benefits**:
    - Users now receive the intended number of articles (up to 50) during sync operations
    - Background syncs are more comprehensive while remaining efficient
    - Manual syncs provide better coverage of available content
    - Maintains all existing performance optimizations and error handling
    - Preserves battery life through early termination when targets are met

- **Fixed Sync Logic for Target-Based Article Processing** (Completed):
  - Resolved critical issue where sync was limited to processing only 50 articles total, regardless of how many were new vs duplicates
  - Root cause: APIClient artificially limited processing to 50 articles before checking if they were actually new in the database
  - This meant users could get fewer than 50 new articles if many were duplicates, and potentially miss new content after the cutoff
  
  - **Implementation Details**:
    - **Updated APIClient.swift**:
      - Changed progress handler from `((Int, Int) -> Void)?` to `((String) -> Void)?` for phase-based reporting
      - Removed artificial limit that stopped at 50 articles
      - Now processes ALL articles the server sends (server already does smart filtering)
      - Changed from numeric progress to phase-based: "Checking for new articles..." → "Downloading new articles..."
    
    - **Enhanced ArticleService.swift**:
      - Added new target-based `processRemoteArticles` method with `targetNewArticles: Int = 50` parameter
      - Implements early termination when target number of NEW articles is reached
      - Updated `syncArticlesFromServer` to use target-based approach  
      - Updated `performBackgroundSync` to use phase-based progress reporting
      - Maintains backward compatibility with legacy method signature
    
    - **Updated ArticleServiceProtocol.swift**:
      - Updated method signatures to use phase-based progress handlers
      - Maintains API compatibility while enabling better UX

  - **Key Behavior Changes**:
    - **Before**: Stop after processing 50 articles total (includes duplicates)
    - **After**: Process until 50 NEW articles found OR all server articles processed
    - **Progress**: Standard iOS pattern: "Checking..." → "Downloading..." → "Found X new articles"
    - **Performance**: Early termination saves processing time when target is reached
    - **Reliability**: Users always get up to 50 new articles when available

  - **Benefits**:
    - More reliable sync ensuring users get the expected number of new articles
    - No missed content due to artificial processing limits
    - Better user experience with familiar iOS progress patterns
    - Improved performance through early termination
    - Maintains all existing functionality while fixing the core issue

- **Fixed Database ID Display Flow** (Completed):
  - Resolved a critical bug where article database IDs were not being displayed in the UI:
    - Root cause: Database ID was correctly extracted from JSON in `processArticleJSON` but wasn't being passed to the `ArticleModel` constructor in `ArticleService.swift`
    - This caused:
      1. Database ID field being nil in the SwiftData database
      2. ID not being included in the engine_stats JSON string
      3. No ID displayed in the UI's Argus Engine Stats section
  
  - Fix implementation:
    - Added the missing parameter to the `ArticleModel` constructor in `processRemoteArticles`:
    ```swift
    let newArticle = ArticleModel(
        // Other fields...
        databaseId: article.databaseId,  // Added this line to fix the bug
        // Other fields...
    )
    ```
    - Comprehensive documentation added in memory-bank/article-id-display-flow.md tracing article database ID flow from initial API to display in UI
  
  - Complete flow implemented and verified:
    1. Backend API includes `id` field in the article JSON
    2. `processArticleJSON` extracts the ID and places it in `ArticleJSON` object
    3. `processRemoteArticles` passes the ID to the `ArticleModel` constructor (fixed)
    4. The ID is stored in the SwiftData database as part of the ArticleModel
    5. `engine_stats` property includes the ID in the JSON string
    6. `parseEngineStatsJSON` extracts the ID from JSON string into `ArgusDetailsData` object
    7. `ArgusDetailsView` renders the ID in the UI with "Source: Engine Stats JSON" label
  
  - Added specific debugging recommendations in the documentation for troubleshooting similar issues:
    - API Response Check: Confirm the backend API is including the ID field
    - Database Storage Check: Verify the ID is stored in the ArticleModel
    - Engine Stats JSON Check: Examine the generated engine_stats JSON string
    - Parsing Check: Confirm the ID is correctly extracted from the JSON
    - UI Rendering Check: Verify the conditional display logic
  
  - The fixed implementation ensures a complete, consistent flow for handling the database ID from API to UI

- **Implemented "Explain Like I'm 5" Feature** (Completed):
  - Added support for the new `eli5` field in the JSON payload:
    - Simple, plain language explanation of complex article content
    - Designed to make news accessible to all reading levels
    - Positioned in the UI under Talking Points and before Argus Engine Stats
  - Technical implementation:
    - Added `eli5` field to `ArticleJSON` and `PreparedArticle` structs in ArticleModels.swift:
      ```swift
      struct ArticleJSON {
          // Existing fields...
          
          // New fields for R2 URL JSON payload
          let actionRecommendations: String?
          let talkingPoints: String?
          let eli5: String?
      }
      ```
    - Added corresponding property and blob storage field in ArticleDataModels.swift:
      ```swift
      @Model
      final class ArticleModel: Equatable {
          // Existing fields...
          
          // New field
          var eli5: String?
          
          // Blob storage field for rich text
          var eli5Blob: Data?
          
          // API compatibility extension
          var eli5: String? {
              get { return eli5 }
              set { eli5 = newValue }
          }
      }
      ```
    - Updated MarkdownUtilities.swift for rich text handling:
      - Added new case to `RichTextField` enum
      - Implemented section naming and mapping
      - Added text style configuration
      - Updated blob storage and retrieval
      - Included field in verification and regeneration functions
    - Updated ArticleService.swift with proper handling in:
      - `regenerateRichTextForField` method to include the eli5 field
      - `generateRichTextContent` to support the eli5 field
    - Updated DatabaseCoordinator.swift to:
      - Extract the eli5 field from JSON in `syncProcessArticleJSON`
      - Include the eli5 field in the ArticleJSON constructor
      - Update the `updateFields` method to handle the eli5 field
    
  - Format and structure:
    - `eli5`: Simple paragraph(s) explaining complex topics in plain language
    - Uses Markdown formatting for rich text display
    - Typically 2-3 paragraphs of simplified content
  
  - User benefits:
    - Makes complex news topics accessible to users of all reading levels
    - Provides an entry point for understanding difficult concepts
    - Increases overall accessibility of content
    - Maintains consistent rich text rendering across all content types

- **Implemented R2 URL JSON New Fields** (Completed):
  - Added support for two new fields in the JSON payload from the R2 URL:
    - `action_recommendations`: Concrete, actionable steps based on article content
    - `talking_points`: Thought-provoking discussion points to facilitate conversation
  - Technical implementation:
    - Added fields to `ArticleJSON` and `PreparedArticle` structs in ArticleModels.swift:
      ```swift
      struct ArticleJSON {
          // Existing fields...
          
          // New fields for R2 URL JSON payload
          let actionRecommendations: String?
          let talkingPoints: String?
      }
      ```
    - Added corresponding properties and blob storage fields in ArticleDataModels.swift:
      ```swift
      @Model
      final class ArticleModel: Equatable {
          // Existing fields...
          
          // New fields
          var actionRecommendations: String?
          var talkingPoints: String?
          
          // Blob storage fields for rich text
          var actionRecommendationsBlob: Data?
          var talkingPointsBlob: Data?
          
          // API compatibility extensions
          var action_recommendations: String? {
              get { return actionRecommendations }
              set { actionRecommendations = newValue }
          }
          
          var talking_points: String? {
              get { return talkingPoints }
              set { talkingPoints = newValue }
          }
      }
      ```
    - Updated MarkdownUtilities.swift for rich text handling:
      - Added new cases to `RichTextField` enum
      - Implemented section naming and mapping
      - Added text style configuration
      - Updated blob storage and retrieval
      - Included fields in verification and regeneration functions
    
  - Format and structure:
    - `action_recommendations`: 3-5 bullet points, each starting with a bold action verb
    - `talking_points`: 3-5 discussion points with either questions or statement/question combinations
    - Both fields use Markdown formatting for rich text display
  
  - User benefits:
    - Provides practical, actionable steps users can take based on article content
    - Facilitates sharing and conversation about articles with prepared discussion points
    - Transitions from passive consumption to active engagement with news content
    - Maintains consistent rich text rendering across all content types

- **Fixed UI Update Issue for Empty Topics and Filters** (Completed):
  - Resolved multiple related issues with UI updates:
    1. When reading the only article in a topic and closing it, the view didn't refresh to "All"
    2. Enabling/disabling filters didn't update the article list properly
    3. Background syncs required manual topic switching to see new articles
  - Root cause analysis:
    - Disconnected UI components didn't properly update the ViewModel:
      1. Article detail view closure only called basic refresh without auto-redirect logic
      2. Filter toggles didn't trigger article refresh in the ViewModel
      3. Background sync completion didn't notify the UI about new content
  - Implementation details:
    - Added a dedicated auto-redirect method in NewsViewModel:
      ```swift
      // Refreshes articles and performs auto-redirect if needed
      @MainActor
      func refreshWithAutoRedirectIfNeeded() async {
          // First do the normal refresh
          await refreshArticles()
          
          // Then check if we need to redirect
          if filteredArticles.isEmpty && selectedTopic != "All" {
              // Revert to "All" topic and refresh again
              selectedTopic = "All"
              saveUserPreferences()
              await refreshArticles()
          }
      }
      ```
    - Implemented callback-based filter updates in FilterView:
      ```swift
      private struct FilterView: View {
          @Binding var showUnreadOnly: Bool
          @Binding var showBookmarkedOnly: Bool
          var onFilterChanged: () -> Void  // New callback for filter changes
          
          var body: some View {
              // View content with onChange handlers that call the callback
              Toggle(isOn: $showUnreadOnly) {
                  Label("Unread Only", systemImage: "envelope.badge")
              }
              .onChange(of: showUnreadOnly) { _, _ in
                  onFilterChanged()
              }
          }
      }
      ```
    - Added notification posting in BackgroundTaskManager to signal UI updates:
      ```swift
      // Post notification that articles have been processed
      await MainActor.run {
          NotificationCenter.default.post(
              name: Notification.Name.articleProcessingCompleted,
              object: nil
          )
      }
      ```
    - Implemented a refreshAfterBackgroundSync method in NewsViewModel
    - Fixed Swift 6 compliance issues with explicit self references and proper error handling
  - Benefits:
    - User experience is more intuitive with automatic redirection from empty topics
    - UI promptly reflects filter changes without requiring manual refresh
    - New articles appear automatically after background sync completes
    - Better Swift 6 compatibility with explicit self references and proper error handling
  - Patterns documented in .clinerules for future implementation reference

- **Fixed Related Articles Implementation** (Completed):
  - Resolved recurring issues with related articles by completely redesigning the feature:
    ```
    Failed to parse similar_articles: Swift.DecodingError.typeMismatch(Swift.Double, Swift.DecodingError.Context(..., debugDescription: "Expected to decode Double but found a string instead.")
    ```
  - Root cause analysis identified multiple incorrect assumptions:
    - Data format assumption: Same date format (ISO8601 strings) assumed in both API and database
    - Decoder assumption: A single decoder could handle both API responses and database retrieval
    - Format consistency assumption: Related articles data would be consistent across sources
    - Error handling assumption: Parsing errors were exceptional rather than common
  
  - Implementation details:
    - Created separate context-specific models:
      ```swift
      /// API Model - specifically for API responses with ISO8601 dates
      struct APIRelatedArticle: Codable {
          let publishedDate: String? // API provides as ISO8601 string
          // Additional fields and proper CodingKeys...
          
          /// Converts API model to database model with proper date conversion
          func toRelatedArticle() -> RelatedArticle {
              return RelatedArticle(
                  // Properties with date conversion...
                  publishedDate: publishedDate != nil ? 
                      ISO8601DateFormatter().date(from: publishedDate!) : nil,
              )
          }
      }
      
      /// Database Model - for storage and UI with Date objects
      struct RelatedArticle: Codable, Identifiable, Hashable {
          // Properties including Date objects
          // Explicit Codable implementation
          // Computed formatting properties for UI
      }
      ```
    
    - Implemented two-phase decoding workflow:
      ```swift
      // Phase 1: Decode API Response (handles ISO8601 strings)
      let apiRelatedArticles = try decoder.decode([APIRelatedArticle].self, from: data)
      
      // Phase 2: Convert to database model with proper date conversion
      let databaseArticles = apiRelatedArticles.map { $0.toRelatedArticle() }
      
      // Phase 3: Store with explicit date encoding strategy
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      relatedArticlesData = try encoder.encode(databaseArticles)
      ```
      
    - Created comprehensive error handling with fallbacks:
      ```swift
      // Attempt structured decoding first
      do {
          decodedArticles = try decoder.decode([RelatedArticle].self, from: data)
      } catch {
          // Fallback to more flexible parsing if structured decode fails
          AppLogger.database.error("Primary decoding failed: \(error)")
          if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
              // Alternative parsing approach
          }
      }
      ```
      
  - Enhanced UI with progressive disclosure pattern:
    - Created dedicated `RelatedArticlesComponents.swift` with modular components
    - Implemented expandable details with `DisclosureGroup`
    - Added visual metric bars and color-coded badges
    - Included tooltips for explaining technical metrics
  
  - Comprehensive documentation:
    - Detailed in `memory-bank/related-articles-implementation.md`
    - Field definitions in `memory-bank/related-articles-fields.md`
    - Test implementation in `EnhancedRelatedArticlesTest.swift`
  
  - Benefits:
    - Complete elimination of parsing errors across all data sources
    - Clear separation of API and database concerns
    - Self-documenting code with explicit context handling
    - Enhanced user experience with intuitive UI
    - Reusable pattern for handling other complex data transformations

- **Fixed Argus Engine Stats Display** (Completed):
  - Resolved issues with engine stats display in NewsDetailView:
    - Fixed JSON field parsing for proper data extraction from API responses
    - Modified `parseEngineStatsJSON` to handle snake_case field names from backend API (`elapsed_time`, `system_info`)
    - Implemented proper fallback mechanisms for missing or malformed data
    - Enhanced the UI components to display engine statistics in a user-friendly format
  - Implementation details:
    - Rebuilt supporting data models and UI components that were needed for displaying stats:
      - Added `ContentSection` struct for representing section data
      - Created specialized `ArgusDetailsView` for displaying engine metrics
      - Implemented `SimilarArticleRow` for related articles section
      - Added sharing capabilities with `ShareSelectionView` and `ActivityViewController`
    - Added robust JSON parsing to extract critical fields:
      - `model`: Engine model name (e.g., "mistral-small:24b-instruct-2501-fp16")
      - `elapsed_time`: Processing duration in seconds
      - `stats`: Article processing metrics in colon-separated format
      - `system_info`: Build information and runtime metrics
    - Enhanced content dictionary building to properly transfer engine stats data
    - Implemented helper methods for formatting and displaying engine statistics
  - Key improvements:
    - Users can now see comprehensive statistics about AI processing for each article
    - Proper display of processing time, model version, and metrics
    - Consistent rendering of stats across all articles regardless of source
    - Robust error handling with sensible defaults for missing data
    - Smooth integration with existing NewsDetailView architecture

- **Fixed Database Duplicate Content Issue** (Completed):
  - Successfully identified and resolved issue where duplicate articles were being added to database during sync operations
  - Root cause analysis revealed potential race conditions in the article processing flow:
    - Articles could be processed twice if a sync was interrupted and restarted
    - The single transaction save at the end of processing created a window for race conditions
    - Different ModelContext instances might not see each other's uncommitted changes
  - Implementation details:
    - Refactored `processRemoteArticles` in ArticleService to use batched transaction management
    - Articles are now processed in batches of 10 with explicit transaction boundaries (context.save())
    - Each batch is an atomic operation with duplicate checks within the same transaction
    - Rich text generation happens in separate batches of 5 articles after all inserts are completed
    - Added comprehensive logging to track transaction boundaries and batch progress
  - Key improvements:
    - Each batch is committed to the database before the next batch starts, preventing partial sync issues
    - Duplicate checks now see fully committed records from previous batches
    - Processing in smaller batches improves performance and memory usage
    - Transaction boundaries provide clean restart points if sync is interrupted
    - No more duplicate articles even if sync is exited and restarted

- **Improved Sync Status Indicator with Real-Time Feedback** (Completed):
  - Enhanced the article download process to provide per-article progress updates:
    - Modified `APIClient.fetchArticles` to accept a progressHandler parameter
    - Added progress updates at each stage of the download process:
      - Initial "Checking for new articles..." during URL fetching
      - "Downloading 0 of X articles..." after article URLs are retrieved
      - "Downloading 1 of X articles...", "Downloading 2 of X articles..." etc. during each article download
    - Updated `ArticleService.syncArticlesFromServer` to pass the progressHandler to APIClient
  - Technical implementation details:
    - Enhanced loop in `fetchArticles` to track the current article index
    - Utilized the enumerate() method to access both the index and URL in the loop
    - Added progress updates before and after each article fetch
    - Created a predictive total count based on the number of article URLs
  - User experience improvements:
    - Eliminated the issue where "Checking for new articles..." would display for 99% of the sync time
    - Added real-time countdown feedback showing exactly which article is being downloaded
    - Provided clear visual indication of sync progress with exact article counts
    - Increased transparency into which part of the sync operation is taking time
  - Benefits for users:
    - Better understanding of sync progress and how much longer it will take
    - Clearer feedback during potentially long network operations
    - Improved perception of app responsiveness during sync operations
    - More informative status messages during the sync process

- **Fixed Rich Text Formatting and Size Issue** (Completed):
  - Successfully resolved issue where article content was displayed either as raw markdown or with text too small:
    - Root cause identified: NonSelectableRichTextView was directly using the original attributed string without proper font sizing
    - When displaying sections like Summary or Critical Analysis, rich text was properly formatted but too small to read
    - The issue affected both article lists in NewsView and detailed article views in NewsDetailView
  - Implementation details:
    - Modified NonSelectableRichTextView.updateUIView to create a mutable copy of the original attributed string
    - Added font size normalization that preserves all formatting attributes while ensuring consistent readable size:
      ```swift
      // Create a mutable copy to preserve formatting but ensure proper font size
      let mutableString = NSMutableAttributedString(attributedString: attributedString)
      
      // Apply system body font size to all text while preserving other attributes
      let bodyFont = UIFont.preferredFont(forTextStyle: .body)
      mutableString.enumerateAttributes(in: NSRange(location: 0, length: mutableString.length)) { attributes, range, _ in
          if let existingFont = attributes[.font] as? UIFont {
              // Create a new font with the same characteristics but body font size
              let newFont = existingFont.withSize(bodyFont.pointSize)
              mutableString.addAttribute(.font, value: newFont, range: range)
          } else {
              // If no font exists, add the body font
              mutableString.addAttribute(.font, value: bodyFont, range: range)
          }
      }
      ```
    - Preserved all formatting attributes like bold, italic, and headers while normalizing font size
    - Ensured all text is rendered at the system's preferred body text size for readability
  - Results:
    - Article content now displays with proper rich text formatting (bold, italic, headers) at a consistent, readable size
    - Both the article list view and detail view show properly formatted content at the same size
    - Text no longer appears as raw markdown with visible formatting characters
    - Content is properly readable without being too small or requiring pinch-to-zoom
  - Key learnings:
    - When working with NSAttributedString, it's important to preserve formatting while ensuring readability
    - The NonSelectableRichTextView implementation needed to balance preserving styling with consistent sizing
    - This fix aligns with the guidance in .clinerules about using NonSelectableRichTextView for article content
    - Rich text rendering requires careful attribute handling to maintain both formatting and readability

## Project Status Overview
- **Development Phase**: Core functionality completed - entering stabilization and refinement phase
- **All Critical Bugs Resolved**: Persistent blob storage, interface consistency, and CloudKit integration issues fixed
- **Primary Focus Areas**: Additional testing, performance optimization, and UX refinement for public release
- **Architecture Refinements**: ModernizationLogger implemented for transition period monitoring and diagnostics
- **User Experience**: Improved error recovery, eliminated sync jitter, enhanced offline capabilities, and simplified to one-time migration
- **Cross-Device Capabilities**: CloudKit integration errors resolved, enabling reliable iPhone/iPad syncing
- **Migration System**: Successfully converted from temporary to production migration mode with one-time execution
- **API Connectivity**: Implemented graceful degradation patterns for API connectivity issues
- **Simplified Implementation**: Removed dual-implementation pattern by simplifying MigrationAwareArticleService
- **Settings Functionality**: Fixed issues with settings updates using Combine-based observation in ViewModels
- **Enhanced Related Articles**: Added additional vector and entity similarity metrics to provide deeper insight into article relationships
- **Sync Reliability**: Fixed target-based sync logic to ensure users always get the expected number of new articles
- **Sync Article Count**: Resolved sync limit constraints that were preventing users from receiving the full intended 50 articles per sync

## Current Work Focus

- **Fixed Tags Section Implementation** (Completed):
  - Resolved issue where Tags section was not appearing in the UI despite being partially implemented
  - Root cause analysis identified two missing pieces in the data storage pipeline:
    1. **PRIMARY ISSUE**: ArticleModel constructor was missing `self.entities = entities` line
    2. **SECONDARY ISSUE**: MarkdownUtilities verification functions were missing `.clusterSummary` field
  - Technical implementation:
    - **Updated ArticleDataModels.swift**: Added missing storage line in ArticleModel constructor
    - **Updated MarkdownUtilities.swift**: Added `.clusterSummary` to field lists in `verifyAllBlobs` and `regenerateAllBlobs` functions
  - Complete pipeline verification confirmed all other components were correctly implemented:
    - ✅ Entity struct and data models
    - ✅ JSON extraction in DatabaseCoordinator
    - ✅ API pipeline in ArticleService
    - ✅ RichTextField enum includes all fields
    - ✅ UI components (TagsView) complete and functional
    - ✅ Section integration in NewsDetailView
  - Benefits:
    - Tags section now properly displays extracted entities from articles
    - Users can see people, organizations, locations, events, and other entities mentioned in articles
    - Visual distinction between primary and secondary importance entities
    - Interactive grid layout with type-specific icons and colors
    - Complete end-to-end functionality from API to UI display
  - This fix demonstrates the importance of following the complete implementation checklist for new sections

- **Fixed Related Articles Cluster Summary Text Display** (Completed):
  - Resolved issue where cluster summary text was not appearing above the related articles list in the Related Articles section
  - Root cause analysis identified the exact same two issues that affected the Tags section:
    1. **PRIMARY ISSUE**: ArticleModel constructor was missing `self.clusterSummary = clusterSummary` assignment line
    2. **SECONDARY ISSUE**: MarkdownUtilities `regenerateAllBlobs` function was missing `.clusterSummary` in its field list
  - Technical implementation:
    - **Updated ArticleDataModels.swift**: Added missing assignment lines in ArticleModel constructor:
      - `self.clusterSummary = clusterSummary`
      - `self.clusterSummaryBlob = clusterSummaryBlob`
    - **Updated MarkdownUtilities.swift**: Added `.clusterSummary` to the field list in `regenerateAllBlobs` function
  - Complete pipeline verification confirmed all other components were correctly implemented:
    - ✅ Cluster summary field defined in ArticleModel
    - ✅ JSON extraction pipeline established
    - ✅ RichTextField enum includes `.clusterSummary`
    - ✅ UI components in RelatedArticlesComponents.swift properly display cluster summary
    - ✅ Section integration in NewsDetailView includes cluster summary handling
  - Benefits:
    - Cluster summary text now properly appears above related articles list
    - Users get explanatory context about why articles are grouped together
    - Enhanced user experience with contextual information about article relationships
    - Complete end-to-end functionality from API to UI display
  - This demonstrates the pattern: both Tags and Related Articles cluster summary experienced identical implementation gaps in the data storage pipeline

- **Enhanced Related Articles with Similarity Metrics** (Completed):
  - Implemented comprehensive similarity metrics to explain why articles are related:
    - **Vector Similarity**: 
      - `vectorScore`: Raw cosine similarity between article embeddings
      - `vectorActiveDimensions`: Embedding dimensions contributing to similarity
      - `vectorMagnitude`: Vector strength indicator (L2 norm)
    
    - **Entity Similarity**:
      - `entityOverlapCount`: Total shared entities between articles
      - `primaryOverlapCount`: Primary (most important) shared entities
      - `personOverlap`: People/persons similarity score
      - `orgOverlap`: Organizations similarity score
      - `locationOverlap`: Locations similarity score
      - `eventOverlap`: Events similarity score
      - `temporalProximity`: Time closeness score
      
    - **Formula Explanation**:
      - Human-readable explanation of the similarity calculation
      - Example: "60% vector similarity (0.85) + 40% entity similarity (0.70), where entity similarity combines person (30%), organization (20%), location (15%), event (15%), and temporal (20%) factors"
      
  - UI Implementation:
    - Designed with progressive disclosure pattern to prevent information overload
    - Main components in `RelatedArticlesComponents.swift`:
      - `EnhancedRelatedArticlesView`: Main container for article list
      - `EnhancedRelatedArticleRow`: Individual article with expandable details  
      - `SimilarityBadge`: Visual indicator of similarity strength
      - `MetricBarView`: Visual bar for comparing metrics
      - `InfoTooltip`: Context-sensitive help for technical metrics
    
    - Specialized detail components:
      - `VectorDetailsView`: For displaying embedding similarity
      - `EntityDetailsView`: For displaying entity overlap metrics
      - `FormulaExplanationView`: For explaining calculation formula
    
  - Key improvements:
    - Transparency into the "why" behind article relationships
    - Educational elements explaining AI similarity concepts
    - Interactive elements allowing users to explore details as desired
    - Consistent visual language with rest of the application
    - Robust error handling with fallbacks for missing data
    
  - Documentation and testing:
    - Full implementation details in `memory-bank/related-articles-implementation.md`
    - Field descriptions in `memory-bank/related-articles-fields.md`
    - Test implementation with sample data in `EnhancedRelatedArticlesTest.swift`
