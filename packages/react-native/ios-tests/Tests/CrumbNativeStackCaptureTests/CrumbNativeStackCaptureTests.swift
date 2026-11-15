import CrumbCore
import Foundation
import Testing
@testable import CrumbNativeStackCapture

@Suite(.serialized)
struct CrumbNativeStackCaptureTests {
    @Test
    func liveCaptureLeavesOtherThreadsRunningAndInstallsNoCrashHandler() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread { started.signal(); release.wait(); finished.signal() }
        worker.start()
        #expect(started.wait(timeout: .now() + 2) == .success)
        defer { release.signal() }

        let hadExceptionHandler = NSGetUncaughtExceptionHandler() != nil
        let captured = try #require(CrumbNativeStackCapture.capture())
        #expect((NSGetUncaughtExceptionHandler() != nil) == hadExceptionHandler)

        #expect(captured.threads.count >= 2)
        #expect(captured.threads.count <= CrumbNativeStackSnapshot.maximumThreads)
        #expect(captured.threads.filter(\.isCaptureThread).count == 1)
        #expect(captured.threads.first?.isCaptureThread == true)
        #expect(captured.threads.allSatisfy { !$0.frames.isEmpty && $0.frames.count <= CrumbNativeStackSnapshot.maximumFramesPerThread })
        #expect(captured.threads.flatMap(\.frames).allSatisfy { !$0.contains("/Users/") && !$0.contains("/private/") })

        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }
}
