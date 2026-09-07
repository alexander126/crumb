import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbFailureStacksTests {
    @Test
    func liveCaptureLeavesOtherThreadsRunningAndPersistsBoundedNativeFrames() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread { started.signal(); release.wait(); finished.signal() }
        worker.start()
        #expect(started.wait(timeout: .now() + 2) == .success)
        defer { release.signal() }
        let hadExceptionHandler = NSGetUncaughtExceptionHandler() != nil
        let captured = try #require(CrumbFailureStacks.capture())
        #expect((NSGetUncaughtExceptionHandler() != nil) == hadExceptionHandler)
        #expect(captured.threads.count >= 2)
        #expect(captured.threads.contains { $0.state == "capture_thread" })
        #expect(captured.threads.allSatisfy { !$0.frames.isEmpty && $0.frames.count <= 16 })
        #expect(captured.threads.flatMap(\.frames).allSatisfy { !$0.contains("/Users/") && !$0.contains("/private/") })
        let encoded = try JSONEncoder().encode(captured)
        #expect(encoded.count <= CrumbFailureStacks.maximumBytes)
        #expect(try JSONDecoder().decode(CrumbFailureStacks.self, from: encoded) == captured)
        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test
    func rejectsOversizedStoredFrames() {
        let value = CrumbFailureStacks(threads: [.init(index: 0, name: "Thread 0", state: "unknown",
            frames: [String(repeating: "x", count: 513)])], truncated: false)
        #expect(value.validated() == nil)
    }
}
