# Active Context: Argus iOS App

## Current Work Focus

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

## Current Work Focus
- **Active Development Phase**: Modernization implementation in progress with focus on error handling, robustness, and simplifying migration
- **Critical Bug Resolution**: Working to resolve persistent blob storage issues after multiple attempted fixes
- **Primary Focus Areas**: Implementing error handling improvements, CloudKit integration fixes, API resilience enhancements, and simplifying migration system
- **Architecture Refinement**: Creating ModernizationLogger for transition period monitoring and diagnostics
- **User Experience Improvements**: Improving error recovery, eliminating sync jitter, enhancing offline capabilities, and converting to one-time migration
- **Cross-Device Capabilities**: Addressing CloudKit integration errors to enable future iPhone/iPad syncing
- **Migration System Refinement**: Converting from temporary to production migration mode with one-time execution
- **API Connectivity**: Implementing graceful degradation patterns for API connectivity issues
- **Duplicate Implementation Removal**: Removing dual-implementation pattern for syncing and displaying content by simplifying MigrationAwareArticleService
- **Settings Functionality**: Fixing issues with settings updates not being observed by view models

## Recent Changes

- **Fixed Article Navigation Flicker Issue** (Completed):
  - Resolved visual issue when navigating between articles using chevron buttons:
    - Problem symptoms: When navigating to a new article, three different states would display in rapid succession:
      1. First showing the article as bold/unread
      2. Then showing it with unformatted content
      3. Finally showing it with properly formatted content
    - Root cause: The UI was being updated with unformatted content before formatted blobs were extracted
  - Implementation details:
    - Modified `navigateToArticle(direction:)` in `NewsDetailViewModel.swift` to use a content-first approach:
      ```swift
      // Extract formatted content from blobs BEFORE updating the UI
      var extractedTitle: NSAttributedString? = nil
      var extractedBody: NSAttributedString? = nil
      var extractedSummary: NSAttributedString? = nil
      
      // After extraction is complete, update the UI in a single operation
      await MainActor.run {
          // CRITICAL: Set formatted content BEFORE triggering UI refresh
          titleAttributedString = extractedTitle
          bodyAttributedString = extractedBody
          summaryAttributedString = extractedSummary
          
          // Force UI refresh AFTER all content is ready
          contentTransitionID = UUID()
          scrollToTopTrigger = UUID()
      }
      ```
    - Took advantage of the fact that title and body blobs are always available in the database
    - Restructured code to extract all blob content first, then update UI only once with fully formatted content
    - Removed unused variables causing compiler warnings
  - Results:
    - Navigation between articles now shows only the final formatted state with no flickering
    - No intermediate unformatted content is displayed during transitions
    - Improved user experience with smoother, more professional transitions
    - Eliminated jarring content changes that were distracting when reviewing multiple articles
  - Key learnings:
    - When working with formatted content, it's better to wait until all content is ready before updating UI
    - The content-first approach (versus UI-first) provides a better user experience for rich content
    - Taking advantage of pre-generated blobs can significantly improve performance
    - Single UI updates are less jarring than staged UI updates

- **Fixed Cloud Build String Extension Issue** (Completed):
  - Resolved build error that occurred in Apple's cloud build but not in local Xcode build:
    - Error symptoms: `Value of type 'String' has no member 'extractDomain'` in DatabaseCoordinator.swift
    - Root cause: In cloud builds, String extensions defined in other files may not be visible across file boundaries
  - Implementation details:
    - Modified `DatabaseCoordinator.swift` to use the private standalone function instead of calling it as an extension method:
      ```swift
      // Before:
      let domain = url.extractDomain()
      
      // After:
      let domain = extractDomain(from: url)
      ```
    - Used the already existing private function implementation in DatabaseCoordinator.swift
    - Maintained identical functionality while ensuring compatibility with cloud build environments
  - Results:
    - App now builds successfully in Apple's cloud build environment
    - No functional changes, just improved build reliability
    - Consistent domain extraction behavior between local and cloud builds
  - Key learnings:
    - Cloud build environments may process files differently than local Xcode builds
    - Prefer using local functions over extensions when working across file boundaries in cloud builds
    - Using standalone functions creates more predictable behavior across different build environments
    - This pattern aligns with previous fixes for similar issues in other parts of the app

- **Fixed Cloud Build Domain Extraction Scope Error** (Completed):
  - Resolved build error that occurred in Apple's cloud build but not in local Xcode build:
    - Error symptoms: `Cannot find 'extractDomain' in scope` in DatabaseCoordinator.swift and ArticleModels.swift
    - Root cause: Global functions may not be properly visible across file boundaries in cloud build environments
  - Implementation details:
    - Duplicated the `extractDomain(from:)` function directly in both files that need it:
      ```swift
      // Function duplicated in both files that need it
      private func extractDomain(from urlString: String) -> String? {
          // Implementation
      }
      ```
    - Made the function private to each file to avoid potential naming conflicts
    - Maintained identical implementation in both files to ensure consistent behavior
  - Results:
    - App now builds successfully in both local Xcode and Apple's cloud build environment
    - No functional changes, just improved build reliability
    - Self-contained files with no external function dependencies
  - Key learnings:
    - Cloud build environments may process files in a different order than local builds
    - Functions defined in one file may not be visible to other files during cloud builds
    - Sometimes direct duplication is more reliable than elegant centralization for build systems
    - Each file containing all its dependencies makes it more resilient to build order issues

- **Fixed Swift 6 String Interpolation Issues with RichTextField** (Completed):
  - Resolved compiler errors related to RichTextField enum in string interpolation:
    - Problem: Swift 6 is more strict about type safety and requires CustomStringConvertible for string interpolation
    - Error symptoms: "Type of expression is ambiguous without a type annotation" when using RichTextField in strings
  - Implementation details:
    - Identified that RichTextField enum was used in string interpolation but didn't conform to CustomStringConvertible
    - Added explicit String conversion using `String(describing:)` in all places where RichTextField was used:
      ```swift
      // Before:
      AppLogger.database.debug("Generating rich text content for field: \(field) on article \(articleId)")
      
      // After:
      AppLogger.database.debug("Generating rich text content for field: \(String(describing: field)) on article \(articleId)")
      ```
    - Fixed multiple similar issues throughout ArticleService.swift
    - Made body text loading in ArticleService more robust with safe unwrapping
  - Specific fixes included:
    - Corrected `bodyText = article.body` to handle non-optional String properly
    - Fixed all string interpolation instances using `String(describing:)` wrapper
    - Made RichTextField enum conform to CaseIterable to enable iteration in diagnostic functions
  - Results:
    - All compiler errors related to string interpolation resolved
    - ArticleService now builds successfully in Swift 6 mode
    - Type-safety warning messages eliminated
    - Section blobs now properly save to the database with context
  - Key learnings:
    - Swift 6 requires explicit CustomStringConvertible for string interpolation of custom types
    - The `String(describing:)` wrapper provides a clean solution without modifying enum definitions
    - When working with enums in string contexts, it's important to provide proper string conversion

- **Fixed Article Content Display Issue in NewsView** (Completed):
  - Successfully resolved the display issue where formatted article content wasn't properly displayed in NewsView:
    - Initial problem: Text appeared as faint gray with improper formatting and was wrapping off screen edges in NewsView
    - Text displayed correctly in NewsDetailView but not in NewsView despite using the same data
  - Root cause identified:
    - NewsView and NewsDetailView used completely different UI components to render rich text:
      - NewsView was using `AccessibleAttributedText` component
      - NewsDetailView was using `NonSelectableRichTextView` component 
    - These components have fundamental internal differences:
      - Different width constraints (32px vs 40px padding)
      - Different font handling (`NonSelectableRichTextView` forces body font on all text)
      - Different text container configurations
  - Solution implemented:
    - Modified `summaryContent` method in NewsView.swift to use `NonSelectableRichTextView` instead of `AccessibleAttributedText`
    - Kept the secondary text color for visual consistency
    - Removed any modifiers that might interfere with proper text wrapping
  - Results:
    - Text now displays consistently in both views with proper formatting and wrapping
    - Article body content is fully visible and formatted correctly
    - No text stretches off screen edges
  - Key learnings:
    - Component selection is critical - seemingly similar UI components can have very different rendering behaviors
    - Consistency between views should extend to the actual UI components used, not just visual styling
    - When rich text rendering issues occur, investigate the fundamental component differences first
    - Use the same UI component across the app for the same type of content display

- **Fixed Swift 6 Equatable Conformance Issue** (Completed):
  - Successfully resolved Equatable conformance issues with SwiftData models in Swift 6:
    - Identified a complex interaction between SwiftData's `@Model` macro and Swift 6's handling of Equatable conformances
    - Cleaned up NewsDetailViewModel.swift by removing obsolete comment about moved Equatable implementation
    - Kept the necessary `hash(into:)` implementation which is important for collections
    - Updated ArgusApp.swift to use ArticleModel instead of NotificationData in all FetchDescriptor instances
    - Fixed field name references in predicates to match ArticleModel (e.g., date → addedDate)
  - Implemented solution confirmed that in-class Equatable implementation in model classes is the correct approach:
    - The SwiftData models in ArticleDataModels.swift (ArticleModel, SeenArticleModel, TopicModel) were already 
      using the correct pattern with in-class Equatable implementation
    - Conflicts arose from remnants of previous implementations in other files
    - The `@Model` macro in Swift 6 generates partial Equatable machinery that conflicts with explicit implementations
  - Key learnings for SwiftData models in Swift 6:
    - Use in-class Equatable conformance and implementation for SwiftData models
    - Avoid duplicate implementations across files (extensions, etc.)
    - Maintain Hashable support through proper `hash(into:)` implementations where needed
    - Be cautious about using NotificationData (legacy class) with SwiftData contexts

- **Fixed Swift 6 Compatibility Issues** (In Progress, Partially Successful):
  - Tackled Swift 6 compilation errors across multiple files:
    - Fixed Equatable protocol conformance issues for SwiftData models
    - Addressed issues with `@Model` classes and their Equatable implementations
    - Several approaches attempted with varying success:
      - Initially tried adding explicit Equatable protocol to class declarations (`final class ArticleModel: Equatable`)
      - Also tried implementing Equatable in extensions (`extension ArticleModel: Equatable`)
      - Ultimately removed explicit Equatable conformance from class declarations while keeping extension methods
    - Attempted to avoid "Invalid redeclaration of '=='" errors while still maintaining Equatable functionality
    - Fixed improper optional handling in NewsView.swift for Date properties
    - Fixed nil coalescing operators on non-optional properties (`article.title ?? ""` to `article.title`)
    - Added proper try-catch error handling to methods where needed
  - Current status:
    - Many issues resolved but Equatable conformance errors persist
    - Some conflicts between the SwiftData auto-generated Equatable conformance and manual implementations
    - Need a more fundamental approach to resolve the remaining Equatable issues
  - Learned key insights about SwiftData and Swift 6:
    - SwiftData models generate some built-in protocol conformances that can conflict with manual implementations
    - Swift 6 is more strict about optional handling and explicit self-references
    - Type conversion between model types still needs refinement

- **7th Attempted Fix for Blob Persistence Issue** (In Progress, Unsuccessful):
  - Identified fundamental type system conflict at the root of the problem:
    - Swift predicates cannot directly compare properties between different model types (NotificationData vs ArticleModel)
    - The system has architectural ambiguity with both NotificationData class and ArticleModel competing
    - Predicate errors suggest fundamental type compatibility issues in SwiftData context
  - Implemented workarounds that still don't fully resolve the issue:
    - Modified ArticleServiceProtocol to use NotificationData consistently in method signatures
    - Used string-based UUID comparison to avoid direct type comparisons
    - Implemented manual filtering instead of predicates in both MigrationAdapter and MigrationAwareArticleService
    - Fixed the groupedArticles property name in NewsViewModel to use "articles" instead of "notifications"
    - Tried various approaches in MigrationAdapter.standardizedArticleExistsCheck to avoid predicates
  - Critical remaining errors:
    - SwiftData still has type conversion issues in predicates despite our workarounds
    - Some predicate errors persist even after type conversion
    - There appears to be a deep architectural conflict that may require a more fundamental redesign
  - Current situation:
    - UI is partially working but database persistence of blobs remains unreliable
    - Type conversion and context issues continue to plague the system
    - Will need a more comprehensive architectural solution that may involve significant refactoring

- **Attempted Fix for Blob Loading Issue** (Previous Attempt, Unsuccessful):
  - Implemented a comprehensive solution that didn't fully resolve the issue:
    - Created centralized context management in ArticleOperations:
      - Added `getArticleWithContext(id:)` to retrieve both article representations with contexts
      - Fixed usage of the read-only modelContext property
      - Improved logging for better diagnosis of context issues
    - Streamlined the ViewModel implementation:
      - Simplified loadContentForSection to use a centralized approach
      - Eliminated redundant code and unused variables
      - Updated the loadInitialMinimalContent method in NewsDetailView 
    - Updated ArticleModelAdapter and ArticleOperations to handle context correctly
    - Fixed unused variables in NewsView+Extensions to eliminate compiler warnings
  - Analysis of logs after implementation:
    - The unified context mechanism correctly retrieves articles: `✅ Created fully context-aware article pair`
    - When a blob doesn't exist, it's correctly generated: `⚙️ Converting markdown to attributed string`
    - The generated blob is successfully saved to the database: `✅ Saved Relevance blob to database (2519 bytes) - verified`
    - CloudKit successfully syncs the changes: `CoreData: CloudKit: Modify records finished`
    - **However**: The next time the same section is accessed, it still doesn't find the blob in the database
  - Key insights from this attempt:
    - The fix correctly addresses the context preservation during a single session
    - The blobs are being properly generated and saved to the database
    - CloudKit is properly exporting the changes to iCloud
    - The issue appears to be related to blob retrieval between different sessions or views
    - There may be a more fundamental architectural issue with how blobs are stored or retrieved
  - Potential future approaches:
    - Investigate possible database schema issues that might prevent proper blob retrieval
    - Examine the CoreData/CloudKit integration more closely for potential transaction issues
    - Review the blob storage and retrieval paths for potential inconsistencies
    - Consider alternatives to the current blob storage approach, such as dedicated blob tables
    - Implement a more robust caching layer to reduce reliance on database blob retrieval

- **Continued Investigation of Section Expansion Issues** (In Progress):
  - Fixed several aspects but core issue remains:
    - We addressed race conditions by properly distinguishing between "content already loaded" and "content currently loading"
    - We fixed duplicate loading triggers by removing redundant onAppear handlers
    - We corrected unused normalization code to reduce compiler warnings
    - We fixed the SwiftDataContainer access in ArticleOperations by properly handling the non-optional container property
  - New evidence from logs after our changes:
    - Model context is still sometimes missing: `⚠️ Article D7788754-71A2-4AAB-9032-87928122462C has no model context - attempting to get fresh copy`
    - Even fresh copies lack context: `⚠️ Fresh article copy also has no context`
    - However, the system successfully falls back to generation: `⚙️ PHASE 2: Blob loading failed, attempting rich text generation for Context & Perspective`
    - Content generation works correctly: `✅ Context & Perspective blob contains valid attributed string`
    - The blob is successfully saved: `✅ Saved Context & Perspective blob to database (10791 bytes) - verified`
    - CloudKit sync properly syncs the changes: `CoreData: warning: CoreData+CloudKit: -[PFCloudKitExporter exportOperationFinished:withSavedRecords:deletedRecordIDs:operationError:](688): Modify records finished`
  - Current understanding:
    - There's a fundamental issue with model context preservation during article access and conversion
    - The fallback generation pathway works as expected and properly saves the generated content
    - CloudKit sync is handling the saved blobs correctly for cross-device syncing
    - The fixes we've implemented have improved the situation but haven't resolved the core context issue
  - Next steps:
    - Further research into SwiftData context propagation - might need to audit all conversion points in lifecycle
    - Consider a more radical pattern change that addresses the architectural disconnect
    - Focus on creating clear context preservation rules in the codebase with better documentation

- **Fixed Section Rich Text Loading Issue** (Completed):
  - Resolved issue where article sections were always falling back to raw markdown text:
    - Root cause identified: Articles without valid SwiftData model context couldn't persist rich text blobs to database
    - Log evidence: `⚠️ Article 31F48F86-D5AB-44DF-83D2-4EA4511A831F has no model context - not saved to database`
    - Key issue: Successful in-memory blob creation wasn't resulting in database persistence
  - Implemented a comprehensive solution:
    - Added context validation and multiple fallback paths for saving blobs:
      - First attempt: Direct save via article context
      - Second attempt: Save via current ArticleModel
      - Final attempt: Fetch fresh ArticleModel and retry save
    - Added robust verification system to confirm database persistence
    - Enhanced ArticleOperations.getArticleWithContext to better handle missing context
    - Added preemptive ArticleModel loading in NewsDetailViewModel initialization
  - Fixed code implementation mistake:
    - Removed duplicate `verifyBlobInDatabase` method that was causing compilation error
    - Retained the more comprehensive verification implementation that checks blob validity
    - Added careful blob unarchiving verification to ensure blobs contain valid content
  - This fix ensures:
    - Rich text blobs properly persist to the database and CloudKit
    - Article sections load immediately from cached blobs
    - Section loading falls back to generation only when necessary
    - The app provides better diagnostics when blob persistence fails
    - The implementation follows Swift best practices for verification and error handling

- **Fixed Swift Closure Capture Semantics Issues** (Completed):
  - Fixed Swift compiler warnings about implicit self-capture in closures:
    - Added explicit `self.id` references in MarkdownUtilities.swift when capturing ID in verifyAllBlobs()
    - Added explicit `self.id` references in ArticleModelAdapter.swift when logging in updateBlobs()
    - Added explicit `self.backgroundTaskID` references in MigrationService.swift for task registration/completion
  - Improved code organization and maintainability:
    - Standardized consistent self-capture patterns throughout the codebase
    - Fixed all compiler warnings related to closure captures
    - Made all closures use consistent capture semantics
  - Fixed access control issues:
    - Changed `getRichTextFieldForSection` access level from private to public in NewsDetailViewModel.swift
    - Implemented identical standalone version in NewsDetailView.swift to avoid access control issues
    - Ensured consistent implementation between view and view model for section name mapping
  - Benefits:
    - Eliminated all Swift compiler warnings related to "Reference to property in closure requires explicit use of 'self'"
    - Improved code robustness by preventing subtle bugs related to implicit self-capture
    - Ensured that the codebase follows Swift best practices for closure capture semantics
    - Fixed potential memory leaks and capture-related issues

- **Fixed Section Viewing Issues in Argus App** (Completed):
  - Resolved problem where sections were falling back to displaying raw text:
    - Fixed inconsistent field naming between view and view model implementations
    - Standardized section name to field key mapping across components
    - Removed duplicate `getRichTextFieldForSection` implementation in NewsDetailViewModel.swift
    - Made section name mapping consistent by using identical implementations
  - Addressed root cause of section viewing problems:
    - Ensured proper bridging between display names ("Critical Analysis") and internal keys ("criticalAnalysis")
    - Enhanced key consistency with normalized field name across the blob loading process
    - Added robust verification after blob saving for better error reporting
    - Implemented consistent self-referencing in closures to prevent Swift capture semantics errors
  - Enhanced diagnostics:
    - Added detailed logging including both human-readable section names and normalized keys
    - Improved error messages to help diagnose future section loading issues
    - Added proper log tracking for successful blob storage operations
  - This fix ensures that:
    - All article sections display rich text formatting properly instead of falling back to raw text
    - The app properly retrieves saved blobs from the database regardless of access pattern
    - Content is consistent across app launches and CloudKit synchronization

- **Fixed Rich Text Blob Architectural Issue** (Completed, Partial Success):
  - Addressed architectural disconnect between model context and UI views:
    - Fixed core issue: NewsDetailView was creating its own ViewModel, losing SwiftData model context
    - Modified NewsDetailView to accept pre-configured ViewModel via constructor pattern that maintains context:
      ```swift
      init(viewModel: NewsDetailViewModel) {
          _viewModel = ObservedObject(initialValue: viewModel)
          self.initiallyExpandedSection = viewModel.initiallyExpandedSection
      }
      ```
    - Updated all initialization points (AppDelegate.swift, NewsView.swift) to use new constructor pattern
    - Fixed UIModalPresentationStyle references to use proper Swift enum
    - Removed references to no-longer-exists properties (notifications, allNotifications, currentIndex)
    - Updated SimilarArticleRow to no longer use the removed bindings
  - Status after fix:
    - Log analysis shows blobs **are** now being correctly saved to the database:
      - Success message: `✅ Saved blob for criticalAnalysis to database (11551 bytes)`
      - Success message: `✅ Successfully saved blob to database model`
      - Success message: `✅ Blob saved to database (11551 bytes)`
    - CloudKit is properly syncing the blobs to iCloud:
      - Log shows successful record creation: `<CKRecord: 0x10fa16280>`
      - Log shows modified blob fields: `"CD_criticalAnalysisBlob", "CD_titleBlob", "CD_bodyBlob"`
      - Log confirms CloudKit export success: `CoreData: warning: CoreData+CloudKit: Finished export`
    - However, there are still some issues that need further investigation:
      - Error remains for some articles: `⚠️ Article 2F1B3CEA-BE44-4F30-944E-E0115CB334F7 has no model context - not saved to database`
      - This suggests some article instances are still being created without a proper model context
      - Interestingly, even with this error, the system recovers: `⚙️ PHASE 2: Blob loading failed, attempting rich text generation for Critical Analysis`
  - Future investigation needed:
    - Trace complete context propagation path to ensure no article instances miss getting a SwiftData context
    - Verify ArticleModel creation in NewsDetailViewModel is always capturing model context
    - Review all places in the app that create NotificationData objects to ensure they maintain context
    - Add more robust fallback mechanisms for cases where context is missing
    - Enhance logging around context assignment to pinpoint exactly where we're losing it

- **Diagnosed Rich Text Blob Storage Architectural Limitations** (In Progress):
  - Implemented partial fixes for rich text blobs not being saved to database:
    - Root cause identified: Architectural disconnect between models and view initialization flow
    - Primary issue: NotificationData objects lose SwiftData model context when converted from ArticleModel
    - Log evidence: `⚠️ Article 0B3B3CC6-9536-48D8-88EC-485152E8738E has no model context - not saved to database`
    - Core architectural conflict: NewsDetailView creates its own ViewModel internally, ignoring externally created ViewModel
  - Implemented a two-model synchronization approach:
    - Added `getArticleModelWithContext(byId:)` to ArticleOperations to retrieve intact database model
    - Added `saveBlobToDatabase(field:blobData:articleModel:)` method for direct database blob storage
    - Added support in NewsDetailViewModel for tracking and using ArticleModel alongside NotificationData
    - Modified NewsView+Extensions to fetch and prepare ArticleModel when opening articles
    - Fixed string interpolation compiler errors with RichTextField enum
    - Added comprehensive logging for blob saving operations
  - Current state and limitations:
    - Log shows successful ArticleModel fetch: `✅ Found ArticleModel with valid context for ID: 0B3B3CC6-9536-48D8-88EC-485152E8738E`
    - Log shows successful blob saving: `✅ Successfully saved blob to database model`
    - Blobs exist in database but aren't loaded between sessions due to architectural disconnect
    - Fundamental issue: NewsDetailView initializer creates its own ViewModel instead of using our pre-configured one
  - Architectural resolution requires:
    - Modifying NewsDetailView to accept a pre-configured ViewModel rather than creating its own
    - Or adding a secondary initializer to NewsDetailView that accepts a ViewModel directly 
    - Better adherence to MVVM by creating ViewModels at a higher level and injecting them into views
  - Created diagnostic tool (blob-diagnostic.swift) to analyze and verify database state
  - Learned valuable architectural insights about SwiftData context propagation:
    - Model context is lost when converting between models, requiring explicit context preservation
    - Using the right model for each operation is critical for database persistence
    - Nested view creation can cause dependency injection issues with ViewModels
    - Properly documenting architectural dependencies is essential for future maintainability

- **Fixed Rich Text Blob Storage Issue** (Completed):
  - Resolved issue with rich text blobs not being properly saved to database:
    - Root cause: Articles without a SwiftData model context could not persist their generated rich text
    - Log symptoms: `⚠️ Article has no model context - not saved to database`, `⚠️ No model context to save blob`
    - Error impact: Users had to regenerate section content like "Critical Analysis" on each view
  - Implemented a three-part solution:
    - Added `getArticleWithContext` method to ArticleOperations to retrieve database-backed articles
    - Restructured the rich text generation and blob saving process in NewsDetailViewModel:
      - Separated generation (inside timeout function) from blob saving (outside timeout)
      - Added support for saving blobs to both in-memory article and database-persisted copy
    - Enhanced diagnostic logging for model context and blob verification
  - Fixed compiler error with Swift concurrency:
    - Removed `await MainActor.run` usage inside timeout function which caused compiler error
    - Refactored to move async operations outside the timeout block for proper execution
  - Implemented a more robust pattern for blob management:
    - Three-phase loading: check blob cache → generate rich text → save persistent copy
    - Added error handling for each phase with proper fallbacks
    - Added verification step to confirm successful database storage
  - This fix ensures rich text content is properly persisted across app sessions, significantly improving user experience when viewing article sections

- **Fixed ArticleService Thread-Safety Issue** (Completed):
  - Resolved app crash caused by thread-safety issue in ArticleService cache operations:
    - Error: `-[NSIndexPath member:]: unrecognized selector sent to instance 0x8000000000000000`
    - Root cause: Concurrent access to `cacheKeys` set from multiple threads
    - Fixed by implementing proper thread isolation using serial dispatch queue
  - Implemented comprehensive thread-safety improvements:
    - Added `cacheQueue = DispatchQueue(label: "com.argus.articleservice.cache")` for isolation
    - Modified `cacheResults()` to run async on the queue when writing to cache
    - Updated `checkCache()` to synchronously access cache with thread safety
    - Refactored `clearCache()` into async public method and sync private implementation
    - Implemented safe cache accessors: `hasCacheKey()`, `cacheSize()`, `isCacheExpired()`
    - Added `withSafeCache<T>()` helper for generic safe cache operations
  - Enhanced async handling for cache operations:
    - Used `withCheckedContinuation` when calling `clearCache()` from async methods
    - Added comprehensive logging for cache operations with ModernizationLogger
    - Properly handled self-reference in closures with explicit syntax
  - Modernized ArticleService class documentation:
    - Added thread-safety documentation to class-level comment
    - Improved method documentation with thread-safety details
  - This fix follows modern Swift concurrency best practices:
    - Used dedicated dispatch queue for thread isolation
    - Implemented async/sync patterns appropriate to operation type
    - Ensured all mutable state access is properly synchronized
    - Applied consistent error handling and logging throughout
  - Key learnings for future development:
    - All shared mutable state needs explicit synchronization
    - Singletons require special attention to thread-safety
    - Cache operations benefit from serial queue isolation
    - Proper logging is essential for diagnosing concurrency issues

- **Fixed Filter Panel Display and Functionality Issues** (Completed):
  - Fixed two related issues with the filter panel in NewsView:
    - UI Layout Problem: The filter panel wasn't properly covering content below it, allowing text from underlying views to show through
    - Incorrect Functionality: The panel stated that "Changes are applied immediately" but filtering changes weren't actually applied until the user performed other actions
  - Implementation details:
    - Enhanced `filterSheet` implementation by using a ZStack with an opaque background:
      ```swift
      ZStack {
          // Full-coverage background layer to prevent seeing through
          Color(UIColor.systemBackground)
              .opacity(1.0)
              .ignoresSafeArea()
              .edgesIgnoringSafeArea(.all)
          
          // Rest of filter sheet content
          // ...
      }
      ```
    - Improved FilterView component by passing the viewModel and adding immediate refresh:
      ```swift
      private struct FilterView: View {
          @Binding var showUnreadOnly: Bool
          @Binding var showBookmarkedOnly: Bool
          var viewModel: NewsViewModel
          
          var body: some View {
              // ...
              Toggle(isOn: $showUnreadOnly) { ... }
                  .onChange(of: showUnreadOnly) { _, _ in
                      Task { await viewModel.refreshArticles() }
                  }
              // ...
          }
      }
      ```
  - Results:
    - The filter panel now completely covers the content beneath it, eliminating visual confusion
    - Filter changes now trigger an immediate UI refresh when toggled
    - The descriptive text "Changes are applied immediately" is now accurate
  - Key learnings:
    - In SwiftUI, using ZStack with a solid background can ensure proper visual layering
    - The `.onChange` modifier is the preferred modern approach for responding to state changes in SwiftUI
    - Passing the viewModel as a dependency enhances component reusability and testability
    - This approach follows iOS 18+ and Swift 6+ best practices for reactive UI updates

- **Implemented Modern Settings Observation** (Completed):
  - Fixed display preferences in Settings not affecting the NewsView and NodeDetailView:
    - Created dedicated UserDefaultsExtensions.swift for standardized settings access
    - Implemented Combine-based observation of UserDefaults changes in ViewModels
    - Standardized "date" as the default grouping style across components
    - Enhanced NewsViewModel to handle immediate UI updates when settings change
    - Enhanced NewsDetailViewModel for settings observation infrastructure
    - Added proper memory management with subscription cancellation in deinit
  - Added typed key constants to avoid stringly-typed programming
  - Implemented computed properties for all relevant UserDefaults settings
  - Used modern iOS 18+ patterns with Combine publishers for reactive settings updates
  - Achieved real-time UI updates when settings change
