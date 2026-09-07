import Foundation

public struct CrumbRenderingSnapshot: Codable, Equatable, Sendable {
    public let source: String
    public let sampleCount: Int
    public let slowFrameCount: Int
    public let meanFrameMs: Double
    public let maxFrameMs: Double
    public let gpuSampleCount: Int
    public let meanGpuMs: Double?
    public let maxGpuMs: Double?
    public let lastFrameAgeMs: Double

    package func validated() -> Self? {
        guard source == "ios_display_link", (1...5000).contains(sampleCount), (0...sampleCount).contains(slowFrameCount),
              gpuSampleCount == 0, meanGpuMs == nil, maxGpuMs == nil,
              [meanFrameMs, maxFrameMs, lastFrameAgeMs].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 5000 }),
              maxFrameMs >= meanFrameMs, lastFrameAgeMs < 5000 else { return nil }
        return self
    }

    public init(source: String, sampleCount: Int, slowFrameCount: Int, meanFrameMs: Double, maxFrameMs: Double,
                gpuSampleCount: Int = 0, meanGpuMs: Double? = nil, maxGpuMs: Double? = nil, lastFrameAgeMs: Double) {
        self.source = source; self.sampleCount = sampleCount; self.slowFrameCount = slowFrameCount
        self.meanFrameMs = meanFrameMs; self.maxFrameMs = maxFrameMs; self.gpuSampleCount = gpuSampleCount
        self.meanGpuMs = meanGpuMs; self.maxGpuMs = maxGpuMs; self.lastFrameAgeMs = lastFrameAgeMs
    }
}

/// Only numeric, five-second aggregates. The UI module owns platform observation.
package final class CrumbRenderingBuffer: @unchecked Sendable {
    package static let shared = CrumbRenderingBuffer()
    private struct Bucket {
        var second = -1, count = 0, slow = 0
        var sum = 0.0, maximum = 0.0
    }
    private let lock = NSLock()
    private var buckets = Array(repeating: Bucket(), count: 5)
    private var last = -1.0
    package init() {}
    package func clear() { lock.lock(); defer { lock.unlock() }; buckets = Array(repeating: Bucket(), count: 5); last = -1 }
    package func record(now: Double, frameMs: Double, budgetMs: Double) {
        guard now.isFinite, now >= 0, frameMs.isFinite, frameMs > 0, frameMs <= 5000,
              budgetMs.isFinite, budgetMs > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let second = Int(now), index = second % 5
        if buckets[index].second != second { buckets[index] = Bucket(second: second) }
        guard buckets[index].count < 1000 else { return }
        buckets[index].count += 1; buckets[index].sum += frameMs
        buckets[index].maximum = max(buckets[index].maximum, frameMs)
        if frameMs > budgetMs * 1.5 { buckets[index].slow += 1 }
        last = now
    }
    package func snapshot(now: Double = ProcessInfo.processInfo.systemUptime) -> CrumbRenderingSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, last >= 0, now >= last, now - last < 5 else { return nil }
        let active = buckets.filter { $0.second > Int(now) - 5 && $0.second <= Int(now) }
        let count = active.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        return CrumbRenderingSnapshot(source: "ios_display_link", sampleCount: count,
            slowFrameCount: active.reduce(0) { $0 + $1.slow }, meanFrameMs: active.reduce(0.0) { $0 + $1.sum } / Double(count),
            maxFrameMs: active.map(\.maximum).max() ?? 0, lastFrameAgeMs: (now - last) * 1000)
    }
    package static func capture(settings: CrumbReportSettings) -> CrumbRenderingSnapshot? {
        guard settings.diagnostics.renderingEnabled, settings.evidence.contains(.performance) else { shared.clear(); return nil }
        return shared.snapshot()
    }
}
