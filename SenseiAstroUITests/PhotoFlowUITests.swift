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
