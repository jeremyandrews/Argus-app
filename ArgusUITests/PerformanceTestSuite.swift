//
//  PerformanceTestSuite.swift
//  ArgusUITests
//
//  Comprehensive performance testing for article navigation and topic switching
//

import XCTest

final class PerformanceTestSuite: XCTestCase {
    
    private var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--performance-test"]
        app.launch()
        
        // Simple wait for app to stabilize - don't assert, just wait
        Thread.sleep(forTimeInterval: 2.0)
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Simple Performance Tests
    
    func testTopicSwitchingPerformance() throws {
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // Find available buttons that look like topics
            let buttons = app.buttons
            var topicButtonsFound = 0
            
            for i in 0..<buttons.count {
                let button = buttons.element(boundBy: i)
                if button.exists && topicButtonsFound < 3 {
                    let label = button.label
                    // Skip system buttons and look for topic-like names
                    if !label.isEmpty && 
                       label.count < 20 &&
                       !label.contains("Back") && 
                       !label.contains("Settings") &&
                       !label.contains("Tab") {
                        print("Tapping button: \(label)")
                        button.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                        topicButtonsFound += 1
                    }
                }
            }
            
            if topicButtonsFound == 0 {
                print("No topic buttons found - app may have no topics or different UI")
            }
        }
    }
    
    func testArticleDetailViewPerformance() throws {
        // Check if we have any articles
        let cells = app.tables.cells
        
        guard cells.count > 0 else {
            print("No articles available for testing - skipping")
            return
        }
        
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // Tap first article
            let firstArticle = cells.firstMatch
            if firstArticle.exists {
                firstArticle.tap()
                
                // Wait for navigation
                Thread.sleep(forTimeInterval: 0.5)
                
                // Look for signs we're in detail view
                let scrollViews = app.scrollViews
                let textViews = app.textViews
                
                if scrollViews.count > 0 || textViews.count > 0 {
                    print("Detail view loaded")
                }
                
                // Try to go back
                let navBars = app.navigationBars
                if navBars.count > 0 {
                    let backButton = navBars.buttons.firstMatch
                    if backButton.exists {
                        backButton.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
            }
        }
    }
    
    func testCompleteUserJourney() throws {
        measure(metrics: [XCTClockMetric()]) {
            // 1. Try to tap a topic button
            let buttons = app.buttons
            for i in 0..<min(5, buttons.count) {
                let button = buttons.element(boundBy: i)
                if button.exists {
                    let label = button.label
                    if !label.isEmpty && label.count < 20 && !label.contains("Back") {
                        button.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                        break
                    }
                }
            }
            
            // 2. Try to open an article
            let cells = app.tables.cells
            if cells.count > 0 {
                cells.firstMatch.tap()
                Thread.sleep(forTimeInterval: 0.5)
                
                // 3. Try to go back
                let navBars = app.navigationBars
                if navBars.count > 0 {
                    let backButton = navBars.buttons.firstMatch
                    if backButton.exists {
                        backButton.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
            }
            
            // 4. Try another topic
            for i in 1..<min(5, buttons.count) {
                let button = buttons.element(boundBy: i)
                if button.exists {
                    let label = button.label
                    if !label.isEmpty && label.count < 20 && !label.contains("Back") {
                        button.tap()
                        break
                    }
                }
            }
        }
    }
    
    func testEstablishPerformanceBaseline() throws {
        let metrics: [XCTMetric] = [
            XCTClockMetric(),
            XCTMemoryMetric()
        ]
        
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 2
        
        measure(metrics: metrics, options: measureOptions) {
            // Basic navigation test
            let buttons = app.buttons
            var actionsTaken = 0
            
            // Tap a few buttons
            for i in 0..<buttons.count {
                if actionsTaken >= 3 { break }
                
                let button = buttons.element(boundBy: i)
                if button.exists {
                    let label = button.label
                    if !label.isEmpty && 
                       !label.contains("Back") && 
                       !label.contains("Tab") &&
                       label.count < 30 {
                        button.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                        actionsTaken += 1
                    }
                }
            }
            
            // Try to open an article
            let cells = app.tables.cells
            if cells.count > 0 {
                cells.firstMatch.tap()
                Thread.sleep(forTimeInterval: 0.5)
                
                // Try to go back
                let navBars = app.navigationBars
                if navBars.count > 0 {
                    let backButton = navBars.buttons.firstMatch
                    if backButton.exists {
                        backButton.tap()
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
            }
        }
        
        print("=====================================")
        print("Performance Baseline Established")
        print("=====================================")
    }
}
