import XCTest

final class PhotoFlowUITests: XCTestCase {
    func testResetAllAndUndoRestoreAutomaticDevelopment() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["compareOriginal"].waitForExistence(timeout: 30))
        let automatic = app.switches["automaticProcessing"]
        reveal(automatic, in: app)
        if automatic.value as? String != "1" { automatic.tap() }
        XCTAssertTrue(app.sliders["Automatic strength"].exists)
        app.sliders["Automatic strength"].adjust(toNormalizedSliderPosition: 0.4)
        reveal(app.buttons["resetAllEdits"], in: app)
        app.buttons["resetAllEdits"].tap()
        for _ in 0..<12 {
            if app.buttons["Undo"].isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(app.buttons["Undo"].isHittable)
        app.buttons["Undo"].tap()
        for _ in 0..<12 {
            if automatic.isHittable { break }
            app.swipeDown()
        }
        XCTAssertEqual(automatic.value as? String, "1")
        attach(app, "05-automatic-strength-and-undo")
    }

    func testCloudNavigationDoesNotInventForecastWhileUnavailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-ui-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Clouds"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Clouds"].tap()
        XCTAssertTrue(app.staticTexts["NEAR NOW"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No nearby sample"].exists)
        XCTAssertTrue(app.staticTexts["No remaining sample"].exists)
        attach(app, "06-cloud-unavailable-state")
    }
    func testEditorCompareInspectExportAndRecoverProject() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-ui-test"]
        app.launch()
        let compare = app.buttons["compareOriginal"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["EDITED PREVIEW"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Astrophotography development applied from measured source pixels. Your original remains unchanged."].exists)
        attach(app, "01-editor")
        compare.tap()
        XCTAssertTrue(app.staticTexts["ORIGINAL"].exists)
        app.buttons["inspectSource"].tap()
        XCTAssertTrue(app.buttons["Source detail"].waitForExistence(timeout: 5))
        app.buttons["Source detail"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "source-pixel region")).firstMatch.waitForExistence(timeout: 20))
        attach(app, "02-source-detail")
        app.buttons["Done"].tap()
        reveal(app.switches["automaticProcessing"], in: app)
        XCTAssertEqual(app.switches["automaticProcessing"].value as? String, "1")
        reveal(app.buttons["prepareExport"], in: app)
        app.buttons["prepareExport"].tap()
        XCTAssertTrue(app.staticTexts["exportVerified"].waitForExistence(timeout: 30))
        attach(app, "03-verified-export")
        app.terminate(); app.launch()
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        let savedProjects = app.buttons["savedProjects"]
        XCTAssertTrue(savedProjects.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"),
            object: savedProjects)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        savedProjects.tap()
        XCTAssertTrue(app.navigationBars["Your projects"].waitForExistence(timeout: 20))
        XCTAssertGreaterThan(app.cells.count, 0)
        attach(app, "04-project-recovery")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
