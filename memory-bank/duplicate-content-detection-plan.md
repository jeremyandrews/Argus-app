# Duplicate Content Detection & Cleanup Implementation Plan

## Problem Analysis

After examining the sync architecture, I've identified the root cause of duplicate content downloads:

### Race Condition Sources
1. **Manual vs Automatic Sync Collision**: 
   - Manual sync via `NewsView.syncWithServer()` calls `ArticleOperations.syncContent()`
   - Automatic sync via `AutoSyncCoordinator.performAutoSyncIfNeeded()` calls `ArticleService.performBackgroundSync()`
   - Both can execute simultaneously without coordination

2. **Multiple Entry Points**:
   - Pull-to-refresh in NewsView
   - Auto-sync coordinator periodic sync
   - Auto-sync coordinator foreground return sync
   - Manual sync buttons in UI
   - Background app refresh

3. **Insufficient Sync Coordination**:
   - `AutoSyncCoordinator` has `isAutoSyncing` flag but only prevents multiple auto-syncs
   - No coordination between manual and automatic syncs
   - `ArticleService.processRemoteArticles()` processes articles in batches but doesn't have global sync coordination

## Current Duplicate Detection

The app already has `ArticleService.removeDuplicateArticles()` method that:
- Groups articles by `jsonURL`
- Keeps the newest version (by `addedDate`) 
- Deletes older duplicates

However, this is reactive cleanup rather than proactive prevention.

## Solution: Comprehensive Sync Coordination + Proactive Detection

### Phase 1: Global Sync Coordinator
Create a centralized sync coordinator that prevents race conditions:

1. **SyncCoordinator Singleton**:
   - Global `isSyncInProgress` flag
   - Queue for pending sync requests
   - Coordination between all sync entry points

2. **Sync Request Deduplication**:
   - Track active sync operations by type/topic
   - Merge duplicate requests when possible
   - Return existing sync results for identical requests

### Phase 2: Enhanced Duplicate Detection
Improve the duplicate detection to be more proactive:

1. **Pre-Insert Duplicate Check**:
   - Check for duplicates before inserting into database
   - Use `jsonURL` as primary deduplication key
   - Add secondary checks for `url`, `title`, and `publishDate` combination

2. **Batch Processing Improvements**:
   - Process articles in smaller batches with duplicate checks between batches
   - Early termination if duplicate ratio becomes too high

### Phase 3: Post-Sync Automatic Cleanup
Add automatic cleanup after sync operations:

1. **Immediate Post-Sync Cleanup**:
   - Run duplicate detection after each sync
   - Clean up any duplicates that slipped through
   - Report cleanup statistics

2. **Smart Cleanup Scheduling**:
   - More frequent cleanup if duplicates are detected
   - Background cleanup during low activity periods

### Phase 4: User Notification & Diagnostics
Provide visibility into duplicate handling:

1. **Sync Statistics Enhancement**:
   - Track duplicate detection events
   - Show cleanup statistics in sync statistics view
   - Alert user if duplicate rate becomes unusually high

2. **Manual Cleanup Tools**:
   - Enhanced duplicate cleanup in debug tools
   - Ability to force cleanup from settings

## Implementation Details

### 1. Global Sync Coordinator

```swift
@MainActor
final class GlobalSyncCoordinator: ObservableObject {
    static let shared = GlobalSyncCoordinator()
    
    @Published private(set) var isSyncInProgress = false
    @Published private(set) var currentSyncType: SyncType?
    
    private var pendingSyncs: [SyncRequest] = []
    private var activeSyncTask: Task<Int, Error>?
    
    enum SyncType {
        case manual(topic: String?)
        case automatic(context: String)
        case background
        case foregroundReturn
    }
    
    struct SyncRequest {
        let type: SyncType
        let topic: String?
        let limit: Int?
        let progressHandler: ((String) -> Void)?
        let completion: @Sendable (Result<Int, Error>) -> Void
    }
    
    func requestSync(
        type: SyncType,
        topic: String? = nil,
        limit: Int? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        // Check for duplicate request
        if let activeTask = activeSyncTask,
           currentSyncType?.isDuplicate(of: type, topic: topic) == true {
            // Return result of existing sync
            return try await activeTask.value
        }
        
        // Queue request if sync in progress
        if isSyncInProgress {
            return try await queueSyncRequest(type: type, topic: topic, limit: limit, progressHandler: progressHandler)
        }
        
        // Execute sync immediately
        return try await performSync(type: type, topic: topic, limit: limit, progressHandler: progressHandler)
    }
}
```

### 2. Enhanced Duplicate Detection

```swift
extension ArticleService {
    func processRemoteArticlesWithDuplicateDetection(
        _ articles: [ArticleJSON],
        targetNewArticles: Int = 50,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> (newArticles: Int, duplicatesDetected: Int, duplicatesRemoved: Int) {
        
        var duplicatesDetected = 0
        var duplicatesRemoved = 0
        var newArticles = 0
        
        // Pre-process duplicate detection
        let uniqueArticles = deduplicateArticlesBatch(articles, duplicatesFound: &duplicatesDetected)
        
        // Process unique articles
        newArticles = try await processRemoteArticles(uniqueArticles, targetNewArticles: targetNewArticles, progressHandler: progressHandler)
        
        // Post-process cleanup
        duplicatesRemoved = try await removeDuplicateArticles()
        
        return (newArticles: newArticles, duplicatesDetected: duplicatesDetected, duplicatesRemoved: duplicatesRemoved)
    }
    
    private func deduplicateArticlesBatch(_ articles: [ArticleJSON], duplicatesFound: inout Int) -> [ArticleJSON] {
        var seen: Set<String> = []
        var unique: [ArticleJSON] = []
        
        for article in articles {
            let key = article.jsonURL
            if !key.isEmpty && !seen.contains(key) {
                seen.insert(key)
                unique.append(article)
            } else {
                duplicatesFound += 1
            }
        }
        
        return unique
    }
}
```

### 3. Integration Points

Update all sync entry points to use the global coordinator:

1. **NewsView.syncWithServer()** → `GlobalSyncCoordinator.requestSync(.manual)`
2. **AutoSyncCoordinator.performAutoSyncIfNeeded()** → `GlobalSyncCoordinator.requestSync(.automatic)`
3. **ArticleOperations.syncContent()** → `GlobalSyncCoordinator.requestSync(.manual)`

## Implementation Priority

1. **High Priority**: Global Sync Coordinator - prevents race conditions
2. **Medium Priority**: Enhanced duplicate detection - improves efficiency
3. **Low Priority**: User notifications - improves user experience

## Testing Strategy

1. **Race Condition Testing**:
   - Trigger manual sync during automatic sync
   - Verify only one sync operation occurs
   - Confirm no duplicates are created

2. **Duplicate Detection Testing**:
   - Inject duplicate articles in test data
   - Verify detection and cleanup works correctly
   - Test edge cases (same URL, different content)

3. **Performance Testing**:
   - Measure sync performance with coordination overhead
   - Ensure cleanup doesn't significantly impact sync time

## Rollout Plan

1. **Phase 1**: Implement Global Sync Coordinator (1-2 days)
2. **Phase 2**: Integrate all sync entry points (1 day)
3. **Phase 3**: Enhanced duplicate detection (1 day)
4. **Phase 4**: Testing and refinement (1 day)

Total estimated time: 4-5 days

## Success Metrics

- Zero duplicate content downloads in testing
- Sync performance maintained or improved
- User-reported duplicate issues eliminated
- Sync statistics show proper coordination
