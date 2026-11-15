import Foundation

/// One native thread supplied by an adapter-owned stack provider.
public struct CrumbNativeThreadSnapshot: Sendable {
    public let number: Int
    /// Whether this is the thread that requested the snapshot.
    public let isCaptureThread: Bool
    /// Innermost frame first. Crumb sanitizes and bounds every frame before it is stored.
    public let frames: [String]

    public init(number: Int, isCaptureThread: Bool, frames: [String]) {
        self.number = number
        self.isCaptureThread = isCaptureThread
        self.frames = frames
    }
}

/// Raw native stacks from an adapter. CrumbCore never captures stacks itself: the
/// React Native adapter owns the capture and its dependency, so a native
/// application links neither. Whatever a provider returns is sorted, sanitized and
/// cut to Crumb's limits before it is persisted.
public struct CrumbNativeStackSnapshot: Sendable {
    /// A provider may stop here; anything beyond these limits is discarded.
    public static let maximumThreads = 32
    public static let maximumFramesPerThread = 16

    public let threads: [CrumbNativeThreadSnapshot]
    /// Set when the provider already dropped threads or frames.
    public let truncated: Bool

    public init(threads: [CrumbNativeThreadSnapshot], truncated: Bool = false) {
        self.threads = threads
        self.truncated = truncated
    }
}

/// Runs synchronously inside an opted-in JavaScript failure handoff.
public typealias CrumbNativeStackProvider = @Sendable () -> CrumbNativeStackSnapshot?

/// Local-only, independently discardable evidence. IDs are snapshot indexes, not Mach IDs.
package struct CrumbFailureStacks: Codable, Equatable, Sendable {
    package struct Thread: Codable, Equatable, Sendable {
        let index: UInt64
        let name: String
        let state: String
        let frames: [String]
    }
    package let threads: [Thread]
    package let truncated: Bool
    package static let maximumBytes = 12_288
    private static let captureLock = NSLock()

    package func validated() -> Self? {
        guard threads.count <= CrumbNativeStackSnapshot.maximumThreads, threads.allSatisfy({ thread in
            thread.name.utf8.count <= 128 && thread.state.utf8.count <= 64 &&
            thread.frames.count <= CrumbNativeStackSnapshot.maximumFramesPerThread && thread.frames.allSatisfy { $0.utf8.count <= 512 }
        }), let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return nil }
        return self
    }

    package var diagnostic: CrumbStackTraceDiagnostic {
        CrumbStackTraceDiagnostic(status: threads.isEmpty ? .unavailable : .captured,
            scope: "native_threads", threads: threads.map {
                CrumbThreadStackDiagnostic(id: $0.index, name: CrumbLogSanitizer.sanitize($0.name),
                    state: $0.state, frames: $0.frames.map(CrumbLogSanitizer.sanitize))
            }, truncated: truncated, unavailableReason: threads.isEmpty ? "native_stack_capture_empty" : nil)
    }

    /// Called only during an opted-in JS handoff, never from a native signal handler.
    /// Returns nil when no adapter registered a provider, which is every native application.
    package static func capture() -> Self? {
        guard captureLock.try() else { return nil }
        defer { captureLock.unlock() }
        guard let provider = CrumbRuntime.shared.nativeStackProvider(), let snapshot = provider() else { return nil }
        return bounded(snapshot)
    }

    /// The privacy and size boundary for adapter-supplied stacks. It does not trust the
    /// provider to have honoured any limit.
    package static func bounded(_ snapshot: CrumbNativeStackSnapshot) -> Self? {
        let maximumThreads = CrumbNativeStackSnapshot.maximumThreads
        let maximumFrames = CrumbNativeStackSnapshot.maximumFramesPerThread
        let sorted = snapshot.threads.sorted {
            if $0.isCaptureThread != $1.isCaptureThread { return $0.isCaptureThread }
            return $0.number < $1.number
        }
        var threads: [Thread] = []
        var truncated = snapshot.truncated || sorted.count > maximumThreads
        for thread in sorted.prefix(maximumThreads) {
            guard thread.number >= 0 else { truncated = true; continue }
            if thread.frames.count > maximumFrames { truncated = true }
            let rawFrames = thread.frames.prefix(maximumFrames).map(CrumbLogSanitizer.sanitize)
            if rawFrames.contains(where: { $0.utf8.count > 512 }) { truncated = true }
            let formatted = rawFrames.map { value in
                value.utf8.count <= 512 ? value : String(decoding: value.utf8.prefix(508), as: UTF8.self)
            }
            guard !formatted.isEmpty else { continue }
            threads.append(Thread(index: UInt64(thread.number), name: "Thread \(thread.number)",
                state: thread.isCaptureThread ? "capture_thread" : "unknown", frames: formatted))
            while let encoded = try? JSONEncoder().encode(Self(threads: threads, truncated: true)), encoded.count > maximumBytes {
                truncated = true
                guard let last = threads.popLast() else { break }
                guard last.frames.count > 1 else { break }
                threads.append(Thread(index: last.index, name: last.name, state: last.state, frames: Array(last.frames.dropLast())))
            }
            if truncated && threads.last?.index != UInt64(thread.number) { break }
        }
        return Self(threads: threads, truncated: truncated).validated()
    }
}
