import XCTest

final class CompositorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateCanvasAndNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["widthInput"].waitForExistence(timeout: 5))
        let width = app.textFields["widthInput"]
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("0")
        XCTAssertFalse(app.buttons["createCanvas"].isEnabled)
        width.typeKey("a", modifierFlags: .command)
        width.typeText("1200")
        let height = app.textFields["heightInput"]
        height.click()
        height.typeKey("a", modifierFlags: .command)
        height.typeText("800")
        app.buttons["createCanvas"].click()
        XCTAssertTrue((app.staticTexts["zoomStatus"].value as? String ?? "").contains("1,200 × 800"))
        app.buttons["actualPixels"].click()
        XCTAssertTrue((app.staticTexts["zoomStatus"].value as? String ?? "").hasPrefix("100%"))
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue((app.staticTexts["zoomStatus"].value as? String ?? "").hasPrefix("125%"))
        app.buttons["fitCanvas"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor foundation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("n", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue((app.staticTexts["zoomStatus"].value as? String ?? "").contains("1,200 × 800"))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Explicit macOS baseline: includes XCTest launch/idle/accessibility overhead.
        let app = XCUIApplication()
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.textFields["widthInput"].waitForExistence(timeout: 5))
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("LAUNCH_TO_READY_SECONDS: \(samples)")
        print("LAUNCH_TO_READY_MEDIAN: \(samples.sorted()[2])")
    }
}
