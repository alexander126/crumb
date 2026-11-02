#if canImport(Network)
@testable import CrumbCore
import Foundation
import Testing
@testable import CrumbUI

@MainActor
struct CrumbUploadCoordinatorTests {
    @Test
    func automaticWakesRemainTerminalButLaterForegroundRearms() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.coordinator.pause(); try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.resume()
        await settle(coordinator)
        let failed = try await fixture.queue.load(reportID: fixture.terminalID)
        #expect(failed.summary.attemptCount == 1)

        // show() and repeated lifecycle delivery may call resume while already foreground.
        coordinator.resume()
        await settle(coordinator)
        #expect(await fixture.transport.attempts(fixture.terminalID) == 1)

        try await fixture.enqueue(fixture.newID, offset: 2)
        coordinator.reportDidQueue()
        await settle(coordinator)
        #expect(await fixture.transport.attempts(fixture.newID) == 1)
        #expect(try await fixture.queue.load(reportID: fixture.terminalID) == failed)
        #expect(try await fixture.queue.reports().count == 1)

        coordinator.connectivityDidBecomeAvailable(generation: coordinator.connectivityGeneration)
        await settle(coordinator)
        #expect(await fixture.transport.attempts(fixture.terminalID) == 1)

        coordinator.pause()
        coordinator.reportDidQueue()
        #expect(coordinator.uploadTask == nil)
        coordinator.resume()
        await settle(coordinator)
        #expect(await fixture.transport.attempts(fixture.terminalID) == 2)
        #expect(try await fixture.queue.load(reportID: fixture.terminalID).summary.attemptCount == 2)
        coordinator.resume()
        await settle(coordinator)
        #expect(await fixture.transport.attempts(fixture.terminalID) == 2)
    }

    @Test
    func foregroundIntentWaitsForOldCancelledPass() async throws {
        let fixture = try await CoordinatorFixture(blockTransient: true)
        defer { fixture.coordinator.pause(); try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.resume()
        await fixture.transport.waitUntilBlocked()
        #expect(await fixture.transport.attempts(fixture.terminalID) == 1)

        coordinator.pause()
        coordinator.resume()
        coordinator.resume()
        coordinator.reportDidQueue()
        await fixture.transport.release()
        await settle(coordinator)

        #expect(await fixture.transport.attempts(fixture.terminalID) == 2)
        #expect(await fixture.transport.attempts(fixture.transientID) == 2)
        #expect(try await fixture.queue.load(reportID: fixture.terminalID).summary.attemptCount == 2)
        #expect(try await fixture.queue.load(reportID: fixture.transientID).summary.attemptCount == 2)
    }

    @Test
    func retiredConnectivitySignalCannotRestartQuiescentTerminalQueue() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.coordinator.pause(); try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = fixture.coordinator
        coordinator.resume()
        let retiredGeneration = coordinator.connectivityGeneration
        await settle(coordinator)
        #expect(coordinator.connectivityGeneration != retiredGeneration)

        // Models a satisfied callback posted before stopConnectivityMonitoring retired it.
        coordinator.connectivityDidBecomeAvailable(generation: retiredGeneration)
        #expect(coordinator.uploadTask == nil)
        #expect(await fixture.transport.attempts(fixture.terminalID) == 1)
        #expect(try await fixture.queue.load(reportID: fixture.terminalID).summary.attemptCount == 1)
    }

    private func settle(_ coordinator: CrumbUploadCoordinator) async {
        while let task = coordinator.uploadTask { await task.value }
    }
}

@MainActor
private struct CoordinatorFixture {
    let root: URL
    let queue: CrumbReportQueue
    let transport: CoordinatorTransport
    let coordinator: CrumbUploadCoordinator
    let terminalID = "rpt_TerminalAAAAAAAAAAAAAAAAAAAAAAAAA"
    let transientID = "rpt_TransientBBBBBBBBBBBBBBBBBBBBBBBB"
    let newID = "rpt_NewCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

    init(blockTransient: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("crumb-coordinator-\(UUID().uuidString)")
        let settings = CrumbUploadSettings(projectKey: "synthetic-coordinator-key", ingestionURL: try #require(URL(string: "https://ingestion.example.invalid")))
        queue = CrumbReportQueue(rootURL: root, ownerFingerprint: CrumbQueueOwnerFingerprint.make(projectKey: settings.projectKey, ingestionURL: settings.ingestionURL))
        transport = CoordinatorTransport(terminalID: terminalID, transientID: transientID, blocksTransient: blockTransient)
        coordinator = CrumbUploadCoordinator(worker: CrumbReportUploadWorker(queue: queue, settings: settings, transport: transport), observesConnectivity: false)
        try await enqueue(terminalID, offset: 0)
        if blockTransient { try await enqueue(transientID, offset: 1) }
    }

    func enqueue(_ id: String, offset: TimeInterval) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "report_id": id, "artifacts": []] as [String: Any])
        try await queue.enqueue(envelope: .init(reportID: id, submittedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), data: data), artifacts: [])
    }
}

private actor CoordinatorTransport: CrumbUploadTransport {
    let terminalID: String
    let transientID: String
    let blocksTransient: Bool
    private var counts: [String: Int] = [:]
    private var blocked = false
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(terminalID: String, transientID: String, blocksTransient: Bool) {
        self.terminalID = terminalID
        self.transientID = transientID
        self.blocksTransient = blocksTransient
    }

    func attempts(_ id: String) -> Int { counts[id, default: 0] }
    func waitUntilBlocked() async {
        if !blocked { await withCheckedContinuation { blockedWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        guard request.url?.path.hasSuffix("/init") == true else {
            return .init(statusCode: 200, data: Data(#"{"status":"accepted"}"#.utf8))
        }
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(body["envelope"] as? [String: Any])
        let id = try #require(envelope["report_id"] as? String)
        counts[id, default: 0] += 1
        if id == terminalID { return .init(statusCode: 422) }
        if id == transientID {
            if blocksTransient && counts[id] == 1 {
                blocked = true
                blockedWaiter?.resume()
                blockedWaiter = nil
                await withCheckedContinuation { releaseWaiter = $0 }
            }
            return .init(statusCode: 503)
        }
        let initialized: [String: Any] = ["report_id": id, "status": "accepted", "artifacts": []]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: initialized))
    }
}
#endif
