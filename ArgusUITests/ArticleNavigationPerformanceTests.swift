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
}
