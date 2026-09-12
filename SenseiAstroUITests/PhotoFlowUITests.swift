import XCTest

final class PhotoFlowUITests: XCTestCase {
    func testEditorCompareInspectExportAndRecoverProject() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-ui-test"]
        app.launch()
        let compare = app.buttons["compareOriginal"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["EDITED PREVIEW"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Measured starting edit applied automatically. Your original remains unchanged."].exists)
        attach(app, "01-editor")
        compare.tap()
        XCTAssertTrue(app.staticTexts["ORIGINAL"].exists)
        app.buttons["inspectSource"].tap()
        XCTAssertTrue(app.buttons["Source detail"].waitForExistence(timeout: 5))
        app.buttons["Source detail"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "source-pixel region")).firstMatch.waitForExistence(timeout: 20))
        attach(app, "02-source-detail")
        app.buttons["Done"].tap()
        reveal(app.buttons["applyAdvice"], in: app)
        app.buttons["applyAdvice"].tap()
        reveal(app.buttons["prepareExport"], in: app)
        app.buttons["prepareExport"].tap()
        XCTAssertTrue(app.staticTexts["exportVerified"].waitForExistence(timeout: 30))
        attach(app, "03-verified-export")
        app.terminate(); app.launch()
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        app.buttons["savedProjects"].tap()
        XCTAssertTrue(app.navigationBars["Your projects"].waitForExistence(timeout: 10))
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
