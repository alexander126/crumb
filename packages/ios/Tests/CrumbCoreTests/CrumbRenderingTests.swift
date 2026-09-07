import Foundation
import Testing
@testable import CrumbCore

struct CrumbRenderingTests {
    @Test func aggregatesOnlyRecentFramesAndClearsOnBackground() throws {
        let buffer = CrumbRenderingBuffer()
        #expect(buffer.snapshot(now: 10) == nil)
        buffer.record(now: 10, frameMs: 16, budgetMs: 16)
        buffer.record(now: 10.1, frameMs: 64, budgetMs: 16)
        let snapshot = try #require(buffer.snapshot(now: 10.2))
        #expect(snapshot.sampleCount == 2 && snapshot.slowFrameCount == 1)
        #expect(snapshot.meanFrameMs == 40 && snapshot.maxFrameMs == 64)
        #expect(snapshot.meanGpuMs == nil)
        #expect(buffer.snapshot(now: 15.2) == nil)
        buffer.clear(); #expect(buffer.snapshot(now: 10.3) == nil)
    }
    @Test func boundsHighRefreshSamplesAndRejectsInvalidDurations() throws {
        let buffer = CrumbRenderingBuffer()
        for _ in 0..<2000 { buffer.record(now: 10, frameMs: 8, budgetMs: 8) }
        buffer.record(now: 10, frameMs: .nan, budgetMs: 8)
        buffer.record(now: 10, frameMs: 6000, budgetMs: 8)
        #expect(try #require(buffer.snapshot(now: 10)).sampleCount == 1000)
    }
}
