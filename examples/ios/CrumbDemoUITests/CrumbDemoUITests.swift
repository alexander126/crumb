import XCTest

final class CrumbDemoUITests: XCTestCase {
    @MainActor
    func testInteractiveDismissalAllowsAnotherReport() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demo.report-problem"].tap()
        let reporter = app.staticTexts["crumb.reporter-title"]
        XCTAssertTrue(reporter.waitForExistence(timeout: 5))

        app.buttons["crumb.reporter-grabber"].swipeDown()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: reporter
        )
        XCTAssertEqual(XCTWaiter().wait(for: [dismissed], timeout: 3), .completed)

        app.buttons["demo.report-problem"].tap()
        XCTAssertTrue(reporter.waitForExistence(timeout: 5))
    }

    @MainActor
    func testReportSurvivesRotationAndBackgrounding() {
        let app = XCUIApplication()
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }

        app.buttons["demo.report-problem"].tap()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))

        let description = app.textViews["crumb.description"]
        description.tap()
        description.typeText("Keep this draft")
        description.typeText("\n")

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(description.waitForExistence(timeout: 3))
        XCTAssertTrue((description.value as? String)?.contains("Keep this draft") == true)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))
        XCTAssertTrue((description.value as? String)?.contains("Keep this draft") == true)
    }

    @MainActor
    func testDescriptionKeepsItsGeometryThroughTypingAndRefocus() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["demo.report-problem"].tap()
        let description = app.textViews["crumb.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        description.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // XCTest can report a hardware-keyboard placeholder before showing the
        // software keyboard. Prime it, then restore the empty draft before measuring.
        description.typeText(" ")
        description.typeText(XCUIKeyboardKey.delete.rawValue)
        let editingFrame = settledFrame(of: description)
        let title = app.staticTexts["crumb.reporter-title"]
        let titleY = title.frame.minY
        // XCTest may expose predictive suggestions outside the keyboard element.
        // Measure the whole visible keyboard, including that accessory strip.
        let predictions = app.otherElements["Typing Predictions"].firstMatch
        let keysTop = app.keyboards.firstMatch.frame.minY
        let keyboardTop = predictions.exists ? min(keysTop, predictions.frame.minY) : keysTop
        let statusBottom = app.staticTexts["crumb.keyboard-screenshot-status"].frame.maxY
        XCTAssertGreaterThanOrEqual(keyboardTop - statusBottom, 0)
        XCTAssertLessThanOrEqual(keyboardTop - statusBottom, 60,
                                 "The editing controls must sit directly above the keyboard")
        XCTAssertLessThanOrEqual(editingFrame.maxY, keyboardTop)
        description.typeText("A")
        XCTAssertEqual(description.frame.height, editingFrame.height, accuracy: 1,
                       "The first character must not collapse the input")
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1,
                       "Typing must not move the sheet header")
        description.typeText(" synthetic keyboard regression")
        description.typeText("\n")
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter().wait(for: [keyboardHidden], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["crumb.review-draft"].exists)
        XCTAssertFalse(app.staticTexts["crumb.keyboard-screenshot-status"].exists)
        XCTAssertEqual(description.value as? String, "A synthetic keyboard regression")

        description.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        description.typeText(" ")
        description.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(settledFrame(of: description).height, editingFrame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(description.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertTrue(app.buttons["Review"].firstMatch.isHittable)
        app.buttons["Review"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 5))
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["crumb.review-draft"].exists,
                      "Returning from review must restore the normal form")
        XCTAssertEqual(description.value as? String, "A synthetic keyboard regression")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Discard this report?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep editing"].tap()
        XCTAssertEqual(description.value as? String, "A synthetic keyboard regression")
    }

    @MainActor
    func testLongDescriptionSurvivesRotationWhileEditing() {
        let app = XCUIApplication()
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["demo.report-problem"].tap()
        let description = app.textViews["crumb.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        description.tap()
        description.typeText(" ")
        description.typeText(XCUIKeyboardKey.delete.rawValue)
        let emptyFrame = settledFrame(of: description)
        let emptyTitleY = app.staticTexts["crumb.reporter-title"].frame.minY
        let draft = String(repeating: "Synthetic description with enough words to wrap. ", count: 8)
        description.typeText(draft)
        let populatedFrame = settledFrame(of: description)
        XCTAssertGreaterThan(populatedFrame.height, emptyFrame.height)
        XCTAssertLessThan(app.staticTexts["crumb.reporter-title"].frame.minY, emptyTitleY,
                          "Wrapped text must grow the composer upwards")
        XCTAssertEqual(description.value as? String, draft)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(description.value as? String, draft)
        XCUIDevice.shared.orientation = .portrait
        description.typeText("\n")
        let review = app.buttons["crumb.review-draft"]
        for _ in 0..<5 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor
    func testCreatesLocalReportDraft() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demo.simulate-activity"].tap()
        XCTAssertEqual(app.staticTexts["demo.activity-count"].label, "CPU pressure active for 4 seconds")

        app.buttons["demo.report-problem"].tap()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Masked screenshot preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["crumb.diagnostics-summary"].exists)
        XCTAssertFalse(app.staticTexts["Your own words are the most useful part of the report."].exists)
        XCTAssertFalse(app.staticTexts["Add a description to continue."].exists)
        attachScreenshot(named: "ios-report", app: app)

        let description = app.textViews["crumb.description"]
        description.tap()
        description.typeText("The payment button stopped responding")
        description.typeText("\n")

        let review = app.buttons["crumb.review-draft"]
        waitUntilEnabled(review)
        if !review.isHittable { app.swipeUp() }
        review.tap()

        XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 3))
        app.buttons["crumb.show-technical-detail"].tap()
        let summary = app.textViews["crumb.draft-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue((summary.value as? String)?.contains("LOCAL ONLY — NOT UPLOADED") == true)
        XCTAssertTrue((summary.value as? String)?.contains("ON-DEMAND DIAGNOSTICS") == true)
        XCTAssertTrue((summary.value as? String)?.contains("Network:") == true)
        XCTAssertTrue((summary.value as? String)?.contains("The payment button stopped responding") == true)
        attachScreenshot(named: "ios-draft", app: app)
    }

    @MainActor
    func testShakeShowsCompactConfirmationBeforeReporter() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demo.report-problem"].press(forDuration: 1)

        XCTAssertTrue(app.staticTexts["crumb.shake-prompt-title"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textViews["crumb.description"].exists)

        app.buttons["crumb.shake-report"].tap()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["crumb.description"].exists)
    }

    @MainActor
    func testDarkAppearanceAndLargestTextKeepActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launchEnvironment["CRUMB_TEST_APPEARANCE"] = "dark"
        app.launch()

        app.buttons["demo.report-problem"].tap()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Masked screenshot preview"].waitForExistence(timeout: 5))

        let description = app.textViews["crumb.description"]
        description.tap()
        description.typeText("Accessible report")
        description.typeText("\n")

        let review = app.buttons["crumb.review-draft"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: review
        )
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 3), .completed)
        for _ in 0..<4 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable)
        review.tap()

        XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 3))
        attachScreenshot(named: "ios-dark-largest-text", app: app)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.isHittable)
        app.buttons["Cancel"].firstMatch.tap()
    }

    @MainActor
    func testQualityBudgetsProduceRepeatableMeasurements() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_QUALITY_METRICS"] = "1"
        app.launch()

        let reporter = app.staticTexts["crumb.reporter-title"]
        for run in 0..<20 {
            app.buttons["demo.report-problem"].tap()
            XCTAssertTrue(reporter.waitForExistence(timeout: 3), "Reporter run \(run + 1)")
            XCTAssertTrue(app.buttons["Masked screenshot preview"].waitForExistence(timeout: 3))
            // Readiness is exposed by the review action, without a status card.
            let description = app.textViews["crumb.description"]
            description.tap()
            description.typeText("Synthetic quality report\n")
            let review = app.buttons["crumb.review-draft"]
            waitUntilEnabled(review)

            if run == 19 {
                if !review.isHittable { app.swipeUp() }
                review.tap()
                XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 3))
            }

            app.buttons["Cancel"].firstMatch.tap()
            if run != 19 {
                XCTAssertTrue(app.alerts["Discard this report?"].waitForExistence(timeout: 3))
                app.alerts.buttons["Discard report"].tap()
            }
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: reporter
            )
            XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 3), .completed)
        }

        let results = app.staticTexts["demo.quality-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 3))
        let retainedReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS 'retained_bytes=' AND NOT (label CONTAINS 'retained_bytes=pending')"
            ),
            object: results
        )
        XCTAssertEqual(XCTWaiter().wait(for: [retainedReady], timeout: 8), .completed)
        let metrics = parseMetrics(results.label)
        XCTAssertLessThanOrEqual(tryMetric("start_p95", metrics), 5)
        XCTAssertLessThanOrEqual(tryMetric("form_p95", metrics), 120)
        XCTAssertLessThanOrEqual(tryMetric("screenshot_p95", metrics), 750)
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil {
            XCTAssertLessThanOrEqual(tryMetric("diagnostics_p95", metrics), 500)
            XCTAssertLessThanOrEqual(tryMetric("retained_bytes", metrics), 20 * 1_024 * 1_024)
        }
        print("CrumbT10 \(results.label)")
    }

    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        // A keyboard can exist in the accessibility tree before its presentation
        // animation finishes. Measure editing geometry only once it has settled.
        var frame = element.frame
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let current = element.frame
            if current != frame {
                frame = current
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 0.75 {
                return frame
            }
        }
        XCTFail("Input geometry did not settle")
        return frame
    }

    private func parseMetrics(_ value: String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: value.split(separator: " ").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let number = Double(parts[1]) else { return nil }
            return (String(parts[0]), number)
        })
    }

    private func tryMetric(_ name: String, _ metrics: [String: Double]) -> Double {
        guard let value = metrics[name] else {
            XCTFail("Missing \(name) in quality metrics: \(metrics)")
            return .infinity
        }
        return value
    }

    @MainActor
    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
