import XCTest

final class RunnerExportUITests: XCTestCase {
  @MainActor
  func testRegisteredFlutterChannelPresentsAndCancelsExport() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "cn.higheq.highEq")
    app.launch()

    let share = app.buttons["Share synthetic ZIP"]
    XCTAssertTrue(share.waitForExistence(timeout: 30), app.debugDescription)
    share.tap()

    let sheet = app.otherElements["ActivityListView"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 20), app.debugDescription)

    // Dart requires the receipt to stay pending while the real sheet is open.
    let disappearedEarly = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == NO"), object: sheet
    )
    disappearedEarly.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [disappearedEarly], timeout: 4), .completed,
                   "The system share list disappeared before cancellation")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "T35 Runner iOS share sheet"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
    XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5), app.debugDescription)
    let appFrame = app.frame
    let regionFrame = dismissRegion.frame.intersection(appFrame)
    let sheetFrame = sheet.frame
    let outsideBottom = min(regionFrame.maxY, sheetFrame.minY)
    XCTAssertTrue(!regionFrame.isEmpty && !sheetFrame.isEmpty && outsideBottom > regionFrame.minY,
                  "No tappable area above the system share list: \(regionFrame), \(sheetFrame)")
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
      dx: regionFrame.midX - appFrame.minX,
      dy: (regionFrame.minY + outsideBottom) / 2 - appFrame.minY
    )).tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), app.debugDescription)

    let expected = "dispatched=1 | presented=1 | held=ZIP+owner | cancelled=1 | cleanup=ZIP+owner+part absent"
    let status = app.descendants(matching: .any)["t35-runner-export-status"].firstMatch
    let finalStatus = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == YES AND label == %@", expected), object: status
    )
    XCTAssertEqual(XCTWaiter.wait(for: [finalStatus], timeout: 15), .completed,
                   "Observed \(status.exists ? status.label : "no Dart status"). \(app.debugDescription)")

    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == NO OR label != %@", expected), object: status
    )
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 2), .completed,
                   "The Dart status changed after cancellation")

    let evidence = XCTAttachment(string: "ActivityListView observed and dismissed\n\(status.label)")
    evidence.name = "T35 Runner Flutter channel cancellation"
    evidence.lifetime = .keepAlways
    add(evidence)
  }
}
