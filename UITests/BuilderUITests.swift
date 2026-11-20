import XCTest

final class BuilderUITests: XCTestCase {
    func testOpenPlannerBeforeConnectingAnyAccounts() throws {
        let app = XCUIApplication()
        app.launch()
        let create = app.buttons["Create a soundtrack"]
        XCTAssertTrue(create.waitForExistence(timeout:12))
        create.tap()
        XCTAssertTrue(app.buttons["Choose starting point"].waitForExistence(timeout:6))
        app.buttons["Choose starting point"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout:6))
    }
}
