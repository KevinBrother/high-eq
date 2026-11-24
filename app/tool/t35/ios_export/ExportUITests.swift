import XCTest

final class ExportUITests: XCTestCase {
  @MainActor
  func testTemporaryZIPShowsSystemSheetAndCancels() {
    assertCancellation(button: "share-tmp")
  }

  @MainActor
  func testCachesZIPShowsSystemSheetAndCancels() {
    assertCancellation(button: "share-caches")
  }

  @MainActor
  func testOutsideNestedAndSymlinkPathsAreRejected() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let rejection = app.buttons["check-rejections"]
    XCTAssertTrue(rejection.wait(for: \.isHittable, toEqual: true, timeout: 10),
                  "FAIL(rejection.start)")
    rejection.tap()
    assertStatus(
      "outside=io_error | nested=io_error | file-link=io_error | directory-link=io_error"
        + " | attempts=0 | visible=0 | presentation=0 | files=unchanged",
      in: app, stage: "rejection"
    )
  }

  @MainActor
  private func assertCancellation(button: String) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let share = app.buttons[button]
    XCTAssertTrue(share.wait(for: \.isHittable, toEqual: true, timeout: 10),
                  "FAIL(cancel.start)")
    share.tap()

    let sheet = app.otherElements["ActivityListView"].firstMatch
    guard sheet.waitForExistence(timeout: 15) else {
      XCTFail("FAIL(cancel.sheet) The system share list did not appear.")
      return
    }
    let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
    guard dismissRegion.waitForExistence(timeout: 5) else {
      XCTFail("FAIL(cancel.dismiss) The outside dismissal region did not appear.")
      return
    }

    // UIKit exposes the dismissal region over the whole window on iOS 26.5.
    // Tap the part above the activity list so the touch lands outside the sheet.
    let appFrame = app.frame
    let regionFrame = dismissRegion.frame.intersection(appFrame)
    let sheetFrame = sheet.frame
    let outsideBottom = min(regionFrame.maxY, sheetFrame.minY)
    guard !regionFrame.isEmpty, !sheetFrame.isEmpty, outsideBottom > regionFrame.minY else {
      XCTFail("FAIL(cancel.dismiss) No tappable area above the system share list.")
      return
    }
    let tapOffset = CGVector(
      dx: regionFrame.midX - appFrame.minX,
      dy: (regionFrame.minY + outsideBottom) / 2 - appFrame.minY
    )
    app.coordinate(withNormalizedOffset: .zero).withOffset(tapOffset).tap()

    guard sheet.waitForNonExistence(timeout: 10) else {
      XCTFail("FAIL(cancel.dismiss) The system share sheet remained visible.")
      return
    }
    assertStatus(
      "URL=file ZIP | receipt=cancelled | attempts=1 | visible=1"
        + " | presentation=shown | files=unchanged", in: app, stage: "cancel"
    )
  }

  @MainActor
  private func assertStatus(_ expected: String, in app: XCUIApplication, stage: String) {
    let status = app.staticTexts["probe-result"]
    let receipt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: status)
    guard XCTWaiter.wait(for: [receipt], timeout: 15) == .completed else {
      XCTFail("FAIL(\(stage).receipt) Expected \(expected). Observed \(status.exists ? status.label : "no status")")
      return
    }

    // A late or duplicate callback can change the report after completion.
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", expected), object: status
    )
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 2), .completed,
                   "FAIL(\(stage).observation) Observed \(status.exists ? status.label : "no status")")
  }
}

final class ExportLocalFilesUITests: XCTestCase {
  private let saveToFilesLabels = ["Save to Files", "保存到“文件”"]
  private let localLocationLabels = ["On My iPhone", "在我的 iPhone 上", "我的 iPhone"]
  private let browseLabels = ["Browse", "浏览"]
  private let saveLabels = ["Save", "存储", "保存"]
  private let openFileLabels = ["Open", "打开"]

  @MainActor
  func testSaveToOnMyiPhoneSurvivesSourceCleanup() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["T35_LOCAL_FILES_ID"] = UUID().uuidString
    app.launch()

    let filename = app.staticTexts["local-files-filename"]
    XCTAssertTrue(filename.waitForExistence(timeout: 10), "FAIL(files.source-name) No staged filename.")
    let archiveName = filename.label
    XCTAssertNotNil(archiveName.range(of: #"^high-eq-export-[0-9]+\.zip$"#, options: .regularExpression),
                    "FAIL(files.source-name) Unexpected fixture name.")
    tap(app.buttons.matching(identifier: "local-files-share"), stage: "files.share")

    let sheet = app.otherElements["ActivityListView"].firstMatch
    guard sheet.waitForExistence(timeout: 15) else {
      let status = app.staticTexts["probe-result"]
      XCTFail("FAIL(files.share-sheet) Observed \(status.exists ? status.label : "no status").")
      return
    }
    tapSaveToFiles(in: sheet)
    openLocalFilesRoot(in: app, stage: "files.save-location", archiveName: archiveName)
    tap(labeled(saveLabels, in: app.navigationBars.buttons), stage: "files.save-confirm")

    let saved = "receipt=completed | source=verified then removed"
    waitForStatus(saved, in: app, stage: "files.save-receipt")
    let duplicateReceipt = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label != %@", saved), object: app.staticTexts["probe-result"]
    )
    duplicateReceipt.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [duplicateReceipt], timeout: 2), .completed,
                   "FAIL(files.save-observation) The save receipt changed after completion.")

    app.terminate()
    app.launchEnvironment["T35_LOCAL_FILES_READBACK"] = "1"
    app.launch()
    waitForStatus("source=absent", in: app, stage: "files.restart")
    tap(app.buttons.matching(identifier: "local-files-read"), stage: "files.read-picker")
    let location = openLocalFilesRoot(
      in: app, stage: "files.read-location", archiveName: archiveName
    )

    // Files can hide the extension in the row title. The picker delegate
    // still requires the full, exact filename on the returned URL.
    let basename = String(archiveName.dropLast(".zip".count))
    guard tapFixtureRow(in: app, labels: [archiveName, basename], archiveName: archiveName) else {
      return
    }
    let digest = "3779ff054d5dafa662957e83d6dfc1ae54f01fee5b8d6a1e2cdd9089341afe2a"
    let readback = "source=absent | destination=external | bytes=141 | sha256=\(digest)"
    guard confirmOpenIfNeeded(in: app, archiveName: archiveName, expected: readback) else { return }
    waitForReadbackStatus(readback, in: app, archiveName: archiveName)

    let evidence = XCTAttachment(string: "\(archiveName)\n\(saved)\n\(location)\n\(readback)")
    evidence.name = "T35 local Files readback"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  @MainActor
  private func tapSaveToFiles(in sheet: XCUIElement) {
    let actionCells = sheet.cells.matching(identifier: "actionGroupCell")
    let namedCell = labeled(saveToFilesLabels, in: actionCells)
    let titledCell = actionCells.containing(NSPredicate(
      format: "identifier == %@ AND label IN %@", "cellTitleLabel", saveToFilesLabels
    ))
    let namedTitle = labeled(saveToFilesLabels, in: sheet.staticTexts.matching(identifier: "cellTitleLabel"))
    let fallback = fileRows(saveToFilesLabels, in: sheet)
    for scrolls in 0...4 {
      if let action = hittable(namedCell) ?? hittable(namedTitle) ?? hittable(titledCell) ?? hittable(fallback) {
        action.tap()
        return
      }
      if scrolls < 4 { sheet.swipeUp() }
    }
    XCTFail("FAIL(files.save-action) The system Save to Files action was not tappable.")
  }

  @discardableResult
  @MainActor
  private func openLocalFilesRoot(
    in app: XCUIApplication, stage: String, archiveName: String
  ) -> String {
    let title = labeled(localLocationLabels, in: app.navigationBars.children(matching: .staticText)).firstMatch
    let bar = app.navigationBars.matching(
      NSPredicate(format: "identifier IN %@ OR label IN %@", localLocationLabels, localLocationLabels)
    ).firstMatch
    func rootTitle() -> String? {
      if bar.exists { return localLocationLabels.contains(bar.label) ? bar.label : bar.identifier }
      if title.exists { return title.label }
      return nil
    }

    let locations = fileRows(localLocationLabels, in: app)
    let back = labeled(browseLabels + ["Locations", "位置"] + localLocationLabels,
                       in: app.navigationBars.buttons)
    let browseTab = labeled(browseLabels, in: app.tabBars.buttons)
    for _ in 0..<4 {
      var root: String?
      var location: XCUIElement?
      var navigation: XCUIElement?
      let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        root = rootTitle()
        if root != nil { return true }
        location = self.hittable(locations)
        if location != nil { return true }
        navigation = self.hittable(back) ?? self.hittable(browseTab)
        return navigation != nil
      }, object: nil)
      guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed else { break }
      if let root { return root }
      if let location {
        location.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
          root = rootTitle()
          return root != nil
        }, object: nil)
        if XCTWaiter.wait(for: [opened], timeout: 10) == .completed, let root { return root }
        break
      }
      navigation?.tap()
    }
    failReadback(stage, in: app, archiveName: archiveName,
                 reason: "The picker did not reach the On My iPhone root")
    return ""
  }

  @MainActor
  private func labeled(_ labels: [String], in query: XCUIElementQuery) -> XCUIElementQuery {
    query.matching(NSPredicate(format: "label IN %@", labels))
  }

  @MainActor
  private func fileRows(_ labels: [String], in container: XCUIElement) -> XCUIElementQuery {
    let predicate = NSPredicate(
      format: "label IN %@ AND elementType IN %@",
      labels,
      [XCUIElement.ElementType.button, .cell, .staticText, .other].map { NSNumber(value: $0.rawValue) }
    )
    return container.descendants(matching: .any).matching(predicate)
  }

  @MainActor
  private func tapFixtureRow(
    in app: XCUIApplication, labels: [String], archiveName: String
  ) -> Bool {
    let predicate = NSPredicate(format: "label IN %@", labels)
    let cells = app.cells.containing(predicate)
    if let cell = waitForHittable(cells) {
      cell.tap()
      return true
    }
    if let row = waitForHittable(fileRows(labels, in: app)) {
      row.tap()
      return true
    }
    failReadback("files.read-selection", in: app, archiveName: archiveName,
                 reason: "The exact synthetic archive row was not tappable")
    return false
  }

  @MainActor
  private func confirmOpenIfNeeded(
    in app: XCUIApplication, archiveName: String, expected: String
  ) -> Bool {
    let status = app.staticTexts["probe-result"]
    let open = labeled(openFileLabels, in: app.buttons)
    var openButton: XCUIElement?
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      if status.exists && (status.label == expected || status.label.hasPrefix("FAIL(")) {
        return true
      }
      openButton = self.hittable(open)
      return openButton != nil
    }, object: nil)
    guard XCTWaiter.wait(for: [settled], timeout: 5) == .completed else {
      failReadback("files.read-confirm", in: app, archiveName: archiveName,
                   reason: "no callback or Open control")
      return false
    }
    if status.exists && status.label == expected { return true }
    if status.exists && status.label.hasPrefix("FAIL(") {
      failReadback("files.read-confirm", in: app, archiveName: archiveName,
                   reason: "probe rejected the returned document")
      return false
    }
    guard let openButton else {
      failReadback("files.read-confirm", in: app, archiveName: archiveName,
                   reason: "Open control was not tappable")
      return false
    }
    openButton.tap()
    return true
  }

  @MainActor
  private func waitForReadbackStatus(_ expected: String, in app: XCUIApplication, archiveName: String) {
    let status = app.staticTexts["probe-result"]
    let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: status)
    guard XCTWaiter.wait(for: [match], timeout: 15) == .completed else {
      failReadback("files.read-evidence", in: app, archiveName: archiveName,
                   reason: "exact external byte and SHA evidence did not arrive")
      return
    }
  }

  @MainActor
  private func waitForHittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
    var target: XCUIElement?
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      target = self.hittable(query)
      return target != nil
    }, object: nil)
    guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else { return nil }
    return target
  }

  @MainActor
  private func failReadback(_ stage: String, in app: XCUIApplication, archiveName: String, reason: String) {
    let diagnostics = readbackDiagnostics(in: app, archiveName: archiveName)
    let attachment = XCTAttachment(string: diagnostics)
    attachment.name = "T35 local Files sanitized diagnostics"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTFail("FAIL(\(stage)) \(reason). \(diagnostics)")
  }

  @MainActor
  private func readbackDiagnostics(in app: XCUIApplication, archiveName: String) -> String {
    let status = app.staticTexts["probe-result"]
    let pickerState = (status.value as? String) ?? "picker=unreported"
    let statusClass: String
    if !status.exists {
      statusClass = "missing"
    } else if status.label == "source=absent" {
      statusClass = "source-absent"
    } else if status.label.hasPrefix("FAIL(") {
      statusClass = "fixed-failure"
    } else {
      statusClass = "other-probe-state"
    }

    let basename = String(archiveName.dropLast(".zip".count))
    let labels = [archiveName, basename]
    let fixture = fileRows(labels, in: app).allElementsBoundByIndex
    let fixtureRoles = Set(fixture.map { roleName($0.elementType) }).sorted().joined(separator: ",")
    let selected = fixture.contains { $0.isSelected }
    let openHittable = hittable(labeled(openFileLabels, in: app.buttons)) != nil

    let countedTypes: [(XCUIElement.ElementType, String)] = [
      (.navigationBar, "nav"), (.button, "button"), (.cell, "cell"), (.staticText, "text"),
      (.collectionView, "collection"), (.table, "table"), (.searchField, "search"), (.other, "other"),
    ]
    let roleCounts = countedTypes.map { type, name in
      "\(name)=\(app.descendants(matching: type).count)"
    }.joined(separator: ",")

    return "\(pickerState) | status=\(statusClass) | fixtureVisible=\(fixture.count)"
      + " | fixtureRoles=\(fixtureRoles.isEmpty ? "none" : fixtureRoles)"
      + " | fixtureSelected=\(selected) | openHittable=\(openHittable) | roles=\(roleCounts)"
  }

  private func roleName(_ type: XCUIElement.ElementType) -> String {
    switch type {
    case .cell: return "cell"
    case .button: return "button"
    case .staticText: return "text"
    case .other: return "other"
    default: return "type-\(type.rawValue)"
    }
  }

  @MainActor
  private func hittable(_ query: XCUIElementQuery) -> XCUIElement? {
    query.allElementsBoundByIndex.first { $0.isHittable && ($0.elementType != .button || $0.isEnabled) }
  }

  @MainActor
  private func tap(_ query: XCUIElementQuery, stage: String) {
    var target: XCUIElement?
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      target = self.hittable(query)
      return target != nil
    }, object: nil)
    guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed, let element = target else {
      XCTFail("FAIL(\(stage)) The expected control was not tappable.")
      return
    }
    element.tap()
  }

  @MainActor
  private func waitForStatus(_ expected: String, in app: XCUIApplication, stage: String) {
    let status = app.staticTexts["probe-result"]
    let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 15), .completed,
                   "FAIL(\(stage)) Expected \(expected). Observed \(status.exists ? status.label : "no status")")
  }
}
