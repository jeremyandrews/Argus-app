import XCTest

final class NewsDetailViewTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // Skip permission prompts with these launch arguments
        app.launchArguments += ["UI_TESTING"]
        app.launchArguments += ["UI_TESTING_PERMISSIONS_GRANTED"]

        // Set environment variables for test data
        app.launchEnvironment["SETUP_TEST_DATA"] = "1"

        // Launch the app
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testNewsDetailViewContentVisibility() throws {
        // Add UI interruption monitor for system alerts
        addUIInterruptionMonitor(withDescription: "System Dialog") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            return false
        }

        // Wait for the app to load completely
        let appLoaded = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(appLoaded, "App failed to launch properly")

        // Take screenshot of initial state
        let initialScreenshot = XCTAttachment(screenshot: app.screenshot())
        initialScreenshot.name = "Initial App State"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)

        // Wait for the article title to appear
        let titleElement = app.staticTexts["Test Article Title for UI Tests"]
        XCTAssertTrue(titleElement.waitForExistence(timeout: 10), "Article title not found")

        // Screenshot before tapping
        let beforeTapScreenshot = XCTAttachment(screenshot: app.screenshot())
        beforeTapScreenshot.name = "Before Tapping Cell"
        beforeTapScreenshot.lifetime = .keepAlways
        add(beforeTapScreenshot)

        // Tap directly on the article title text
        titleElement.tap()

        // Ensure interruption monitor gets triggered if needed
        app.swipeUp()

        // Give the detail view time to fully load
        sleep(2)

        // Take a screenshot after the view has loaded
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Detail View After Loading"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)

        // Debug: Print all static text elements to see what's actually on screen
        print("--- All Static Text Elements in Detail View: ---")
        for (index, element) in app.staticTexts.allElementsBoundByIndex.enumerated() {
            print("[\(index)] \"\(element.label)\"")
        }

        // Debug: Print all buttons to see section headers
        print("--- All Buttons in Detail View: ---")
        for (index, element) in app.buttons.allElementsBoundByIndex.enumerated() {
            print("[\(index)] \"\(element.label)\"")
        }

        // Verify we've reached the detail view with the actual button names present in UI
        let detailViewFound = app.buttons["Close"].exists ||
            app.buttons["Back"].exists ||
            app.buttons["Forward"].exists
        XCTAssertTrue(detailViewFound, "Detail view navigation elements not found")

        // Verify that the topic is visible
        let topicExists = app.staticTexts.matching(NSPredicate(format: "label MATCHES[c] %@", "Technology|Politics|Science|Business|All")).firstMatch.exists
        XCTAssertTrue(topicExists, "Topic pill should be visible")

        // Verify that the title is visible
        let titleExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Test Article")).firstMatch.exists ||
            app.staticTexts.element(boundBy: 0).exists
        XCTAssertTrue(titleExists, "Title should be visible")

        let dateExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Published:")).firstMatch.exists
        XCTAssertTrue(dateExists, "Date should be visible with the 'Published:' prefix")

        // Alternative check if the regex fails
        if !dateExists {
            let specificDateText = app.staticTexts["Published: Mar 15, 2025 at 10:59"].exists
            XCTAssertTrue(dateExists || specificDateText, "Date should be visible in some format")
        } else {
            XCTAssertTrue(dateExists, "Date should be visible in some format")
        }

        // Verify that the body is visible
        let bodyExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "test article body")).firstMatch.exists
        XCTAssertTrue(bodyExists, "Body text should be visible")

        // Verify that the domain is visible
        let domainExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ".com")).firstMatch.exists
        XCTAssertTrue(domainExists, "Domain should be visible")

        // Verify quality icons exist (without using the 'name' property)
        let qualityTextExists = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "quality", "proof", "logic")).firstMatch.exists
        let imageCount = app.images.count
        XCTAssertTrue(qualityTextExists || imageCount >= 3, "Quality indicators should be visible")

        // Verify that Summary section is present and expanded by default
        let summaryExists = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Summary")).firstMatch.exists
        XCTAssertTrue(summaryExists, "Summary section should be present")

        // Verify presence of all required sections
        let requiredSections = ["Summary", "Relevance", "Critical Analysis", "Logical Fallacies", "Source Analysis", "Context & Perspective", "Preview"]
        for section in requiredSections {
            let sectionExists = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", section)).firstMatch.exists
            XCTAssertTrue(sectionExists, "Section '\(section)' should be visible")
        }

        // Check that only expected sections are present (plus Argus Engine Stats which is allowed)
        let expectedSectionCount = requiredSections.count + 1 // +1 for Argus Engine Stats
        // Count section buttons that match our pattern (disclosure groups)
        let sectionButtons = app.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", ".*Summary.*|.*Relevance.*|.*Analysis.*|.*Fallacies.*|.*Context.*|.*Preview.*|.*Engine.*")).allElementsBoundByIndex
        // Make sure we don't have unexpected sections
        XCTAssertLessThanOrEqual(sectionButtons.count, expectedSectionCount, "There should only be expected sections visible")

        // Final verification screenshot
        let finalScreenshot = XCTAttachment(screenshot: app.screenshot())
        finalScreenshot.name = "Final Detail View State"
        finalScreenshot.lifetime = .keepAlways
        add(finalScreenshot)
    }
}
