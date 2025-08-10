# Push Notification Quality Filtering Fix Plan

## Problem Summary

Users are receiving visible push notifications for low-quality articles despite having quality filters enabled. The current implementation only filters silent background notifications (`content-available: 1`), but the app actually receives **visible push notifications** that bypass quality filtering entirely.

## Root Cause Analysis

### Current Implementation Issues

1. **Wrong Notification Type**: The current `didReceiveRemoteNotification` method only processes silent notifications with `content-available: 1`
2. **Visible Notifications Ignored**: Visible push notifications (with `aps.alert` payloads) are completely ignored by quality filtering logic
3. **Database Race Condition**: The current implementation tries to lookup quality scores from database immediately after processing, creating potential timing issues

### What Should Happen

- **Visible notifications** arrive with both display content AND data payload
- **Quality filtering** should apply to these visible notifications 
- **Low-quality articles** should have their notifications removed before users see them
- **High-quality articles** should display notifications normally

## Implementation Plan

### 1. Modify Push Notification Processing (`Argus/AppDelegate.swift`)

#### Remove Silent Notification Filtering
```swift
// REMOVE this guard that only handles silent notifications:
guard
    let aps = userInfo["aps"] as? [String: AnyObject],
    let contentAvailable = aps["content-available"] as? Int,
    contentAvailable == 1,
    // ...
```

#### Add Visible Notification Processing  
```swift
// NEW guard that handles visible notifications:
guard
    let aps = userInfo["aps"] as? [String: AnyObject],
    let data = userInfo["data"] as? [String: AnyObject],
    let jsonURL = data["json_url"] as? String, !jsonURL.isEmpty
else {
    await finish(.noData)
    return
}
```

### 2. Implement Direct Quality Filtering

#### Use Server Data Directly (Not Database Lookup)
```swift
// Fetch article data from server
let articleData = try await APIClient.shared.fetchArticleByURL(jsonURL: jsonURL)

// Check quality immediately using server data
let qualityFilter = await MainActor.run {
    UserDefaults.standard.qualityFilter
}

// Apply quality filter using the fetched data directly
if meetsQualityThresholdWithScores(
    sourcesQuality: articleData.sourcesQuality,
    argumentQuality: articleData.argumentQuality, 
    filter: qualityFilter
) {
    // Article passes quality filter - process and allow notification
    _ = try await ArticleService.shared.processArticleData([articleData])
    await finish(.newData)
} else {
    // Article fails quality filter - process but remove notification
    _ = try await ArticleService.shared.processArticleData([articleData])
    await removeNotificationFromCenter(jsonURL: jsonURL)
    await finish(.noData)
}
```

### 3. Add Notification Removal Method

#### Remove Failed Notifications from Notification Center
```swift
@MainActor
private func removeNotificationFromCenter(jsonURL: String) async {
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        let matchingIDs = notifications
            .compactMap { delivered -> String? in
                guard
                    let data = delivered.request.content.userInfo["data"] as? [String: Any],
                    let deliveredURL = data["json_url"] as? String
                else {
                    return nil
                }
                return deliveredURL == jsonURL ? delivered.request.identifier : nil
            }
        if !matchingIDs.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: matchingIDs)
            AppLogger.app.info("Removed \(matchingIDs.count) notifications for filtered article")
        }
    }
}
```

### 4. Simplify Quality Checking Logic

#### Remove Database Lookup Methods
- Remove `shouldShowNotificationForArticle()` method (database lookup approach)
- Keep `meetsQualityThresholdWithScores()` method (direct data approach)
- Remove database context handling for notification filtering

## Expected Server Payload Structure

### Visible Push Notification
```json
{
  "aps": {
    "alert": {
      "title": "Article Title",
      "body": "Article preview text..."
    },
    "sound": "default",
    "badge": 1
  },
  "data": {
    "json_url": "https://api.arguspulse.com/articles/some-article.json"
  }
}
```

### Server Response (from json_url)
```json
{
  "tiny_title": "Article Title",
  "tiny_summary": "Article preview...",
  "sources_quality": 2,
  "argument_quality": 3,
  "json_url": "https://api.arguspulse.com/articles/some-article.json",
  // ... other article data
}
```

## Quality Filter Logic

### Filter Thresholds
- **"All"**: No filtering (show all notifications)
- **"Fair+"**: Show only articles with `sourcesQuality >= 2 AND argumentQuality >= 2`
- **"Good+"**: Show only articles with `sourcesQuality >= 3 AND argumentQuality >= 3`

### Filter Application
1. **Fetch article data** from server using JSON URL
2. **Extract quality scores** from server response (`sources_quality`, `argument_quality`)
3. **Apply AND logic** - both scores must meet threshold
4. **Remove notification** if article fails filter
5. **Allow notification** if article passes filter
6. **Always process article** to database regardless of filter result

## Benefits of This Approach

1. **Eliminates Race Conditions**: No database lookup required
2. **Uses Fresh Server Data**: Quality scores from server response
3. **Proper Notification Filtering**: Actually filters the notifications users see
4. **Maintains Data Integrity**: All articles still saved to database
5. **Better User Experience**: Users only see relevant, high-quality notifications

## Files to Modify

### Primary Changes
- **`Argus/AppDelegate.swift`**: Complete rewrite of notification processing logic

### Testing Requirements
1. **Test all quality filter levels**: "All", "Fair+", "Good+"
2. **Test edge cases**: Missing quality scores, network failures
3. **Test notification removal**: Verify low-quality notifications don't appear
4. **Test badge counts**: Ensure badge reflects filtered notifications
5. **Test database integrity**: All articles still saved regardless of filter

## Success Criteria

✅ **Visible notifications** are processed and filtered  
✅ **Low-quality articles** don't show notifications to users  
✅ **High-quality articles** show notifications normally  
✅ **All articles** are still saved to database for app browsing  
✅ **Badge counts** reflect quality-filtered notification count  
✅ **No race conditions** between processing and filtering  
✅ **Quality filtering works** across all filter levels ("All", "Fair+", "Good+")
