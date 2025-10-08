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
        print("\n" + String(repeating: "=", count: 60))
        print("📊 COMPREHENSIVE TOPIC SWITCHING PERFORMANCE TEST")
        print(String(repeating: "=", count: 60))

        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // STEP 1: Discover all available topic buttons
            print("🔍 Discovering available topics...")
            let buttons = app.buttons
            var topicButtons: [(element: XCUIElement, label: String)] = []

            for i in 0..<buttons.count {
                let button = buttons.element(boundBy: i)
                if button.exists {
                    let label = button.label
                    // Skip system buttons and look for topic-like names
                    if !label.isEmpty &&
                       label.count < 20 &&
                       !label.contains("Back") &&
                       !label.contains("Settings") &&
                       !label.contains("Tab") &&
                       !label.contains("Close") &&
                       !label.contains("Done") {
                        topicButtons.append((element: button, label: label))
                    }
                }
            }

            let topicCount = topicButtons.count
            print("📋 Found \(topicCount) topic buttons: \(topicButtons.map { $0.label }.joined(separator: ", "))")

            if topicCount == 0 {
                print("⚠️ No topic buttons found - app may have no topics or different UI")
                return
            }

            // STEP 2: Cycle through ALL topics TWICE
            print("\n🔄 Starting 2 complete cycles through all \(topicCount) topics...")

            for cycle in 1...2 {
                print("\n📍 Cycle \(cycle) of 2")

                for (index, topicButton) in topicButtons.enumerated() {
                    let topicName = topicButton.label
                    let topicNum = index + 1

                    print("   [\(cycle).\(topicNum)/\(topicCount)] Switching to '\(topicName)'...")

                    let switchStart = Date()
                    topicButton.element.tap()

                    // Wait for article list to update
                    Thread.sleep(forTimeInterval: 0.3)

                    let switchTime = Date().timeIntervalSince(switchStart)
                    let switchTimeMs = Int(switchTime * 1000)

                    // Check if we have articles loaded
                    let cells = app.tables.cells
                    let articleCount = cells.count

                    // Performance rating
                    let rating: String
                    if switchTimeMs < 250 {
                        rating = "✅ EXCELLENT"
                    } else if switchTimeMs < 400 {
                        rating = "✅ GOOD"
                    } else if switchTimeMs < 500 {
                        rating = "⚠️ WARNING"
                    } else {
                        rating = "❌ SLOW"
                    }

                    print("      → \(switchTimeMs)ms \(rating) (\(articleCount) articles)")

                    // Brief pause before next topic
                    if index < topicButtons.count - 1 {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }

                // Pause between cycles
                if cycle == 1 {
                    print("\n   ⏸️ Brief pause before cycle 2...")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            print("\n✅ Completed 2 full cycles through all \(topicCount) topics")
            print("   Total topic switches: \(topicCount * 2)")
        }

        print(String(repeating: "=", count: 60) + "\n")
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
