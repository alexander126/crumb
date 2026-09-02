import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbCoreTests {
    @Test
    func defaultsArePrivateAndOnDemand() {
        let privacy = CrumbPrivacyOptions()
        let capture = CrumbCaptureOptions()
        let diagnostics = CrumbDiagnosticsOptions()
        let upload = CrumbUploadOptions()

        #expect(privacy.maskAllTextInputs)
        #expect(privacy.maskScreenshotsBeforeUpload)
        #expect(capture.screenshot)
        #expect(capture.maximumScreenshotDimension == 2_048)
        #expect(capture.maximumScreenshotBytes == 5_242_880)
        #expect(diagnostics.healthCheckURL == nil)
        #expect(diagnostics.timeout == 2)
        #expect(diagnostics.logs.enabled)
        #expect(diagnostics.logs.lookback == 60)
        #expect(diagnostics.logs.maximumEntries == 200)
        #expect(diagnostics.logs.maximumBytes == 65_536)
        #expect(diagnostics.logs.provider == nil)
        #expect(upload.ingestionURL == nil)
    }

    @Test
    func rejectsOversizedOrHeaderUnsafeConfigurationMetadata() {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }

        #expect(throws: CrumbStartError.invalidProjectKey) {
            try Crumb.start(makeConfiguration(projectKey: String(repeating: "k", count: 513)))
        }
        #expect(throws: CrumbStartError.invalidProjectKey) {
            try Crumb.start(makeConfiguration(projectKey: "key\r\nInjected: value"))
        }
        #expect(throws: CrumbStartError.invalidEnvironment) {
            try Crumb.start(makeConfiguration(environment: String(repeating: "e", count: 65)))
        }
        #expect(throws: CrumbStartError.invalidRelease) {
            try Crumb.start(makeConfiguration(
                release: CrumbRelease(appVersion: String(repeating: "v", count: 65), nativeBuild: "1")
            ))
        }
        #expect(throws: CrumbStartError.invalidRelease) {
            try Crumb.start(makeConfiguration(
                release: CrumbRelease(
                    appVersion: "1.0",
                    nativeBuild: "1",
                    bundleVersion: String(repeating: "j", count: 129)
                )
            ))
        }
    }

    @Test
    func rejectsInvalidScreenshotLimits() {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }

        #expect(throws: CrumbStartError.invalidScreenshotDimension) {
            try Crumb.start(makeConfiguration(
                capture: CrumbCaptureOptions(maximumScreenshotDimension: 319)
            ))
        }
        #expect(throws: CrumbStartError.invalidScreenshotByteLimit) {
            try Crumb.start(makeConfiguration(
                capture: CrumbCaptureOptions(maximumScreenshotBytes: 65_535)
            ))
        }
    }

    @Test
    func rejectsInvalidDiagnosticsTimeout() {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let configuration = makeConfiguration(
            diagnostics: CrumbDiagnosticsOptions(timeout: 0.1)
        )

        #expect(throws: CrumbStartError.invalidDiagnosticsTimeout) {
            try Crumb.start(configuration)
        }
    }

    @Test
    func rejectsInvalidHealthCheckURLs() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let unsupported = try #require(URL(string: "ftp://ingestion.crumb.dev/health"))
        let queried = try #require(URL(string: "https://ingestion.crumb.dev/health?token=value"))

        #expect(throws: CrumbStartError.invalidHealthCheckURL) {
            try Crumb.start(makeConfiguration(
                diagnostics: CrumbDiagnosticsOptions(healthCheckURL: unsupported)
            ))
        }
        #expect(throws: CrumbStartError.invalidHealthCheckURL) {
            try Crumb.start(makeConfiguration(
                diagnostics: CrumbDiagnosticsOptions(healthCheckURL: queried)
            ))
        }
    }

    @Test
    func acceptsRepeatedEquivalentStart() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let configuration = makeConfiguration()

        try Crumb.start(configuration)
        try Crumb.start(configuration)
    }

    @Test
    func workspacePolicyCacheKeyIncludesPolicyScope() throws {
        let policyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v1/policy"))
        let otherPolicyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v2/policy"))

        func cacheKey(environment: String, url: URL) throws -> String {
            Crumb.resetForTesting()
            try Crumb.start(makeConfiguration(
                environment: environment,
                workspacePolicy: CrumbWorkspacePolicyOptions(url: url)
            ))
            return try Crumb.workspacePolicyCacheKey()
        }

        let first = try cacheKey(environment: "test", url: policyURL)
        let otherEnvironment = try cacheKey(environment: "production", url: policyURL)
        let otherEndpoint = try cacheKey(environment: "test", url: otherPolicyURL)
        Crumb.resetForTesting()

        #expect(first != otherEnvironment)
        #expect(first != otherEndpoint)
        #expect(otherEnvironment != otherEndpoint)
    }

    @Test
    func rejectsInvalidLogLimits() {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let configuration = makeConfiguration(
            diagnostics: CrumbDiagnosticsOptions(
                logs: CrumbLogOptions(maximumEntries: 0)
            )
        )

        #expect(throws: CrumbStartError.invalidLogLimits) {
            try Crumb.start(configuration)
        }
    }

    @Test
    func validatesAndIsolatesUploadConfiguration() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let ingestionURL = try #require(URL(string: "https://ingestion.crumb.dev"))
        try Crumb.start(makeConfiguration(upload: CrumbUploadOptions(ingestionURL: ingestionURL)))

        let settings = try #require(try Crumb.uploadSettings())
        #expect(settings.projectKey == "project_write_key")
        #expect(settings.ingestionURL == ingestionURL)

        Crumb.resetForTesting()
        let invalidURL = try #require(URL(string: "ftp://ingestion.crumb.dev"))
        #expect(throws: CrumbStartError.invalidIngestionURL) {
            try Crumb.start(makeConfiguration(upload: CrumbUploadOptions(ingestionURL: invalidURL)))
        }
    }

    @Test
    func sanitizesSensitiveLogValues() {
        let raw = "email=user@example.com Authorization: Bearer abc.def token=hunter2 "
            + "https://admin:password@example.com?a=1&b=2\nforged-line"
        let sanitized = CrumbLogSanitizer.sanitize(raw)

        #expect(!sanitized.contains("user@example.com"))
        #expect(!sanitized.contains("abc.def"))
        #expect(!sanitized.contains("hunter2"))
        #expect(!sanitized.contains("a=1"))
        #expect(!sanitized.contains("admin:password"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.contains("[REDACTED_EMAIL]"))
    }

    @Test
    func exposesOnlyReportTimeSettingsToTheUI() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let url = try #require(URL(string: "https://health.crumb.dev/ping"))
        let configuration = makeConfiguration(
            invocation: [.programmatic],
            capture: CrumbCaptureOptions(screenshot: false),
            diagnostics: CrumbDiagnosticsOptions(healthCheckURL: url, timeout: 1.25),
            privacy: CrumbPrivacyOptions(maskAllTextInputs: false)
        )

        try Crumb.start(configuration)
        let settings = try Crumb.reportSettings()

        #expect(!settings.capture.screenshot)
        #expect(settings.diagnostics.healthCheckURL == url)
        #expect(settings.diagnostics.timeout == 1.25)
        #expect(!settings.privacy.maskAllTextInputs)
        #expect(settings.invocation == [.programmatic])
    }

    @Test
    func configuredWorkspacePolicyFailsClosedUntilValidPolicyIsAvailable() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let policyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v1/policy"))
        let healthURL = try #require(URL(string: "https://api.example.invalid/health"))
        let configuration = makeConfiguration(
            diagnostics: CrumbDiagnosticsOptions(healthCheckURL: healthURL),
            reporter: CrumbReporterOptions(visibleFields: [.category, .description]),
            evidence: Set(CrumbEvidenceCategory.allCases),
            customContext: CrumbCustomContextOptions(
                values: ["account_tier": "trial", "email": "user@example.invalid"],
                allowedKeys: ["account_tier", "email"]
            ),
            workspacePolicy: CrumbWorkspacePolicyOptions(url: policyURL)
        )

        try Crumb.start(configuration)
        let beforeFetch = try Crumb.reportSettings()
        #expect(beforeFetch.evidence.isEmpty)
        #expect(beforeFetch.reporter.visibleFields == [.description])
        #expect(beforeFetch.customContext.isEmpty)
        #expect(beforeFetch.policyStatus == .notFetched)

        let policy = CrumbWorkspacePolicy(
            version: 7,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            disabledEvidence: [.network],
            hiddenReporterFields: [.category],
            allowedContextKeys: ["account_tier"]
        )
        Crumb.applyWorkspacePolicy(policy, source: .fresh)
        let afterFetch = try Crumb.reportSettings()
        #expect(afterFetch.evidence == Set(CrumbEvidenceCategory.allCases).subtracting([.network]))
        #expect(afterFetch.reporter.visibleFields == [.description])
        #expect(afterFetch.customContext == ["account_tier": "trial"])
        #expect(afterFetch.policyStatus == .fresh)
        #expect(afterFetch.workspacePolicyVersion == 7)
    }

    @Test
    func logCollectionFollowsEffectiveWorkspacePolicy() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let policyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v1/policy"))
        try Crumb.start(makeConfiguration(
            evidence: [.logs],
            workspacePolicy: CrumbWorkspacePolicyOptions(url: policyURL)
        ))

        #expect(!Crumb.canCollectLogs())
        Crumb.applyWorkspacePolicy(
            CrumbWorkspacePolicy(
                version: 1,
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            ),
            source: .fresh
        )
        #expect(Crumb.canCollectLogs())
    }

    @Test
    func malformedAndExpiredWorkspacePoliciesDoNotBecomeEffective() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = Data(#"{"schema_version":"1.0","version":7,"expires_at":"2030-01-01T00:00:00Z","disabled_evidence":["network"],"hidden_reporter_fields":["category"],"allowed_context_keys":["account_tier"]}"#.utf8)
        let decoded = try CrumbWorkspacePolicy.decode(valid, now: now)
        #expect(decoded.version == 7)
        #expect(decoded.disabledEvidence == [.network])
        #expect(decoded.hiddenReporterFields == [.category])
        #expect(decoded.allowedContextKeys == ["account_tier"])
        #expect(throws: CrumbWorkspacePolicyError.invalid) {
            try CrumbWorkspacePolicy.decode(Data(#"{"schema_version":"1.0"}"#.utf8), now: now)
        }
        let expired = Data(#"{"schema_version":"1.0","version":1,"expires_at":"2030-01-01T00:00:00Z","disabled_evidence":[],"hidden_reporter_fields":[],"allowed_context_keys":[]}"#.utf8)
        #expect(CrumbPolicyCache.load(data: expired, now: Date(timeIntervalSince1970: 4_000_000_000)) == nil)
    }

    @Test
    func workspacePolicyCannotEnableLocallyDisabledEvidence() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let policyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v1/policy"))
        try Crumb.start(makeConfiguration(
            evidence: [.logs],
            workspacePolicy: CrumbWorkspacePolicyOptions(url: policyURL)
        ))
        Crumb.applyWorkspacePolicy(
            CrumbWorkspacePolicy(
                version: 1,
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
            ),
            source: .fresh
        )
        #expect(try Crumb.reportSettings().evidence == [.logs])
    }

    @Test
    func customContextFollowsItsEvidenceCategory() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let policyURL = try #require(URL(string: "https://policy.example.invalid/sdk/v1/policy"))
        try Crumb.start(makeConfiguration(
            evidence: [.customContext],
            customContext: CrumbCustomContextOptions(
                values: ["account_tier": "trial"],
                allowedKeys: ["account_tier"]
            ),
            workspacePolicy: CrumbWorkspacePolicyOptions(url: policyURL)
        ))
        Crumb.applyWorkspacePolicy(
            CrumbWorkspacePolicy(
                version: 1,
                expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                disabledEvidence: [.customContext],
                allowedContextKeys: ["account_tier"]
            ),
            source: .fresh
        )

        let settings = try Crumb.reportSettings()
        #expect(settings.evidence.isEmpty)
        #expect(settings.customContext.isEmpty)
    }

    @Test
    func sanitizesCustomContextValuesBeforePersistence() {
        let sanitized = CrumbCustomContextSanitizer.sanitize(
            CrumbCustomContextOptions(
                values: ["account_tier": "Authorization: Bearer secret email=user@example.com\nnext"],
                allowedKeys: ["account_tier"]
            )
        )

        #expect(!sanitized["account_tier", default: ""].contains("secret"))
        #expect(!sanitized["account_tier", default: ""].contains("user@example.com"))
        #expect(!sanitized["account_tier", default: ""].contains("\n"))
    }

    @Test
    func buildsContractReadyReportEnvelope() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let healthURL = try #require(URL(string: "https://health.example.invalid/ping"))
        try Crumb.start(makeConfiguration(
            diagnostics: CrumbDiagnosticsOptions(healthCheckURL: healthURL)
        ))
        let input = makeReportInput()

        let envelope = try Crumb.buildReport(input)
        let root = try #require(
            JSONSerialization.jsonObject(with: envelope.data) as? [String: Any]
        )
        let release = try #require(root["release"] as? [String: Any])
        let sdk = try #require(root["sdk"] as? [String: Any])
        let diagnostics = try #require(root["diagnostics"] as? [String: Any])
        let network = try #require(diagnostics["network"] as? [String: Any])
        let logs = try #require(diagnostics["logs"] as? [String: Any])
        let stacks = try #require(diagnostics["stack_traces"] as? [String: Any])
        let privacy = try #require(root["privacy"] as? [String: Any])
        let artifacts = try #require(root["artifacts"] as? [[String: Any]])

        #expect(envelope.reportID == "rpt_0123456789ABCDEF0123456789ABCDEF")
        #expect(root["schema_version"] as? String == "1.0")
        #expect(root["report_id"] as? String == envelope.reportID)
        #expect(root["trigger"] as? String == "shake")
        #expect(release["platform"] as? String == "ios")
        #expect(release["app_version"] as? String == "1.0.0")
        #expect(release["environment"] as? String == "test")
        #expect(sdk["name"] as? String == "crumb-ios")
        #expect(sdk["version"] as? String == CrumbSDKVersion.current)
        #expect(network["cellular_generation"] as? String == "4g_lte")
        #expect((network["health_check"] as? [String: Any])?["latency_ms"] as? Int == 42)
        #expect((logs["entries"] as? [[String: Any]])?.count == 1)
        #expect((stacks["threads"] as? [[String: Any]])?.count == 1)
        #expect(privacy["diagnostics_capture"] as? String == "on_demand")
        #expect(privacy["log_capture"] as? String == "enabled")
        #expect(artifacts.first?["upload_id"] as? String == "upl_0123456789AB")
        #expect(root["reportID"] == nil)
    }

    @Test
    func preservesDeviceConnectivityWhenTheCrumbAPIIsUnavailable() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let healthURL = try #require(URL(string: "https://health.example.invalid/ping"))
        try Crumb.start(makeConfiguration(
            diagnostics: CrumbDiagnosticsOptions(healthCheckURL: healthURL)
        ))

        let envelope = try Crumb.buildReport(makeReportInput(healthCheckSucceeded: false))
        let root = try #require(
            JSONSerialization.jsonObject(with: envelope.data) as? [String: Any]
        )
        let diagnostics = try #require(root["diagnostics"] as? [String: Any])
        let network = try #require(diagnostics["network"] as? [String: Any])
        let health = try #require(network["health_check"] as? [String: Any])

        #expect(network["status"] as? String == "reachable")
        #expect(health["succeeded"] as? Bool == false)
        #expect(health["status_code"] == nil)
        #expect(health["failure"] as? String == "timeout")
    }

    @Test
    func rejectsReportWithReversedTimestamps() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        try Crumb.start(makeConfiguration())
        let input = makeReportInput(
            triggeredAt: Date(timeIntervalSince1970: 1_700_000_002),
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(throws: CrumbReportEnvelopeError.invalidTimestampOrder) {
            try Crumb.buildReport(input)
        }
    }

    @Test
    func rejectsReportWithInvalidArtifactManifest() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        try Crumb.start(makeConfiguration())

        #expect(throws: CrumbReportEnvelopeError.invalidArtifact) {
            try Crumb.buildReport(makeReportInput(artifactKind: "video"))
        }
    }

    private func makeReportInput(
        triggeredAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        submittedAt: Date = Date(timeIntervalSince1970: 1_700_000_002),
        artifactKind: String = "screenshot",
        healthCheckSucceeded: Bool = true
    ) -> CrumbReportBuildInput {
        let reportID = CrumbReportEnvelopeBuilder.makeReportID(
            uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        )
        return CrumbReportBuildInput(
            reportID: reportID,
            trigger: .shake,
            triggeredAt: triggeredAt,
            submittedAt: submittedAt,
            runtime: CrumbReportRuntime(
                osVersion: "18.0",
                deviceFamily: "iPhone",
                locale: "en-US",
                timezone: "Europe/Athens"
            ),
            category: "Bug",
            description: "Checkout froze after tapping Pay",
            diagnostics: makeDiagnostics(
                at: triggeredAt.addingTimeInterval(1),
                healthCheckSucceeded: healthCheckSucceeded
            ),
            screenshotCapture: .enabled,
            screenshotMasking: .applied,
            artifacts: [
                CrumbArtifactManifest(
                    id: "art_0123456789AB",
                    kind: artifactKind,
                    mimeType: "image/png",
                    byteSize: 128,
                    sha256: String(repeating: "a", count: 64),
                    redactionState: "masked",
                    uploadID: "upl_0123456789AB"
                )
            ]
        )
    }

    private func makeDiagnostics(
        at capturedAt: Date,
        healthCheckSucceeded: Bool
    ) -> CrumbDiagnosticsSnapshot {
        CrumbDiagnosticsSnapshot(
            capturedAt: capturedAt,
            location: "CheckoutViewController",
            processName: "CrumbDemo",
            processID: 42,
            cpuUsagePercent: 17.5,
            residentMemoryBytes: 50_000_000,
            physicalFootprintBytes: 70_000_000,
            thermalState: "nominal",
            threadCount: 4,
            busiestThreads: [
                CrumbThreadDiagnostic(id: 7, name: "main", state: "running", cpuUsagePercent: 12.5)
            ],
            gpuStatus: "unavailable_on_demand",
            network: CrumbNetworkDiagnostic(
                status: "reachable",
                transport: "cellular",
                cellularGeneration: "4G/LTE",
                isExpensive: true,
                isConstrained: false,
                healthCheck: CrumbHealthCheckDiagnostic(
                    host: "api.crumb.dev",
                    succeeded: healthCheckSucceeded,
                    statusCode: healthCheckSucceeded ? 204 : nil,
                    latencyMilliseconds: healthCheckSucceeded ? 42 : 1_250,
                    failure: healthCheckSucceeded ? nil : "timeout"
                )
            ),
            logs: CrumbLogDiagnostic(
                status: .captured,
                sources: ["application"],
                entries: [
                    CrumbLogEntry(
                        timestamp: capturedAt,
                        level: .error,
                        category: "checkout",
                        message: "Payment request timed out"
                    )
                ],
                truncated: false,
                droppedEntryCount: 0,
                failures: []
            ),
            stackTraces: CrumbStackTraceDiagnostic(
                status: .captured,
                scope: "managed_threads",
                threads: [
                    CrumbThreadStackDiagnostic(
                        id: 7,
                        name: "main",
                        state: "running",
                        frames: ["CheckoutViewController.pay()"]
                    )
                ],
                truncated: false,
                unavailableReason: nil
            )
        )
    }

    private func makeConfiguration(
        projectKey: String = "project_write_key",
        environment: String = "test",
        release: CrumbRelease = CrumbRelease(appVersion: "1.0.0", nativeBuild: "1"),
        invocation: Set<CrumbInvocation> = [.shake, .programmatic],
        capture: CrumbCaptureOptions = .init(),
        diagnostics: CrumbDiagnosticsOptions = .init(),
        privacy: CrumbPrivacyOptions = .init(),
        upload: CrumbUploadOptions = .init(),
        reporter: CrumbReporterOptions = .init(),
        evidence: Set<CrumbEvidenceCategory> = Set(CrumbEvidenceCategory.allCases),
        application: CrumbApplicationMetadata = .init(),
        customContext: CrumbCustomContextOptions = .init(),
        workspacePolicy: CrumbWorkspacePolicyOptions = .init()
    ) -> CrumbConfiguration {
        CrumbConfiguration(
            projectKey: projectKey,
            environment: environment,
            release: release,
            invocation: invocation,
            capture: capture,
            diagnostics: diagnostics,
            privacy: privacy,
            upload: upload,
            reporter: reporter,
            evidence: evidence,
            application: application,
            customContext: customContext,
            workspacePolicy: workspacePolicy
        )
    }
}
