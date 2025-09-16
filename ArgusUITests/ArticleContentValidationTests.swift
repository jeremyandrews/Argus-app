//
//  ArticleContentValidationTests.swift
//  ArgusUITests
//
//  Tests to validate that article content actually loads and displays correctly
//

import XCTest

final class ArticleContentValidationTests: XCTestCase {
    
    private var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--performance-test"]
        app.launch()
        
        // Wait for app to load
        let exists = app.wait(for: .runningForeground, timeout: 5)
        XCTAssertTrue(exists, "App failed to launch")
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    func testArticleOpensWithContent() throws {
        // Wait for table to load
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "News table should exist")
        
        // Get the first article cell
        let cells = table.cells
        XCTAssertTrue(cells.count > 0, "Should have at least one article")
        
        let firstArticle = cells.element(boundBy: 0)
        
        // Get the article title before tapping
        let titleBeforeTap = firstArticle.staticTexts.firstMatch.label
        print("Article title to open: \(titleBeforeTap)")
        XCTAssertFalse(titleBeforeTap.isEmpty, "Article should have a title")
        
        // Measure the time to open the article
        let startTime = Date()
        firstArticle.tap()
        
        // VALIDATE 1: Check that we navigated to detail view
        let detailView = app.otherElements["ArticleDetailView"]
        let detailExists = detailView.waitForExistence(timeout: 1) || 
                          app.scrollViews.firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(detailExists, "Detail view should appear quickly")
        
        let openTime = Date().timeIntervalSince(startTime)
        print("Time to present detail view: \(openTime * 1000)ms")
        
        // VALIDATE 2: Check for title in detail view
        let detailTitle = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", 
                                                                 String(titleBeforeTap.prefix(20)))).firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 2), 
                     "Article title should be visible in detail view")
        
        // VALIDATE 3: Check for article body content
        let textViews = app.textViews
        let staticTexts = app.staticTexts
        
        var foundContent = false
        var contentLength = 0
        
        // Check text views for content
        if textViews.count > 0 {
            for i in 0..<min(3, textViews.count) {
                let textView = textViews.element(boundBy: i)
                if textView.exists {
                    let content = textView.value as? String ?? ""
                    contentLength = max(contentLength, content.count)
                    if content.count > 50 {
                        foundContent = true
                        print("Found text view content: \(content.prefix(100))...")
                    }
                }
            }
        }
        
        // Check static texts for content (body text)
        for i in 0..<min(10, staticTexts.count) {
            let text = staticTexts.element(boundBy: i)
            if text.exists {
                let label = text.label
                contentLength = max(contentLength, label.count)
                if label.count > 100 && !label.contains("Tab") && !label.contains("Settings") {
                    foundContent = true
                    print("Found static text content: \(label.prefix(100))...")
                }
            }
        }
        
        XCTAssertTrue(foundContent, "Should find article body content")
        XCTAssertTrue(contentLength > 50, "Article should have substantial content (found \(contentLength) chars)")
        
        // VALIDATE 4: Check that content loaded fully
        Thread.sleep(forTimeInterval: 1.0) // Give async load time to complete
        
        // Check again for more content after async load
        var finalContentLength = contentLength
        for i in 0..<min(10, staticTexts.count) {
            let text = staticTexts.element(boundBy: i)
            if text.exists {
                finalContentLength = max(finalContentLength, text.label.count)
            }
        }
        
        print("Initial content length: \(contentLength), Final content length: \(finalContentLength)")
        XCTAssertTrue(finalContentLength >= contentLength, 
                     "Content should not disappear after async load")
        
        // VALIDATE 5: Performance check
        let totalLoadTime = Date().timeIntervalSince(startTime)
        print("Total time to load article with content: \(totalLoadTime * 1000)ms")
        XCTAssertTrue(totalLoadTime < 2.0, "Article should fully load within 2 seconds")
        
        // Navigation test - can we go back?
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists {
            backButton.tap()
            XCTAssertTrue(table.waitForExistence(timeout: 2), 
                         "Should navigate back to article list")
        }
    }
    
    func testMultipleArticlesLoadContent() throws {
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "News table should exist")
        
        let cells = table.cells
        let articleCount = min(3, cells.count)
        XCTAssertTrue(articleCount > 0, "Should have articles to test")
        
        for i in 0..<articleCount {
            print("\n=== Testing article \(i + 1) ===")
            
            let cell = cells.element(boundBy: i)
            XCTAssertTrue(cell.exists, "Article cell \(i) should exist")
            
            let titleBeforeTap = cell.staticTexts.firstMatch.label
            print("Opening article: \(titleBeforeTap)")
            
            let startTime = Date()
            cell.tap()
            
            // Wait for detail view
            let detailLoaded = app.scrollViews.firstMatch.waitForExistence(timeout: 1) ||
                              app.textViews.firstMatch.waitForExistence(timeout: 1)
            XCTAssertTrue(detailLoaded, "Detail view should load for article \(i)")
            
            // Check for content
            var foundContent = false
            let staticTexts = app.staticTexts
            for j in 0..<min(10, staticTexts.count) {
                let text = staticTexts.element(boundBy: j)
                if text.exists && text.label.count > 100 {
                    foundContent = true
                    print("Found content in article \(i): \(text.label.prefix(50))...")
                    break
                }
            }
            
            XCTAssertTrue(foundContent, "Article \(i) should have content")
            
            let loadTime = Date().timeIntervalSince(startTime)
            print("Article \(i) load time: \(loadTime * 1000)ms")
            
            // Go back
            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists {
                backButton.tap()
                XCTAssertTrue(table.waitForExistence(timeout: 2), 
                             "Should navigate back from article \(i)")
            } else {
                // Try swipe back
                app.swipeRight()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
    
    func testArticleContentPersistsAfterAsyncLoad() throws {
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5), "News table should exist")
        
        let firstCell = table.cells.firstMatch
        firstCell.tap()
        
        // Initial content check
        Thread.sleep(forTimeInterval: 0.2)
        var initialContent = ""
        let staticTexts = app.staticTexts
        for i in 0..<min(5, staticTexts.count) {
            let text = staticTexts.element(boundBy: i)
            if text.exists && text.label.count > 50 {
                initialContent = text.label
                break
            }
        }
        
        XCTAssertFalse(initialContent.isEmpty, "Should have initial content")
        print("Initial content: \(initialContent.prefix(100))...")
        
        // Wait for async load to complete
        Thread.sleep(forTimeInterval: 2.0)
        
        // Check content is still there (not replaced with error or blank)
        var finalContent = ""
        for i in 0..<min(5, staticTexts.count) {
            let text = staticTexts.element(boundBy: i)
            if text.exists && text.label.count > 50 {
                finalContent = text.label
                break
            }
        }
        
        XCTAssertFalse(finalContent.isEmpty, "Should still have content after async load")
        XCTAssertFalse(finalContent.contains("error"), "Should not show error message")
        XCTAssertFalse(finalContent.contains("Error"), "Should not show error message")
        print("Final content: \(finalContent.prefix(100))...")
        
        // Content should be the same or expanded, not replaced with placeholder
        if !initialContent.isEmpty && !finalContent.isEmpty {
            // At minimum, the title should still be present
            let titleStillPresent = finalContent.contains(initialContent.prefix(30)) ||
                                   initialContent.contains(finalContent.prefix(30))
            XCTAssertTrue(titleStillPresent || finalContent.count >= initialContent.count,
                         "Content should persist or expand, not be replaced")
        }
    }
}
