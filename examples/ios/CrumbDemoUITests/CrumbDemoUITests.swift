import XCTest

final class CrumbDemoUITests: XCTestCase {
    @MainActor
    func testInteractiveDismissalAllowsAnotherReport() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demo.report-problem"].tap()
        let reporter = app.staticTexts["crumb.reporter-title"]
        XCTAssertTrue(reporter.waitForExistence(timeout: 5))

        app.buttons["Sheet Grabber"].swipeDown()
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
    func testCreatesLocalReportDraft() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demo.simulate-activity"].tap()
        XCTAssertEqual(app.staticTexts["demo.activity-count"].label, "CPU pressure active for 4 seconds")

        app.buttons["demo.report-problem"].tap()
        XCTAssertTrue(app.staticTexts["crumb.reporter-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Masked screenshot preview"].waitForExistence(timeout: 5))
        let diagnostics = app.staticTexts["crumb.diagnostics-summary"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        let diagnosticsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH[c] 'Context ready'"),
            object: diagnostics
        )
        XCTAssertEqual(XCTWaiter().wait(for: [diagnosticsReady], timeout: 10), .completed)
        XCTAssertTrue(diagnostics.label.localizedCaseInsensitiveContains("CPU"))
        attachScreenshot(named: "ios-report", app: app)

        let description = app.textViews["crumb.description"]
        description.tap()
        description.typeText("The payment button stopped responding")
        description.typeText("\n")

        let review = app.buttons["crumb.review-draft"]
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

        let diagnostics = app.staticTexts["crumb.diagnostics-summary"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        let diagnosticsReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH[c] 'Context ready'"),
            object: diagnostics
        )
        XCTAssertEqual(XCTWaiter().wait(for: [diagnosticsReady], timeout: 10), .completed)

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
            let diagnostics = app.staticTexts["crumb.diagnostics-summary"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH[c] 'Context ready'"),
                object: diagnostics
            )
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 3), .completed)

            if run == 19 {
                let description = app.textViews["crumb.description"]
                description.tap()
                description.typeText("Memory retention pass")
                description.typeText("\n")
                let review = app.buttons["crumb.review-draft"]
                let enabled = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: review
                )
                XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 3), .completed)
                if !review.isHittable { app.swipeUp() }
                review.tap()
                XCTAssertTrue(app.staticTexts["crumb.review-title"].waitForExistence(timeout: 3))
            }

            app.buttons["Cancel"].firstMatch.tap()
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
