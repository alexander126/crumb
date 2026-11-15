import Foundation
import Testing
@testable import CrumbCore

// Share CrumbCoreTests' serialized scope: the stack provider is process-wide state.
extension CrumbCoreTests {
    @Test
    func capturesNothingUntilAnAdapterRegistersAProvider() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        #expect(CrumbFailureStacks.capture() == nil)

        Crumb.setJavaScriptCrashStackProvider {
            CrumbNativeStackSnapshot(threads: [
                .init(number: 3, isCaptureThread: false, frames: ["SyntheticApp + 0x20"]),
                .init(number: 7, isCaptureThread: true, frames: ["SyntheticApp + 0x10 · handoff + 4"]),
            ])
        }
        let captured = try #require(CrumbFailureStacks.capture())
        #expect(captured.threads.map(\.index) == [7, 3])
        #expect(captured.threads.map(\.state) == ["capture_thread", "unknown"])
        #expect(captured.threads.first?.frames == ["SyntheticApp + 0x10 · handoff + 4"])
        #expect(!captured.truncated)
        #expect(captured.diagnostic.status == .captured)

        Crumb.setJavaScriptCrashStackProvider { nil }
        #expect(CrumbFailureStacks.capture() == nil)
        Crumb.setJavaScriptCrashStackProvider(nil)
        #expect(CrumbFailureStacks.capture() == nil)
    }

    @Test
    func failureContextRecordsProviderStacksOnlyWhenThreadStackEvidenceIsAllowed() throws {
        Crumb.resetForTesting()
        defer { Crumb.resetForTesting() }
        let calls = LockedCounter()
        Crumb.setJavaScriptCrashStackProvider {
            calls.increment()
            return CrumbNativeStackSnapshot(threads: [.init(number: 0, isCaptureThread: true, frames: ["SyntheticApp + 0x1234"])])
        }

        try Crumb.start(stackConfiguration(evidence: [.screenshot]))
        #expect(CrumbJavaScriptFailureContext.capture(settings: try Crumb.reportSettings()).stacks == nil)
        #expect(calls.value == 0)

        Crumb.resetForTesting()
        Crumb.setJavaScriptCrashStackProvider {
            calls.increment()
            return CrumbNativeStackSnapshot(threads: [.init(number: 0, isCaptureThread: true, frames: ["SyntheticApp + 0x1234"])])
        }
        try Crumb.start(stackConfiguration(evidence: [.threadStacks]))
        let context = CrumbJavaScriptFailureContext.capture(settings: try Crumb.reportSettings())
        #expect(context.stacks?.threads.first?.frames == ["SyntheticApp + 0x1234"])
        #expect(calls.value == 1)
    }

    @Test
    func boundsAndSanitizesWhateverAProviderReturns() throws {
        let longFrame = "SyntheticApp + 0x1 · " + String(repeating: "x", count: 600)
        let threads = (0..<40).map { number in
            CrumbNativeThreadSnapshot(number: number, isCaptureThread: number == 39,
                frames: (0..<30).map { frame in frame == 0 ? "SyntheticApp + 0x\(number) password=synthetic-secret" : longFrame })
        }
        let bounded = try #require(CrumbFailureStacks.bounded(CrumbNativeStackSnapshot(threads: threads)))
        #expect(bounded.truncated)
        #expect(bounded.threads.first?.index == 39)
        #expect(bounded.threads.first?.state == "capture_thread")
        #expect(bounded.threads.count <= CrumbNativeStackSnapshot.maximumThreads)
        #expect(bounded.threads.allSatisfy { !$0.frames.isEmpty && $0.frames.count <= CrumbNativeStackSnapshot.maximumFramesPerThread })
        #expect(bounded.threads.flatMap(\.frames).allSatisfy { $0.utf8.count <= 512 && !$0.contains("synthetic-secret") })
        #expect(try JSONEncoder().encode(bounded).count <= CrumbFailureStacks.maximumBytes)

        let negative = try #require(CrumbFailureStacks.bounded(CrumbNativeStackSnapshot(threads: [
            .init(number: -1, isCaptureThread: false, frames: ["SyntheticApp + 0x1"]),
            .init(number: 2, isCaptureThread: false, frames: []),
        ])))
        #expect(negative.threads.isEmpty)
        #expect(negative.truncated)
        #expect(negative.diagnostic.status == .unavailable)

        let alreadyCut = try #require(CrumbFailureStacks.bounded(CrumbNativeStackSnapshot(
            threads: [.init(number: 0, isCaptureThread: true, frames: ["SyntheticApp + 0x1"])], truncated: true)))
        #expect(alreadyCut.truncated)
    }

    @Test
    func rejectsOversizedStoredFrames() {
        let value = CrumbFailureStacks(threads: [.init(index: 0, name: "Thread 0", state: "unknown",
            frames: [String(repeating: "x", count: 513)])], truncated: false)
        #expect(value.validated() == nil)
    }
}

private func stackConfiguration(evidence: Set<CrumbEvidenceCategory>) -> CrumbConfiguration {
    CrumbConfiguration(projectKey: "project_write_key", environment: "test",
        release: CrumbRelease(appVersion: "1.0.0", nativeBuild: "1"), evidence: evidence)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
