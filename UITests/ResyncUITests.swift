import XCTest

/// Drives the app in the simulator with `-uitest`: a fresh library of the three starter
/// recipes, C1–C3 plus an unknown C5 "read" from the camera, no cable and no Bluetooth.
/// Every test attaches screenshots (kept on success) for a look against the prototype.
final class ResyncUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(fresh: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-uitest"] + (fresh ? ["-uitest-fresh"] : [])
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func button(beginningWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", text)).firstMatch
    }

    private var rows: XCUIElementQuery { app.buttons.matching(identifier: "recipe.row") }

    private func row(containing name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'recipe.row' AND label CONTAINS[c] %@", name)).firstMatch
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) {
        el("tab.\(name)").tap()
        XCTAssertTrue(el("path.current").waitForExistence(timeout: 2))
    }

    private func waitFor(_ e: XCUIElement, _ predicate: String, timeout: TimeInterval = 4) {
        let exp = expectation(for: NSPredicate(format: predicate), evaluatedWith: e)
        wait(for: [exp], timeout: timeout)
    }

    // MARK: Tests

    func testBootScreenSkipsToRecipes() {
        launch(fresh: true)
        let skip = button(beginningWith: "skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "the boot log should end on the pairing step")
        XCTAssertTrue(app.descendants(matching: .any)["resync"].exists)
        snap("01 boot")
        skip.tap()
        XCTAssertTrue(el("path.current").waitForExistence(timeout: 2))
        XCTAssertEqual(el("path.current").label, "recipes")
    }

    func testTabsSwitchAndShutterStaysSquare() {
        launch()
        for name in ["shoot", "recipes", "camera", "log"] {
            tab(name)
            XCTAssertEqual(el("path.current").label, name)
            snap("02 tab \(name)")
        }
        tab("shoot")
        let shutter = el("shutter")
        XCTAssertTrue(shutter.waitForExistence(timeout: 2))
        // The first device build stretched the shutter over half the screen.
        XCTAssertLessThanOrEqual(shutter.frame.width, 100)
        XCTAssertLessThanOrEqual(shutter.frame.height, 100)
        XCTAssertEqual(shutter.frame.width, shutter.frame.height, accuracy: 1)
    }

    func testRecipesShowCameraMarksAndPullQueues() {
        launch()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(el("filter.inCamera").label.contains("3"), "all three starters are in C1–C3")
        let pull = el("pullbar")
        XCTAssertTrue(pull.exists, "C5 isn't in the library, so the pull bar shows")
        XCTAssertTrue(pull.label.contains("1 in the camera"))
        snap("03 recipes")

        pull.tap()
        XCTAssertTrue(el("toast").waitForExistence(timeout: 2))
        snap("03 pull queued")

        tab("camera")
        XCTAssertTrue(app.staticTexts["pull c1–c7 → library"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["waiting for cable"].exists)
        snap("03 camera queue")
    }

    func testNewRecipeSavesItselfAndListsIt() {
        launch()
        button(beginningWith: "new").tap()
        XCTAssertEqual(el("path.current").label, "untitled")
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "test roll")
        waitFor(el("editor.save"), "label BEGINSWITH 'saved'")
        snap("04 editor new")

        button(beginningWith: "back to recipes").tap()
        XCTAssertTrue(row(containing: "test roll").waitForExistence(timeout: 2))
        XCTAssertEqual(rows.count, 4)
    }

    func testEditorStepperAndSimulationMenu() {
        launch()
        row(containing: "kodachrome").tap()
        XCTAssertEqual(el("path.current").label, "kodachrome-64")

        let highlight = el("stepper.highlight")
        XCTAssertTrue(highlight.waitForExistence(timeout: 2))
        let before = highlight.value as? String
        highlight.increment()
        XCTAssertNotEqual(highlight.value as? String, before)

        button(beginningWith: "simulation").tap()
        let acros = button(beginningWith: "acros")
        XCTAssertTrue(acros.waitForExistence(timeout: 2))
        snap("05 simulation sheet")
        acros.tap()
        XCTAssertTrue(el("stepper.mono warm/cool").waitForExistence(timeout: 2), "monochrome swaps color for warm/cool")
        waitFor(el("editor.save"), "label BEGINSWITH 'saved'")
        snap("05 editor acros")
    }

    func testSendQueuesAWriteUntilTheCableIsIn() {
        launch()
        row(containing: "kodachrome").tap()
        button(beginningWith: "send to camera").tap()
        let c6 = el("slot.c6")
        XCTAssertTrue(c6.waitForExistence(timeout: 2))
        c6.tap()
        snap("06 send sheet")
        button(beginningWith: "queue for c6").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'waits for the cable'")).firstMatch.waitForExistence(timeout: 2))
        snap("06 queued")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(el("tab.badge").waitForExistence(timeout: 2))
        XCTAssertEqual(el("tab.badge").label, "1 queued")
    }

    func testSwipeDeleteThenUndo() {
        launch()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        let count = rows.count
        row(containing: "classic negative").swipeLeft()
        app.buttons["delete"].tap()
        XCTAssertEqual(rows.count, count - 1)
        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        snap("07 deleted")
        undo.tap()
        XCTAssertTrue(row(containing: "classic negative").waitForExistence(timeout: 2))
        XCTAssertEqual(rows.count, count)
    }

    func testLogSettings() {
        launch()
        tab("log")
        let haptics = el("setting.haptics")
        XCTAssertTrue(haptics.waitForExistence(timeout: 2))
        let before = haptics.value as? String
        haptics.tap()
        XCTAssertNotEqual(haptics.value as? String, before)
        haptics.tap()
        app.buttons["15 min"].tap()
        XCTAssertTrue(app.buttons["15 min"].isSelected)
        snap("08 log")
    }
}
