import CrumbCore
import Foundation
import Testing
@testable import CrumbUI

struct CrumbEvidenceCountsTests {
    /// The defect this fixes: the caption claimed "4 text fields hidden"
    /// whenever masking had been applied, for any real count including zero.
    /// It is a privacy claim shown next to the screenshot the user is about to
    /// send, so a fixed number tells the user something false.
    @Test
    func theMaskingCaptionReportsTheRealCount() {
        #expect(
            CrumbEvidenceCounts.maskingCaption(maskingApplied: true, maskedViewCount: 1)
                == "1 text field hidden"
        )
        #expect(
            CrumbEvidenceCounts.maskingCaption(maskingApplied: true, maskedViewCount: 7)
                == "7 text fields hidden"
        )
    }

    @Test
    func maskingWithNothingToHideClaimsNothingWasHidden() {
        let caption = CrumbEvidenceCounts.maskingCaption(
            maskingApplied: true,
            maskedViewCount: 0
        )

        #expect(caption == "No text fields to hide")
        #expect(caption.contains("hidden") == false)
    }

    @Test
    func maskingOffKeepsItsExistingCaption() {
        #expect(
            CrumbEvidenceCounts.maskingCaption(maskingApplied: false, maskedViewCount: 4)
                == "Text-field masking is off"
        )
    }

    @Test
    func theAttachmentHeaderCountsTheRowsItSitsAbove() {
        #expect(CrumbEvidenceCounts.attachedItemsTitle(rowCount: 1) == "What’s attached · 1 item")
        #expect(CrumbEvidenceCounts.attachedItemsTitle(rowCount: 6) == "What’s attached · 6 items")
        #expect(CrumbEvidenceCounts.attachedItemsTitle(rowCount: 7) == "What’s attached · 7 items")
    }

    @Test
    func itemValuesArePluralized() {
        #expect(CrumbEvidenceCounts.itemsValue(1) == "1 item")
        #expect(CrumbEvidenceCounts.itemsValue(3) == "3 items")
    }

    @Test
    func unavailableEvidenceIsCountedNotAssumed() {
        let everything = CrumbEvidenceCounts.unavailableItemCount(
            diagnostics: snapshot(
                cpu: 12,
                memory: 1_024,
                logs: .captured,
                stacks: .captured,
                healthCheck: healthCheck(),
                rendering: renderingSnapshot()
            ),
            hasScreenshot: true
        )
        let nothing = CrumbEvidenceCounts.unavailableItemCount(
            diagnostics: snapshot(
                cpu: nil,
                memory: nil,
                logs: .unavailable,
                stacks: .unavailable,
                healthCheck: nil,
                rendering: nil
            ),
            hasScreenshot: false
        )
        let partial = CrumbEvidenceCounts.unavailableItemCount(
            diagnostics: snapshot(
                cpu: 12,
                memory: 1_024,
                logs: .captured,
                stacks: .unavailable,
                healthCheck: nil,
                rendering: nil
            ),
            hasScreenshot: true
        )

        #expect(everything == 0)
        #expect(nothing == 7)
        #expect(partial == 3)
    }

    private func renderingSnapshot() -> CrumbRenderingSnapshot {
        CrumbRenderingSnapshot(
            source: "ios_display_link",
            sampleCount: 120,
            slowFrameCount: 2,
            meanFrameMs: 8.1,
            maxFrameMs: 24.5,
            gpuSampleCount: 0,
            meanGpuMs: nil,
            maxGpuMs: nil,
            lastFrameAgeMs: 42
        )
    }

    private func healthCheck() -> CrumbHealthCheckDiagnostic {
        CrumbHealthCheckDiagnostic(
            host: "ingestion.crumb.test",
            succeeded: true,
            statusCode: 204,
            latencyMilliseconds: 12,
            failure: nil
        )
    }

    private func snapshot(
        cpu: Double?,
        memory: UInt64?,
        logs: CrumbLogCaptureStatus,
        stacks: CrumbStackTraceCaptureStatus,
        healthCheck: CrumbHealthCheckDiagnostic?,
        rendering: CrumbRenderingSnapshot?
    ) -> CrumbDiagnosticsSnapshot {
        CrumbDiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            location: "SyntheticScreen",
            processName: "SyntheticApp",
            processID: 42,
            cpuUsagePercent: cpu,
            residentMemoryBytes: memory,
            physicalFootprintBytes: memory,
            thermalState: "nominal",
            threadCount: 4,
            busiestThreads: [],
            gpuStatus: "unavailable_on_demand",
            network: CrumbNetworkDiagnostic(
                status: "reachable",
                transport: "wifi",
                cellularGeneration: nil,
                isExpensive: false,
                isConstrained: false,
                healthCheck: healthCheck
            ),
            logs: CrumbLogDiagnostic(
                status: logs,
                sources: [],
                entries: [],
                truncated: false,
                droppedEntryCount: 0,
                failures: []
            ),
            stackTraces: CrumbStackTraceDiagnostic(
                status: stacks,
                scope: "none",
                threads: [],
                truncated: false,
                unavailableReason: nil
            ),
            rendering: rendering
        )
    }
}
