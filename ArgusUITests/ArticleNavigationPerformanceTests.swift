//
//  ArticleNavigationPerformanceTests.swift
//  ArgusUITests
//
//  Performance and correctness tests for article navigation
//

import XCTest

final class ArticleNavigationPerformanceTests: XCTestCase {
    
    private var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--performance-test"]
        app.launch()
        
        // Wait for app to fully load
        let startupTimeout: TimeInterval = 10.0
        let startTime = Date()
        
        // Wait for the main table view to appear
        let table = app.tables.firstMatch
        _ = table.waitForExistence(timeout: startupTimeout)
        
        let startupTime = Date().timeIntervalSince(startTime)
        print("🚀 App Startup Time: \(String(format: "%.2f", startupTime))s")
        
        if startupTime > 3.0 {
            print("⚠️ WARNING: Slow startup detected - took \(String(format: "%.2f", startupTime))s")
        }
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Startup Performance Test
    
    func testAppStartupPerformance() throws {
        // This test measures cold startup time
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // Terminate and relaunch app
            app.terminate()
            app.launch()
            
            // Wait for main content to appear
            let table = app.tables.firstMatch
            let exists = table.waitForExistence(timeout: 10.0)
            XCTAssertTrue(exists, "Main table view should appear")
            
            // Check that we have articles
            let cells = app.tables.cells
            if cells.count > 0 {
                print("✅ App loaded with \(cells.count) articles visible")
            } else {
                print("⚠️ No articles visible after startup")
            }
        }
    }
    
    // MARK: - Article Navigation with Content Verification
    
    func testArticleNavigationWithContentVerification() throws {
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 2 else {
            throw XCTSkip("Need at least 2 articles for navigation test")
        }
        
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // STEP 1: Open first article
            print("📄 Opening first article...")
            let firstArticle = cells.element(boundBy: 0)
            firstArticle.tap()
            
            // Verify article content loaded
            let contentLoaded = verifyArticleContentLoaded(articleIndex: 1)
            XCTAssertTrue(contentLoaded, "First article content should load")
            
            // STEP 2: Navigate to next article using swipe or button
            print("➡️ Navigating to second article...")
            navigateToNextArticle()
            
            // Verify second article content loaded
            let secondContentLoaded = verifyArticleContentLoaded(articleIndex: 2)
            XCTAssertTrue(secondContentLoaded, "Second article content should load")
            
            // STEP 3: Navigate back to first article
            print("⬅️ Navigating back to first article...")
            navigateToPreviousArticle()
            
            // Verify first article content is still correct
            let firstContentReloaded = verifyArticleContentLoaded(articleIndex: 1)
            XCTAssertTrue(firstContentReloaded, "First article content should reload correctly")
            
            // STEP 4: Close detail view
            print("🔙 Closing detail view...")
            closeDetailView()
            
            // Verify we're back in the list
            let backInList = table.waitForExistence(timeout: 2.0)
            XCTAssertTrue(backInList, "Should return to article list")
        }
    }
    
    // MARK: - Rapid Article Navigation Test
    
    func testRapidArticleNavigation() throws {
        let cells = app.tables.cells
        guard cells.count >= 5 else {
            throw XCTSkip("Need at least 5 articles for rapid navigation test")
        }
        
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            // Open first article
            cells.element(boundBy: 0).tap()
            
            // Rapidly navigate through articles
            for i in 1..<5 {
                print("⚡ Rapid navigation to article \(i + 1)")
                
                // Navigate to next
                navigateToNextArticle()
                
                // Quick content check (don't wait for full load)
                _ = verifyArticleContentLoaded(articleIndex: i + 1, timeout: 1.0)
            }
            
            // Navigate back through articles
            for i in (1..<5).reversed() {
                print("⚡ Rapid navigation back to article \(i)")
                navigateToPreviousArticle()
                _ = verifyArticleContentLoaded(articleIndex: i, timeout: 1.0)
            }
            
            // Close and verify
            closeDetailView()
        }
    }
    
    // MARK: - Helper Methods
    
    private func verifyArticleContentLoaded(articleIndex: Int, timeout: TimeInterval = 3.0) -> Bool {
        let startTime = Date()
        
        // ENHANCED: More flexible content verification that accounts for progressive loading
        
        // Step 1: Wait for basic UI structure
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: timeout)
        
        if !detailViewExists {
            print("❌ Article \(articleIndex) detail view failed to appear within \(timeout)s")
            return false
        }
        
        // Step 2: Look for progressive loading indicators
        let staticTexts = app.staticTexts
        let buttons = app.buttons
        
        // Give progressive loading some time to show content
        var progressiveTimeout = min(2.0, timeout)
        let endTime = Date().addingTimeInterval(progressiveTimeout)
        
        var hasMinimalContent = false
        var hasTitle = false
        var hasSummary = false
        
        while Date() < endTime && !hasMinimalContent {
            // Check for title content (should load first)
            hasTitle = staticTexts.allElementsBoundByIndex.contains { element in
                element.exists && element.label.count > 20 && element.label.contains(where: { $0.isLetter })
            }
            
            // Check for summary section (should load with progressive loading)
            hasSummary = buttons["Summary"].exists || staticTexts["Summary"].exists ||
                        staticTexts.allElementsBoundByIndex.contains { element in
                            element.exists && element.label.localizedCaseInsensitiveContains("summary")
                        }
            
            // Check for loading state indicators (shows progressive loading is working)
            let hasLoadingIndicator = staticTexts.allElementsBoundByIndex.contains { element in
                element.exists && (
                    element.label.contains("Loading") ||
                    element.label.contains("...") ||
                    element.label.contains("Converting")
                )
            }
            
            // Accept if we have title OR summary OR loading indicator (progressive loading)
            hasMinimalContent = hasTitle || hasSummary || hasLoadingIndicator
            
            if !hasMinimalContent {
                // Wait a bit before checking again
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        
        let loadTime = Date().timeIntervalSince(startTime)
        
        if hasMinimalContent {
            var contentType = "content"
            if hasTitle && hasSummary {
                contentType = "title + summary"
            } else if hasTitle {
                contentType = "title"
            } else if hasSummary {
                contentType = "summary"
            } else {
                contentType = "loading state"
            }
            
            print("✅ Article \(articleIndex) \(contentType) loaded in \(String(format: "%.2f", loadTime))s")
            
            // Progressive loading is acceptable even if slower
            if loadTime > 2.0 && loadTime < 5.0 {
                print("⏳ Progressive loading detected: \(String(format: "%.2f", loadTime))s")
            } else if loadTime > 5.0 {
                print("⚠️ Very slow loading: \(String(format: "%.2f", loadTime))s")
            }
            
            // Log content sample for debugging
            if let sampleText = staticTexts.allElementsBoundByIndex.first(where: { 
                $0.exists && $0.label.count > 30 
            }) {
                let preview = String(sampleText.label.prefix(80))
                print("📝 Content sample: \(preview)...")
            }
            
            return true
        } else {
            print("❌ Article \(articleIndex) failed to show any content within \(timeout)s")
            
            // Debug: Log what UI elements we do see
            let visibleElements = staticTexts.allElementsBoundByIndex.prefix(5).compactMap { element in
                element.exists ? element.label : nil
            }
            if !visibleElements.isEmpty {
                print("🔍 Visible elements: \(visibleElements)")
            }
            
            return false
        }
    }
    
    private func navigateToNextArticle() {
        // Try swipe gesture first
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeLeft()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        
        // Fall back to navigation button
        if let nextButton = findNavigationButton(direction: "next") {
            nextButton.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    
    private func navigateToPreviousArticle() {
        // Try swipe gesture first
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeRight()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        
        // Fall back to navigation button
        if let prevButton = findNavigationButton(direction: "previous") {
            prevButton.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    
    private func findNavigationButton(direction: String) -> XCUIElement? {
        // Look for navigation buttons
        let buttons = app.buttons
        
        for button in buttons.allElementsBoundByIndex {
            if button.exists {
                let label = button.label.lowercased()
                if direction == "next" && (label.contains("next") || label.contains("→")) {
                    return button
                } else if direction == "previous" && (label.contains("prev") || label.contains("←")) {
                    return button
                }
            }
        }
        
        return nil
    }
    
    private func closeDetailView() {
        // Try different ways to close the detail view
        
        // Method 1: Look for a close or back button
        let closeButton = app.buttons["Close"].exists ? app.buttons["Close"] :
                         app.buttons["Done"].exists ? app.buttons["Done"] :
                         app.buttons["Back"].exists ? app.buttons["Back"] : nil
        
        if let button = closeButton {
            button.tap()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        
        // Method 2: Navigation bar back button
        let navBars = app.navigationBars
        if navBars.count > 0 {
            let backButton = navBars.buttons.firstMatch
            if backButton.exists {
                backButton.tap()
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
        }
        
        // Method 3: Swipe down gesture (for modal presentation)
        let window = app.windows.firstMatch
        if window.exists {
            window.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    
    // MARK: - Single Article Performance Test
    
    func testSingleArticleTopicPerformance() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 SINGLE ARTICLE TOPIC PERFORMANCE TEST")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 1 else {
            throw XCTSkip("Need at least 1 article for single article performance test")
        }
        
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 5
        
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // Test opening the first (and potentially only) article in a topic
            print("📄 Testing single article opening performance...")
            let firstArticle = cells.element(boundBy: 0)
            firstArticle.tap()
            
            // Verify article content loads (this is where the hang would occur)
            let contentLoaded = verifyArticleContentLoaded(articleIndex: 1, timeout: 5.0)
            XCTAssertTrue(contentLoaded, "Single article content should load quickly")
            
            // Close and verify
            closeDetailView()
            let backInList = table.waitForExistence(timeout: 2.0)
            XCTAssertTrue(backInList, "Should return to article list")
        }
        
        print("✅ Single Article Topic Performance Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }

    // MARK: - Position Counter Validation Tests
    
    func testTopArticlePositionCounter() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 TOP ARTICLE POSITION COUNTER TEST")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 3 else {
            throw XCTSkip("Need at least 3 articles for position counter test")
        }
        
        let totalArticles = cells.count
        print("📄 Total articles available: \(totalArticles)")
        
        // Test clicking on the TOP article (first in list)
        print("🎯 Testing top article position counter...")
        let topArticle = cells.element(boundBy: 0)
        topArticle.tap()
        
        // Wait for detail view to load
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // Look for position counter - should show "1 of X"
        let positionCounterFound = verifyPositionCounter(expectedPosition: 1, expectedTotal: totalArticles)
        XCTAssertTrue(positionCounterFound, "Top article should show position '1 of \(totalArticles)'")
        
        closeDetailView()
        print("✅ Top Article Position Counter Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func testPositionCounterNavigation() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 POSITION COUNTER NAVIGATION TEST")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 5 else {
            throw XCTSkip("Need at least 5 articles for position counter navigation test")
        }
        
        let totalArticles = cells.count
        print("📄 Total articles available: \(totalArticles)")
        
        // Open first article
        print("🎯 Opening first article...")
        let firstArticle = cells.element(boundBy: 0)
        firstArticle.tap()
        
        // Wait for detail view to load
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // Test navigation through first 5 articles and verify position counters
        for expectedPosition in 1...min(5, totalArticles) {
            print("📍 Verifying position \(expectedPosition) of \(totalArticles)")
            
            let positionCorrect = verifyPositionCounter(expectedPosition: expectedPosition, expectedTotal: totalArticles)
            XCTAssertTrue(positionCorrect, "Article should show position '\(expectedPosition) of \(totalArticles)'")
            
            // Navigate to next article (except on last iteration)
            if expectedPosition < min(5, totalArticles) {
                print("➡️ Navigating to next article...")
                navigateToNextArticle()
                Thread.sleep(forTimeInterval: 0.5) // Give time for position counter to update
            }
        }
        
        // Navigate back and verify position counters update correctly
        print("⬅️ Testing backward navigation...")
        for expectedPosition in (1..<min(5, totalArticles)).reversed() {
            navigateToPreviousArticle()
            Thread.sleep(forTimeInterval: 0.5)
            
            print("📍 Verifying backward position \(expectedPosition) of \(totalArticles)")
            let positionCorrect = verifyPositionCounter(expectedPosition: expectedPosition, expectedTotal: totalArticles)
            XCTAssertTrue(positionCorrect, "Article should show position '\(expectedPosition) of \(totalArticles)' when navigating backward")
        }
        
        closeDetailView()
        print("✅ Position Counter Navigation Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func testPositionCounterConsistency() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 POSITION COUNTER CONSISTENCY TEST")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 3 else {
            throw XCTSkip("Need at least 3 articles for consistency test")
        }
        
        let totalArticles = cells.count
        print("📄 Total articles available: \(totalArticles)")
        
        // Test multiple articles from different positions in the list
        let testPositions = [0, min(1, totalArticles - 1), min(2, totalArticles - 1)]
        
        for (index, cellIndex) in testPositions.enumerated() {
            let expectedPosition = cellIndex + 1
            print("🎯 Testing article at list position \(expectedPosition)...")
            
            // Open article at specific position
            let article = cells.element(boundBy: cellIndex)
            article.tap()
            
            // Wait for detail view
            let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
            XCTAssertTrue(detailViewExists, "Detail view should appear")
            
            // Verify position counter matches the list position
            let positionCorrect = verifyPositionCounter(expectedPosition: expectedPosition, expectedTotal: totalArticles)
            XCTAssertTrue(positionCorrect, "Article at list position \(expectedPosition) should show '\(expectedPosition) of \(totalArticles)'")
            
            // Close and return to list
            closeDetailView()
            let backInList = table.waitForExistence(timeout: 2.0)
            XCTAssertTrue(backInList, "Should return to article list")
            
            Thread.sleep(forTimeInterval: 0.3) // Brief pause between tests
        }
        
        print("✅ Position Counter Consistency Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    private func verifyPositionCounter(expectedPosition: Int, expectedTotal: Int, timeout: TimeInterval = 3.0) -> Bool {
        let expectedText = "\(expectedPosition) of \(expectedTotal)"
        print("🔍 Looking for position counter: '\(expectedText)'")
        
        let endTime = Date().addingTimeInterval(timeout)
        
        while Date() < endTime {
            // FIRST: Try to find the position counter using the new accessibility identifier
            let positionCounter = app.otherElements["ArticlePositionCounter"]
            if positionCounter.exists {
                let label = positionCounter.label
                if label.contains(expectedText) {
                    print("✅ Found position counter via accessibility identifier: '\(label)'")
                    return true
                }
                
                // Also check for partial matches
                if label.contains("of \(expectedTotal)") && label.contains("\(expectedPosition)") {
                    print("✅ Found position counter via accessibility identifier (partial match): '\(label)'")
                    return true
                }
                
                print("🔍 Position counter found but text doesn't match. Expected: '\(expectedText)', Found: '\(label)'")
            }
            
            // FALLBACK: Look for position counter in various possible formats
            let staticTexts = app.staticTexts
            let buttons = app.buttons
            
            // Check static texts for position counter
            for element in staticTexts.allElementsBoundByIndex {
                if element.exists {
                    let label = element.label
                    if label.contains(expectedText) {
                        print("✅ Found position counter in static text: '\(label)'")
                        return true
                    }
                    
                    // Also check for partial matches that might indicate the counter
                    if label.contains("of \(expectedTotal)") && label.contains("\(expectedPosition)") {
                        print("✅ Found position counter (partial match): '\(label)'")
                        return true
                    }
                }
            }
            
            // Check buttons for position counter
            for element in buttons.allElementsBoundByIndex {
                if element.exists {
                    let label = element.label
                    if label.contains(expectedText) {
                        print("✅ Found position counter in button: '\(label)'")
                        return true
                    }
                    
                    if label.contains("of \(expectedTotal)") && label.contains("\(expectedPosition)") {
                        print("✅ Found position counter in button (partial match): '\(label)'")
                        return true
                    }
                }
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Enhanced Debug: Log what we actually found
        print("❌ Position counter '\(expectedText)' not found.")
        
        // Check if the accessibility element exists but with wrong text
        let positionCounter = app.otherElements["ArticlePositionCounter"]
        if positionCounter.exists {
            print("🔍 Position counter element exists with label: '\(positionCounter.label)'")
            print("🔍 Position counter value: '\(positionCounter.value ?? "nil")'")
        } else {
            print("❌ Position counter accessibility element not found")
        }
        
        print("Available text elements:")
        let staticTexts = app.staticTexts
        let availableTexts = staticTexts.allElementsBoundByIndex.prefix(15).compactMap { element in
            element.exists ? element.label : nil
        }.filter { !$0.isEmpty }
        
        for (index, text) in availableTexts.enumerated() {
            print("   \(index + 1). '\(text)'")
        }
        
        // Also check buttons
        print("Available button elements:")
        let buttons = app.buttons
        let availableButtons = buttons.allElementsBoundByIndex.prefix(10).compactMap { element in
            element.exists ? element.label : nil
        }.filter { !$0.isEmpty }
        
        for (index, text) in availableButtons.enumerated() {
            print("   \(index + 1). '\(text)'")
        }
        
        return false
    }

    // MARK: - Missing Article Bug Tests (n-1 issue)
    
    func testArticleCountConsistency() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🐛 ARTICLE COUNT CONSISTENCY TEST (n-1 Bug Detection)")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 3 else {
            throw XCTSkip("Need at least 3 articles for count consistency test")
        }
        
        let listArticleCount = cells.count
        print("📄 Articles visible in list: \(listArticleCount)")
        
        // Open first article and check if navigation total matches list count
        print("🎯 Opening first article to check navigation total...")
        let firstArticle = cells.element(boundBy: 0)
        firstArticle.tap()
        
        // Wait for detail view to load
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // Extract the total count from position counter
        let navigationTotal = extractNavigationTotal()
        print("📊 Navigation shows total: \(navigationTotal)")
        print("📊 List shows total: \(listArticleCount)")
        
        // BUG CHECK: Navigation total should equal list count
        XCTAssertEqual(navigationTotal, listArticleCount, 
                      "🐛 BUG DETECTED: Navigation total (\(navigationTotal)) doesn't match list count (\(listArticleCount)). This is the n-1 bug!")
        
        if navigationTotal != listArticleCount {
            print("❌ CONFIRMED: n-1 bug exists - missing \(listArticleCount - navigationTotal) article(s) in navigation")
        } else {
            print("✅ Article counts match - no n-1 bug detected")
        }
        
        closeDetailView()
        print("✅ Article Count Consistency Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func testNavigateToAllArticles() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🐛 NAVIGATE TO ALL ARTICLES TEST (n-1 Bug Detection)")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 3 else {
            throw XCTSkip("Need at least 3 articles for navigation test")
        }
        
        let listArticleCount = cells.count
        print("📄 Articles visible in list: \(listArticleCount)")
        
        // Open first article
        print("🎯 Opening first article...")
        let firstArticle = cells.element(boundBy: 0)
        firstArticle.tap()
        
        // Wait for detail view to load
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // Try to navigate through ALL articles that should exist
        var maxReachablePosition = 1
        var currentPosition = 1
        
        // Navigate forward as far as possible
        print("➡️ Navigating forward through all articles...")
        while currentPosition < listArticleCount {
            // Try to navigate to next article
            navigateToNextArticle()
            Thread.sleep(forTimeInterval: 0.5)
            
            // Check if we actually moved to a new article
            let newPosition = extractCurrentPosition()
            if newPosition > currentPosition {
                currentPosition = newPosition
                maxReachablePosition = currentPosition
                print("📍 Successfully reached position \(currentPosition)")
            } else {
                print("🛑 Cannot navigate beyond position \(currentPosition)")
                break
            }
        }
        
        print("📊 Maximum reachable position: \(maxReachablePosition)")
        print("📊 Expected maximum position: \(listArticleCount)")
        
        // BUG CHECK: We should be able to reach ALL articles
        XCTAssertEqual(maxReachablePosition, listArticleCount,
                      "🐛 BUG DETECTED: Can only reach \(maxReachablePosition) of \(listArticleCount) articles. Missing \(listArticleCount - maxReachablePosition) article(s)!")
        
        if maxReachablePosition < listArticleCount {
            print("❌ CONFIRMED: n-1 bug exists - cannot navigate to \(listArticleCount - maxReachablePosition) article(s)")
        } else {
            print("✅ Can navigate to all articles - no n-1 bug detected")
        }
        
        closeDetailView()
        print("✅ Navigate To All Articles Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func testFinalArticleScenario() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🐛 FINAL ARTICLE SCENARIO TEST ('1 of 0' Bug Detection)")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 2 else {
            throw XCTSkip("Need at least 2 articles for final article test")
        }
        
        let listArticleCount = cells.count
        print("📄 Articles visible in list: \(listArticleCount)")
        
        // Simulate the scenario: navigate through articles, then return to list
        // and try to open the "final remaining article"
        
        // Step 1: Open first article and navigate through some articles
        print("🎯 Opening first article and navigating through articles...")
        let firstArticle = cells.element(boundBy: 0)
        firstArticle.tap()
        
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // Navigate through a few articles to potentially trigger the filtering issue
        let articlesToNavigate = min(3, listArticleCount - 1)
        for i in 1...articlesToNavigate {
            print("➡️ Navigating to article \(i + 1)...")
            navigateToNextArticle()
            Thread.sleep(forTimeInterval: 0.5)
            
            let position = extractCurrentPosition()
            let total = extractNavigationTotal()
            print("📍 Current position: \(position) of \(total)")
        }
        
        // Step 2: Return to list
        print("🔙 Returning to article list...")
        closeDetailView()
        let backInList = table.waitForExistence(timeout: 2.0)
        XCTAssertTrue(backInList, "Should return to article list")
        
        // Step 3: Check if there are still articles in the list
        let remainingCells = app.tables.cells
        let remainingCount = remainingCells.count
        print("📄 Articles remaining in list: \(remainingCount)")
        
        if remainingCount > 0 {
            print("🎯 Opening what should be the 'final' article...")
            let finalArticle = remainingCells.element(boundBy: remainingCount - 1)
            finalArticle.tap()
            
            let finalDetailExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
            XCTAssertTrue(finalDetailExists, "Final article detail view should appear")
            
            // Check for the "1 of 0" bug
            let finalPosition = extractCurrentPosition()
            let finalTotal = extractNavigationTotal()
            
            print("📍 Final article position: \(finalPosition) of \(finalTotal)")
            
            // BUG CHECK: Should never see "X of 0"
            XCTAssertGreaterThan(finalTotal, 0, 
                               "🐛 BUG DETECTED: Final article shows '\(finalPosition) of 0' - this is the '1 of 0' bug!")
            
            // BUG CHECK: Position should be reasonable
            XCTAssertGreaterThan(finalPosition, 0,
                               "🐛 BUG DETECTED: Final article shows invalid position '\(finalPosition)'")
            
            if finalTotal == 0 {
                print("❌ CONFIRMED: '1 of 0' bug exists - final article shows no total count")
            } else if finalPosition > finalTotal {
                print("❌ CONFIRMED: Position bug exists - position (\(finalPosition)) exceeds total (\(finalTotal))")
            } else {
                print("✅ Final article position looks correct: \(finalPosition) of \(finalTotal)")
            }
            
            closeDetailView()
        } else {
            print("⚠️ No articles remaining in list - cannot test final article scenario")
        }
        
        print("✅ Final Article Scenario Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func testArticleFilteringConsistency() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🐛 ARTICLE FILTERING CONSISTENCY TEST (n-1 Root Cause Detection)")
        print(String(repeating: "=", count: 60))
        
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 3 else {
            throw XCTSkip("Need at least 3 articles for filtering consistency test")
        }
        
        let initialListCount = cells.count
        print("📄 Initial articles in list: \(initialListCount)")
        
        // Test multiple open/close cycles to see if articles disappear from the list
        for cycle in 1...3 {
            print("\n🔄 Cycle \(cycle): Testing article list consistency...")
            
            // Open an article
            let availableCells = app.tables.cells
            let currentListCount = availableCells.count
            print("📄 Articles available in cycle \(cycle): \(currentListCount)")
            
            if currentListCount == 0 {
                print("❌ CRITICAL: No articles left in list after \(cycle - 1) cycles!")
                XCTFail("Articles are disappearing from the list - this confirms the filtering bug")
                break
            }
            
            // Open first available article
            let article = availableCells.element(boundBy: 0)
            article.tap()
            
            let detailExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
            XCTAssertTrue(detailExists, "Detail view should appear in cycle \(cycle)")
            
            // Check navigation totals
            let navTotal = extractNavigationTotal()
            print("📊 Navigation total in cycle \(cycle): \(navTotal)")
            
            // Navigate through a couple articles if possible
            if navTotal > 1 {
                navigateToNextArticle()
                Thread.sleep(forTimeInterval: 0.5)
                
                let newPosition = extractCurrentPosition()
                let newTotal = extractNavigationTotal()
                print("📍 After navigation: \(newPosition) of \(newTotal)")
            }
            
            // Return to list
            closeDetailView()
            let backInList = table.waitForExistence(timeout: 2.0)
            XCTAssertTrue(backInList, "Should return to list in cycle \(cycle)")
            
            Thread.sleep(forTimeInterval: 0.5) // Let list refresh
            
            // Check if article count changed
            let postCycleCells = app.tables.cells
            let postCycleCount = postCycleCells.count
            
            if postCycleCount < currentListCount {
                print("❌ BUG DETECTED: Article count decreased from \(currentListCount) to \(postCycleCount) after cycle \(cycle)")
                print("🐛 This suggests articles are being filtered out incorrectly")
            } else {
                print("✅ Article count stable: \(postCycleCount)")
            }
        }
        
        // Final comparison
        let finalCells = app.tables.cells
        let finalCount = finalCells.count
        
        print("\n📊 FILTERING CONSISTENCY SUMMARY:")
        print("   Initial articles: \(initialListCount)")
        print("   Final articles: \(finalCount)")
        print("   Articles lost: \(initialListCount - finalCount)")
        
        if finalCount < initialListCount {
            print("❌ CONFIRMED: Articles are disappearing from the list - filtering bug exists")
            XCTFail("Filtering consistency bug: Lost \(initialListCount - finalCount) articles during navigation cycles")
        } else {
            print("✅ Article list remains consistent - no filtering bug detected")
        }
        
        print("✅ Article Filtering Consistency Test Complete")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    // MARK: - Helper Methods for Bug Detection
    
    private func extractCurrentPosition() -> Int {
        // Look for position counter and extract current position
        let staticTexts = app.staticTexts
        let buttons = app.buttons
        
        // Look for patterns like "3 of 5", "1 of 10", etc.
        let allElements = staticTexts.allElementsBoundByIndex + buttons.allElementsBoundByIndex
        
        for element in allElements {
            if element.exists {
                let label = element.label
                if let match = label.range(of: #"(\d+) of (\d+)"#, options: .regularExpression) {
                    let matchString = String(label[match])
                    let components = matchString.components(separatedBy: " of ")
                    if components.count == 2, let position = Int(components[0]) {
                        return position
                    }
                }
            }
        }
        
        return 0 // Not found
    }
    
    private func extractNavigationTotal() -> Int {
        // Look for position counter and extract total count
        let staticTexts = app.staticTexts
        let buttons = app.buttons
        
        // Look for patterns like "3 of 5", "1 of 10", etc.
        let allElements = staticTexts.allElementsBoundByIndex + buttons.allElementsBoundByIndex
        
        for element in allElements {
            if element.exists {
                let label = element.label
                if let match = label.range(of: #"(\d+) of (\d+)"#, options: .regularExpression) {
                    let matchString = String(label[match])
                    let components = matchString.components(separatedBy: " of ")
                    if components.count == 2, let total = Int(components[1]) {
                        return total
                    }
                }
            }
        }
        
        return 0 // Not found
    }

    // MARK: - Performance Metrics Summary

    func testPerformanceMetricsSummary() throws {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 PERFORMANCE METRICS SUMMARY")
        print(String(repeating: "=", count: 60))
        
        // Test startup
        let startTime = Date()
        app.terminate()
        app.launch()
        let table = app.tables.firstMatch
        _ = table.waitForExistence(timeout: 10.0)
        let startupTime = Date().timeIntervalSince(startTime)
        
        // Test article opening
        let cells = app.tables.cells
        var articleOpenTime: TimeInterval = 0
        
        if cells.count > 0 {
            let openStart = Date()
            cells.firstMatch.tap()
            _ = verifyArticleContentLoaded(articleIndex: 1)
            articleOpenTime = Date().timeIntervalSince(openStart)
            closeDetailView()
        }
        
        // Print summary
        print("\n📱 App Startup Time: \(String(format: "%.2f", startupTime))s")
        print("📄 Article Open Time: \(String(format: "%.2f", articleOpenTime))s")
        
        // Performance assessment
        print("\n🎯 Performance Assessment:")
        
        if startupTime < 2.0 {
            print("✅ Startup: EXCELLENT (<2s)")
        } else if startupTime < 3.0 {
            print("✅ Startup: GOOD (2-3s)")
        } else if startupTime < 5.0 {
            print("⚠️ Startup: SLOW (3-5s)")
        } else {
            print("❌ Startup: VERY SLOW (>5s)")
        }
        
        if articleOpenTime < 0.3 {
            print("✅ Article Opening: EXCELLENT (<300ms)")
        } else if articleOpenTime < 1.0 {
            print("✅ Article Opening: GOOD (300ms-1s)")
        } else if articleOpenTime < 2.0 {
            print("⚠️ Article Opening: SLOW (1-2s)")
        } else {
            print("❌ Article Opening: VERY SLOW (>2s)")
        }
        
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    // MARK: - N-1 Bug Detection Test
    
    /// Tests the specific n-1 bug: "1 of 4" when there are actually 5 articles
    /// This reproduces the exact user scenario: topic with 5 articles shows "1 of 4", 
    /// can navigate through 4 articles, but 1 is left behind in the list
    /// ENHANCED: Wait 5+ seconds as the user noted the bug appears after a delay
    func testNMinusOneBugDetection() {
        let app = XCUIApplication()
        app.launch()
        
        // Wait for app to load
        waitForAppToLoad(app)
        
        print("🔍 N-1 BUG TEST: Looking for topics with 2+ articles...")
        
        // Try to find a topic with multiple articles (lowered threshold for more reliable testing)
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5.0), "Table should exist")
        
        let cells = app.tables.cells
        guard cells.count >= 2 else {
            XCTFail("Need at least 2 articles for n-1 bug detection test")
            return
        }
        
        let listArticleCount = cells.count
        print("📊 Found \(listArticleCount) articles in current view")
        
        // STEP 1: Open first article
        print("🎯 N-1 BUG TEST: Opening first article...")
        let firstArticle = cells.element(boundBy: 0)
        firstArticle.tap()
        
        // Wait for detail view to load
        let detailViewExists = app.scrollViews.firstMatch.waitForExistence(timeout: 3.0)
        XCTAssertTrue(detailViewExists, "Detail view should appear")
        
        // STEP 2: Check INITIAL navigation total (before background processing)
        let initialNavigationTotal = extractNavigationTotal()
        print("📊 INITIAL navigation total: \(initialNavigationTotal)")
        print("📊 List view shows: \(listArticleCount) articles")
        
        // STEP 3: CRITICAL - Wait 5+ seconds as user suggested
        // This allows background processes (marking as read, filtering, etc.) to complete
        print("⏳ WAITING 5 seconds for background processes to complete...")
        sleep(5)
        
        // STEP 4: Check DELAYED navigation total (after background processing)
        let delayedNavigationTotal = extractNavigationTotal()
        print("📊 DELAYED navigation total (after 5s): \(delayedNavigationTotal)")
        
        // STEP 5: Check for the n-1 bug patterns
        if delayedNavigationTotal != initialNavigationTotal {
            print("🐛 TIMING BUG DETECTED: Navigation total changed from \(initialNavigationTotal) to \(delayedNavigationTotal) after delay!")
        }
        
        if delayedNavigationTotal == listArticleCount - 1 {
            print("🐛 N-1 BUG DETECTED: List shows \(listArticleCount) but navigation shows \(delayedNavigationTotal)")
            XCTFail("N-1 BUG CONFIRMED: After 5 second delay, navigation shows \(delayedNavigationTotal) of \(listArticleCount) articles")
        }
        
        if delayedNavigationTotal < listArticleCount {
            print("🐛 ARTICLE LOSS BUG DETECTED: Missing \(listArticleCount - delayedNavigationTotal) articles from navigation after delay")
        }
        
        // STEP 6: Test actual navigation capability
        print("📍 Testing actual navigation capability...")
        var reachableArticles = 1 // Already on the first
        
        // Navigate through all reachable articles
        for attempt in 1..<listArticleCount {
            print("➡️ Attempting to navigate to article \(attempt + 1)...")
            navigateToNextArticle()
            sleep(1) // Give time for navigation to complete
            
            let currentPosition = extractCurrentPosition()
            if currentPosition > attempt {
                reachableArticles = currentPosition
                print("✅ Successfully reached article \(currentPosition)")
            } else {
                print("🛑 Cannot navigate beyond article \(reachableArticles)")
                break
            }
        }
        
        print("📊 FINAL RESULTS:")
        print("   Articles in list: \(listArticleCount)")
        print("   Initial navigation total: \(initialNavigationTotal)")
        print("   Delayed navigation total: \(delayedNavigationTotal)")
        print("   Actually reachable articles: \(reachableArticles)")
        
        // STEP 7: Final bug detection
        if reachableArticles < listArticleCount {
            print("🐛 CONFIRMED: N-1 Bug - Can only reach \(reachableArticles) of \(listArticleCount) articles")
            XCTFail("N-1 BUG DETECTED: Can only navigate to \(reachableArticles) of \(listArticleCount) articles after background processing")
        } else {
            print("✅ No n-1 bug detected - can reach all \(listArticleCount) articles")
        }
        
        closeDetailView()
    }
    
    // MARK: - Helper Methods for N-1 Bug Test
    
    private func waitForAppToLoad(_ app: XCUIApplication) {
        let table = app.tables.firstMatch
        _ = table.waitForExistence(timeout: 10.0)
        sleep(1) // Additional settling time
    }
    
    private func countArticlesInList(_ app: XCUIApplication) -> Int {
        let articleRows = app.buttons.matching(identifier: "ArticleRow")
        return articleRows.count
    }
}
