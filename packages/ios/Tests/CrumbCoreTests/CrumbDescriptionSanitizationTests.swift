import Foundation
import Testing
@testable import CrumbCore

struct CrumbDescriptionSanitizationTests {
    @Test
    func redactsSerializedAndReopenedQueuedDescriptions() async throws {
        let cases: [(String, String, [String])] = [
            ("Step one\n\npassword=synthetic-secret\nStep two", "Step one\n\npassword=[REDACTED]\nStep two", ["synthetic-secret"]),
            ("password\n=\nsynthetic-multiline\nNext paragraph", "password\n=\n[REDACTED]\nNext paragraph", ["synthetic-multiline"]),
            (#"{"credentials":{"password":"synthetic-json","apiKey":"synthetic-api"},"safe":true}"#,
             #"{"credentials":{"password":"[REDACTED]","apiKey":"[REDACTED]"},"safe":true}"#, ["synthetic-json", "synthetic-api"]),
            ("Authorization: Digest username=synthetic-user, response=synthetic-digest\nNext paragraph",
             "Authorization: [REDACTED]\nNext paragraph", ["synthetic-user", "synthetic-digest"]),
            ("Cookie: session=synthetic-session; second=synthetic-cookie\nNext paragraph",
             "Cookie: [REDACTED]\nNext paragraph", ["synthetic-session", "synthetic-cookie"]),
            ("Bearer synthetic-bearer\n\nNext paragraph", "Bearer [REDACTED]\n\nNext paragraph", ["synthetic-bearer"]),
            ("Open https://synthetic-user:synthetic-pass@example.invalid/path?session=synthetic-query",
             "Open https://[REDACTED]@example.invalid/path?session=[REDACTED]", ["synthetic-user", "synthetic-pass", "synthetic-query"]),
            ("Contact synthetic@example.invalid", "Contact [REDACTED_EMAIL]", ["synthetic@example.invalid"]),
            ("Card 0000 1111 2222 3333", "Card [REDACTED_NUMBER]", ["0000 1111 2222 3333"])
        ]
        for (raw, expected, secrets) in cases {
            let envelope = try build(raw)
            #expect(try description(in: envelope.data) == expected)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("crumb-description-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = String(repeating: "a", count: 64)
            let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
            try await queue.enqueue(envelope: envelope, artifacts: [])
            let persisted = try Data(contentsOf: root.appendingPathComponent(envelope.reportID).appendingPathComponent("envelope.json"))
            let reopened = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
            let payload = try await reopened.load(reportID: envelope.reportID)
            #expect(payload.envelope == persisted)
            #expect(persisted == envelope.data)
            #expect(try description(in: payload.envelope) == expected)
            for secret in secrets {
                #expect(!envelope.json.contains(secret))
                #expect(!String(decoding: persisted, as: UTF8.self).contains(secret))
                #expect(!String(decoding: payload.envelope, as: UTF8.self).contains(secret))
            }
        }
    }

    @Test
    func preservesParagraphsTabsAndExistingMarkersAcrossRepeatedBuilds() throws {
        let raw = "  First café🙂\n\n\tSecond paragraph\nCookie: synthetic-cookie=secret-cookie\n\nThird  "
        let expected = "First café🙂\n\n\tSecond paragraph\nCookie: [REDACTED]\n\nThird"
        let sanitized = try description(in: build(raw).data)
        #expect(sanitized == expected)
        #expect(try description(in: build(sanitized).data) == expected)
        #expect(try description(in: build("token=[REDACTED]\n\nSafe paragraph").data) == "token=[REDACTED]\n\nSafe paragraph")
        #expect(CrumbLogSanitizer.sanitize("one\n\ttwo") == "one  two")
    }

    @Test
    func validatesTheFinalBoundAfterRedactionExpansion() throws {
        let fitting = String(repeating: "a", count: 3_983) + "\nx@y.co"
        let expected = String(repeating: "a", count: 3_983) + "\n[REDACTED_EMAIL]"
        #expect(expected.unicodeScalars.count == 4_000)
        #expect(try description(in: build(fitting).data) == expected)
        for count in [3_984, 3_993] {
            #expect(throws: CrumbReportEnvelopeError.invalidDescription) {
                try build(String(repeating: "a", count: count) + "\nx@y.co")
            }
        }
    }

    @Test
    func keepsRawLimitsAndRejectsEmptySanitizedOutput() throws {
        #expect(try description(in: build(String(repeating: "a", count: 4_000)).data).unicodeScalars.count == 4_000)
        for raw in ["password=" + String(repeating: "s", count: 3_992), String(repeating: "a", count: 4_001), " \n\t", "\u{0}"] {
            #expect(throws: CrumbReportEnvelopeError.invalidDescription) { try build(raw) }
        }
    }

    private func description(in data: Data) throws -> String {
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(envelope["user_input"] as? [String: Any])
        return try #require(input["description"] as? String)
    }

    private func build(_ description: String) throws -> CrumbSerializedReportEnvelope {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = CrumbReportSettings(
            environment: "test", release: CrumbRelease(appVersion: "1", nativeBuild: "1"),
            invocation: [.programmatic], capture: CrumbCaptureOptions(screenshot: false),
            diagnostics: CrumbDiagnosticsOptions(), privacy: CrumbPrivacyOptions(),
            reporter: CrumbReporterOptions(), evidence: [], application: CrumbApplicationMetadata(),
            customContext: [:], policyStatus: .notConfigured, workspacePolicyVersion: nil
        )
        let snapshot = CrumbDiagnosticsSnapshot(
            capturedAt: timestamp, location: "SyntheticScreen", processName: "SyntheticApp", processID: 1,
            cpuUsagePercent: nil, residentMemoryBytes: nil, physicalFootprintBytes: nil,
            thermalState: "unknown", threadCount: 0, busiestThreads: [], gpuStatus: "unavailable",
            network: CrumbNetworkDiagnostic(status: "unknown", transport: "unknown", cellularGeneration: nil, isExpensive: false, isConstrained: false, healthCheck: nil),
            logs: CrumbLogDiagnostic(status: .empty, sources: [], entries: [], truncated: false, droppedEntryCount: 0, failures: []),
            stackTraces: CrumbStackTraceDiagnostic(status: .unavailable, scope: "unavailable", threads: [], truncated: false, unavailableReason: "not_available")
        )
        return try CrumbReportEnvelopeBuilder.build(settings: settings, input: CrumbReportBuildInput(
            reportID: "rpt_0123456789abcdef0123456789abcdef", trigger: .programmatic,
            triggeredAt: timestamp, submittedAt: timestamp, runtime: CrumbReportRuntime(osVersion: "17", deviceFamily: "synthetic", locale: "en", timezone: "UTC"),
            category: "bug", description: description, diagnostics: snapshot,
            screenshotCapture: .disabledByConfiguration, screenshotMasking: .notApplicable
        ))
    }
}
