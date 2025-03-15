import SwiftData
import XCTest

extension XCUIApplication {
    /// Configures the application for UI testing with test data
    func configureForUITesting() {
        // These launch arguments will be read by the app to detect testing mode
        launchArguments = ["UI_TESTING"]

        // Set environment variables to control test data
        launchEnvironment["SETUP_TEST_DATA"] = "1"
    }
}
