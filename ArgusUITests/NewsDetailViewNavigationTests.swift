import XCTest

/// Comprehensive test suite for NewsDetailView navigation and cache corruption scenarios
final class NewsDetailViewNavigationTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // Configure app for navigation testing
        app.launchArguments += [
            "UI_TESTING",
            "UI_TESTING_PERMISSIONS_GRANTED",
            "NAVIGATION_TESTING_MODE"
        ]

        // Set environment variables for test data with multiple articles
        app.launchEnvironment["SETUP_TEST_DATA"] = "1"
        app.launchEnvironment["CREATE_MULTIPLE_ARTICLES"] = "5"

        app.launch()
        
        // Wait for app to be ready
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App failed to launch")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Test that navigation between articles shows correct content (no cache corruption)
    func testNavigationShowsCorrectArticleContent() throws {
        // Navigate to first article
        let firstArticleTitle = app.staticTexts["Test Article Title for UI Tests"]
        XCTAssertTrue(firstArticleTitle.waitForExistence(timeout: 10), "First article not found")
        
        let firstTitleText = firstArticleTitle.label
        firstArticleTitle.tap()
        
        // Wait for detail view to load
        XCTAssertTrue(waitForDetailViewToLoad(), "Detail view failed to load")
        
        // Capture first article content
        let firstArticleContentSnapshot = captureArticleContent()
        
        // Navigate to next article
        let forwardButton = app.buttons["Forward"]
        XCTAssertTrue(forwardButton.exists, "Forward button not found")
        forwardButton.tap()
        
        // Wait for navigation to complete
        sleep(1)
        
        // Capture second article content
        let secondArticleContentSnapshot = captureArticleContent()
        
        // CRITICAL TEST: Verify content has changed (no cache corruption)
        XCTAssertNotEqual(
            firstArticleContentSnapshot.title,
            secondArticleContentSnapshot.title,
            "Navigation failed - still showing first article content (cache corruption detected)"
        )
        
        XCTAssertNotEqual(
            firstArticleContentSnapshot.body,
            secondArticleContentSnapshot.body,
            "Body content didn't change - cache corruption detected"
        )
        
        // Navigate back to first article
        let backButton = app.buttons["Back"]
        XCTAssertTrue(backButton.exists, "Back button not found")
        backButton.tap()
        
        sleep(1)
        
        // Capture content after navigating back
        let backToFirstContentSnapshot = captureArticleContent()
        
        // CRITICAL TEST: Verify we're back to the original content
        XCTAssertEqual(
            firstArticleContentSnapshot.title,
            backToFirstContentSnapshot.title,
            "Back navigation failed - showing wrong content"
        )
        
        // Take final verification screenshot
        let finalScreenshot = XCTAttachment(screenshot: app.screenshot())
        finalScreenshot.name = "Final Navigation State"
        finalScreenshot.lifetime = .keepAlways
        add(finalScreenshot)
    }
    
    /// Test rapid navigation scenario (stress test for cache corruption)
    func testRapidNavigationMaintainsContentIntegrity() throws {
        // Navigate to first article
        let firstArticleTitle = app.staticTexts["Test Article Title for UI Tests"]
        XCTAssertTrue(firstArticleTitle.waitForExistence(timeout: 10), "First article not found")
        firstArticleTitle.tap()
        
        XCTAssertTrue(waitForDetailViewToLoad(), "Detail view failed to load")
        
        let forwardButton = app.buttons["Forward"]
        let backButton = app.buttons["Back"]
        
        // Perform rapid navigation sequence
        var contentSnapshots: [ArticleContentSnapshot] = []
        
        // Capture initial state
        contentSnapshots.append(captureArticleContent())
        
        // Forward navigation sequence
        for i in 1...3 {
            if forwardButton.exists {
                forwardButton.tap()
                usleep(500000) // 0.5 second wait
                contentSnapshots.append(captureArticleContent())
                
                // Take screenshot of each navigation step
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Rapid Navigation Forward Step \(i)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
        
        // Backward navigation sequence
        for i in 1...3 {
            if backButton.exists {
                backButton.tap()
                usleep(500000) // 0.5 second wait
                let backContent = captureArticleContent()
                
                // CRITICAL TEST: Verify content matches expected previous content
                if i <= contentSnapshots.count - 1 {
                    let expectedContent = contentSnapshots[contentSnapshots.count - 1 - i]
                    XCTAssertEqual(
                        expectedContent.title,
                        backContent.title,
                        "Rapid back navigation step \(i) shows wrong content - cache corruption detected"
                    )
                }
                
                // Take screenshot of each back navigation step
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Rapid Navigation Back Step \(i)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }
    
    /// Test forward and backward navigation boundary conditions
    func testNavigationBoundaryConditions() throws {
        // Navigate to first article
        let firstArticleTitle = app.staticTexts["Test Article Title for UI Tests"]
        XCTAssertTrue(firstArticleTitle.waitForExistence(timeout: 10), "First article not found")
        firstArticleTitle.tap()
        
        XCTAssertTrue(waitForDetailViewToLoad(), "Detail view failed to load")
        
        let forwardButton = app.buttons["Forward"]
        let backButton = app.buttons["Back"]
        
        // Try to go back from first article (should either disable button or handle gracefully)
        if backButton.exists && backButton.isEnabled {
            backButton.tap()
            sleep(1)
            
            // Should still show valid content (not crash or show corrupted content)
            let content = captureArticleContent()
            XCTAssertFalse(content.title.isEmpty, "Back navigation at boundary resulted in empty content")
        }
        
        // Navigate to last article by going forward as much as possible
        var navigationCount = 0
        while forwardButton.exists && forwardButton.isEnabled && navigationCount < 10 {
            forwardButton.tap()
            sleep(1)
            navigationCount += 1
        }
        
        // Try to go forward from last article
        if forwardButton.exists {
            forwardButton.tap()
            sleep(1)
            
            // Should still show valid content
            let content = captureArticleContent()
            XCTAssertFalse(content.title.isEmpty, "Forward navigation at boundary resulted in empty content")
        }
        
        // Take final screenshot
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Boundary Navigation Final State"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    
    /// Test that cache behavior works correctly during navigation
    func testCacheBehaviorDuringNavigation() throws {
        // Navigate to first article
        let firstArticleTitle = app.staticTexts["Test Article Title for UI Tests"]
        XCTAssertTrue(firstArticleTitle.waitForExistence(timeout: 10), "First article not found")
        firstArticleTitle.tap()
        
        XCTAssertTrue(waitForDetailViewToLoad(), "Detail view failed to load")
        
        // Wait for content to fully load (including any rich text processing)
        sleep(3)
        
        // Navigate forward and back multiple times to test cache
        let forwardButton = app.buttons["Forward"]
        let backButton = app.buttons["Back"]
        
        // Capture initial content
        let initialContent = captureArticleContent()
        
        // Navigate forward
        if forwardButton.exists {
            forwardButton.tap()
            sleep(2) // Allow time for content loading/caching
            
            let secondContent = captureArticleContent()
            XCTAssertNotEqual(initialContent.title, secondContent.title, "Forward navigation failed")
            
            // Navigate back (should use cache)
            if backButton.exists {
                backButton.tap()
                sleep(1) // Cache should be faster
                
                let cachedContent = captureArticleContent()
                XCTAssertEqual(
                    initialContent.title,
                    cachedContent.title,
                    "Cache failed - wrong content after back navigation"
                )
                
                // Content should appear quickly due to caching
                // This is more of a performance indicator than a strict test
                XCTAssertFalse(cachedContent.title.isEmpty, "Cached content is empty")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Waits for the detail view to fully load
    private func waitForDetailViewToLoad() -> Bool {
        let detailViewIndicators = [
            app.buttons["Close"],
            app.buttons["Back"], 
            app.buttons["Forward"]
        ]
        
        return detailViewIndicators.contains { $0.waitForExistence(timeout: 5) }
    }
    
    /// Captures the current article content for comparison
    private func captureArticleContent() -> ArticleContentSnapshot {
        // Find title - could be in various locations
        var title = ""
        
        // Try to find title in static texts
        let titleCandidates = app.staticTexts.allElementsBoundByIndex
        for element in titleCandidates {
            let label = element.label
            if label.contains("Test Article") || (label.count > 10 && !label.contains("Published:") && !label.contains(".com")) {
                title = label
                break
            }
        }
        
        // Find body content
        var body = ""
        for element in titleCandidates {
            let label = element.label
            if label.contains("body") || label.contains("content") {
                body = label
                break
            }
        }
        
        // Find domain/source
        var source = ""
        for element in titleCandidates {
            let label = element.label
            if label.contains(".com") {
                source = label
                break
            }
        }
        
        return ArticleContentSnapshot(title: title, body: body, source: source)
    }
}

/// Helper struct to capture article content for comparison
struct ArticleContentSnapshot {
    let title: String
    let body: String
    let source: String
}
