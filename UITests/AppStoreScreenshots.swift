import XCTest

/// The App Store screenshots, from the same seeded `-uitest` library as the other tests.
/// Skipped unless scripts/screenshots.sh runs it (it sets TEST_RUNNER_RESYNC_SHOTS=1).
final class AppStoreScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RESYNC_SHOTS"] == "1",
                          "run by scripts/screenshots.sh")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func button(beginningWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", text)).firstMatch
    }

    private func shot(_ name: String) {
        // Let toasts and map tiles settle.
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "appstore-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) {
        el("tab.\(name)").tap()
        XCTAssertTrue(el("path.current").waitForExistence(timeout: 2))
    }

    func testScreenshots() {
        let rows = app.buttons.matching(identifier: "recipe.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        shot("1-recipes")

        app.buttons.matching(NSPredicate(format: "identifier == 'recipe.row' AND label CONTAINS[c] 'kodachrome'")).firstMatch.tap()
        XCTAssertTrue(el("stepper.highlight").waitForExistence(timeout: 2))
        shot("2-editor")

        button(beginningWith: "send to camera").tap()
        let c6 = el("slot.c6")
        XCTAssertTrue(c6.waitForExistence(timeout: 2))
        c6.tap()
        shot("3-send")
        el("sheet.close").tap()
        button(beginningWith: "back to recipes").tap()

        tab("shoot")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "map.pin").firstMatch.waitForExistence(timeout: 5))
        let chip = el("map.routes")
        if chip.waitForExistence(timeout: 2) {
            chip.tap()
            let routes = app.descendants(matching: .any).matching(identifier: "route.row")
            if routes.firstMatch.waitForExistence(timeout: 2) { routes.firstMatch.tap() }
        }
        sleep(3)
        shot("4-map")

        tab("camera")
        shot("5-camera")
    }
}
