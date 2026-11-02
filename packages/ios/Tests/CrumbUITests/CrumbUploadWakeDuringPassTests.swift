#if canImport(Network)
@testable import CrumbCore
import Foundation
import Testing
@testable import CrumbUI

@MainActor
struct CrumbUploadWakeDuringPassTests {
    /// The defect this fixes: a report committed while a pass was running raised
    /// a wake that `wake()` dropped. The running pass had already taken its
    /// queue snapshot, and it ends here with `shouldRetry == false` and
    /// `wasCancelled == false`, so the coordinator treated the session as
    /// finished and the new report waited for the next foreground transition.
    @Test
    func aReportQueuedDuringARunningPassIsDeliveredInTheSameSession() async throws {
        let fixture = try await WakeFixture()
        defer {
            fixture.coordinator.pause()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let coordinator = fixture.coordinator

        coordinator.resume()
        await fixture.transport.waitUntilBlocked()
        #expect(await fixture.transport.attempts(fixture.blockingID) == 1)

        try await fixture.enqueue(fixture.lateID, offset: 1)
        coordinator.reportDidQueue()
        await fixture.transport.release()
        await settle(coordinator)

        #expect(await fixture.transport.attempts(fixture.lateID) == 1)
        #expect(try await fixture.queue.reports().count == 1)
        let retained = try await fixture.queue.load(reportID: fixture.blockingID)
        #expect(retained.summary.state == .failed)
    }

    /// Repeated commits during one pass must not queue up several passes.
    @Test
    func repeatedWakesDuringOnePassRunOneFollowUpPass() async throws {
        let fixture = try await WakeFixture()
        defer {
            fixture.coordinator.pause()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let coordinator = fixture.coordinator

        coordinator.resume()
        await fixture.transport.waitUntilBlocked()
        try await fixture.enqueue(fixture.lateID, offset: 1)
        coordinator.reportDidQueue()
        coordinator.reportDidQueue()
        coordinator.reportDidQueue()
        await fixture.transport.release()
        await settle(coordinator)

        #expect(await fixture.transport.attempts(fixture.lateID) == 1)
        #expect(await fixture.transport.attempts(fixture.blockingID) == 1)
    }

    /// Backgrounding during a pass must not leave a wake armed.
    @Test
    func aWakeDuringAPassIsDiscardedWhenTheAppLeavesTheForeground() async throws {
        let fixture = try await WakeFixture()
        defer {
            fixture.coordinator.pause()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let coordinator = fixture.coordinator

        coordinator.resume()
        await fixture.transport.waitUntilBlocked()
        try await fixture.enqueue(fixture.lateID, offset: 1)
        coordinator.reportDidQueue()
        coordinator.pause()
        await fixture.transport.release()
        await settle(coordinator)

        #expect(await fixture.transport.attempts(fixture.lateID) == 0)
    }

    private func settle(_ coordinator: CrumbUploadCoordinator) async {
        while let task = coordinator.uploadTask { await task.value }
    }
}

@MainActor
private struct WakeFixture {
    let root: URL
    let queue: CrumbReportQueue
    let transport: WakeTransport
    let coordinator: CrumbUploadCoordinator
    let blockingID = "rpt_BlockingAAAAAAAAAAAAAAAAAAAAAAAA"
    let lateID = "rpt_LateBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-wake-\(UUID().uuidString)")
        let settings = CrumbUploadSettings(
            projectKey: "synthetic-wake-key",
            ingestionURL: try #require(URL(string: "https://ingestion.example.invalid"))
        )
        queue = CrumbReportQueue(
            rootURL: root,
            ownerFingerprint: CrumbQueueOwnerFingerprint.make(
                projectKey: settings.projectKey,
                ingestionURL: settings.ingestionURL
            )
        )
        transport = WakeTransport(blockingID: blockingID)
        coordinator = CrumbUploadCoordinator(
            worker: CrumbReportUploadWorker(queue: queue, settings: settings, transport: transport),
            observesConnectivity: false
        )
        try await enqueue(blockingID, offset: 0)
    }

    func enqueue(_ id: String, offset: TimeInterval) async throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["schema_version": "1.0", "report_id": id, "artifacts": []] as [String: Any]
        )
        try await queue.enqueue(
            envelope: .init(
                reportID: id,
                submittedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
                data: data
            ),
            artifacts: []
        )
    }
}

/// Holds the first report inside its `init` call so a commit can land while the
/// pass is demonstrably running, then answers terminally for it: the pass must
/// finish with nothing retryable, which is the case that used to end the
/// session.
private actor WakeTransport: CrumbUploadTransport {
    let blockingID: String
    private var counts: [String: Int] = [:]
    private var blocked = false
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(blockingID: String) {
        self.blockingID = blockingID
    }

    func attempts(_ id: String) -> Int { counts[id, default: 0] }

    func waitUntilBlocked() async {
        if !blocked { await withCheckedContinuation { blockedWaiter = $0 } }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        guard request.url?.path.hasSuffix("/init") == true else {
            return .init(statusCode: 200, data: Data(#"{"status":"accepted"}"#.utf8))
        }
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(body["envelope"] as? [String: Any])
        let id = try #require(envelope["report_id"] as? String)
        counts[id, default: 0] += 1

        if id == blockingID {
            if counts[id] == 1 {
                blocked = true
                blockedWaiter?.resume()
                blockedWaiter = nil
                await withCheckedContinuation { releaseWaiter = $0 }
            }
            // Terminal: the pass must end with shouldRetry == false.
            return .init(statusCode: 422)
        }

        let initialized: [String: Any] = ["report_id": id, "status": "accepted", "artifacts": []]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: initialized))
    }
}
#endif
