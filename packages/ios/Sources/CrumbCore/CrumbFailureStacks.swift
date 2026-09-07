import Foundation
import CrashReporter
#if canImport(Darwin)
import Darwin
#endif

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
        guard threads.count <= 32, threads.allSatisfy({ thread in
            thread.name.utf8.count <= 128 && thread.state.utf8.count <= 64 &&
            thread.frames.count <= 16 && thread.frames.allSatisfy { $0.utf8.count <= 512 }
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
    /// Live reports temporarily suspend threads. PLCrashReporter resumes them before returning;
    /// no crash handler is enabled and symbol lookup happens only after that return.
    package static func capture() -> Self? {
        guard captureLock.try() else { return nil }
        defer { captureLock.unlock() }
        let config = PLCrashReporterConfig(signalHandlerType: .BSD, symbolicationStrategy: [],
            shouldRegisterUncaughtExceptionHandler: false, basePath: NSTemporaryDirectory(), maxReportBytes: 1_048_576)
        guard let reporter = PLCrashReporter(configuration: config),
              let data = reporter.generateLiveReport(), data.count <= 1_048_576,
              let report = try? PLCrashReport(data: data),
              let captured = report.threads as? [PLCrashReportThreadInfo] else { return nil }
        let sorted = captured.sorted {
            if $0.crashed != $1.crashed { return $0.crashed }
            return $0.threadNumber < $1.threadNumber
        }
        var threads: [Thread] = []
        var truncated = captured.count > 32
        for thread in sorted.prefix(32) {
            guard thread.threadNumber >= 0,
                  let frames = thread.stackFrames as? [PLCrashReportStackFrameInfo] else { truncated = true; continue }
            if frames.count > 16 { truncated = true }
            let rawFrames = frames.prefix(16).map { frame in format(frame, report: report) }
            if rawFrames.contains(where: { $0.utf8.count > 512 }) { truncated = true }
            let formatted = rawFrames.map { value in
                value.utf8.count <= 512 ? value : String(decoding: value.utf8.prefix(508), as: UTF8.self)
            }
            guard !formatted.isEmpty else { continue }
            threads.append(Thread(index: UInt64(thread.threadNumber), name: "Thread \(thread.threadNumber)",
                state: thread.crashed ? "capture_thread" : "unknown", frames: formatted))
            while let encoded = try? JSONEncoder().encode(Self(threads: threads, truncated: true)), encoded.count > maximumBytes {
                truncated = true
                guard let last = threads.popLast() else { break }
                guard last.frames.count > 1 else { break }
                threads.append(Thread(index: last.index, name: last.name, state: last.state, frames: Array(last.frames.dropLast())))
            }
            if truncated && threads.last?.index != UInt64(thread.threadNumber) { break }
        }
        return Self(threads: threads, truncated: truncated).validated()
    }

    private static func format(_ frame: PLCrashReportStackFrameInfo, report: PLCrashReport) -> String {
        let address = frame.instructionPointer
        guard let image = report.image(forAddress: address), address >= image.imageBaseAddress else {
            return "unknown image · 0x\(String(address, radix: 16))"
        }
        let module = URL(fileURLWithPath: image.imageName).lastPathComponent
        let uuid = image.hasImageUUID ? image.imageUUID ?? "unknown" : "unknown"
        var value = "\(module) + 0x\(String(address - image.imageBaseAddress, radix: 16)) [\(uuid)]"
        #if canImport(Darwin)
        var info = Dl_info()
        if let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &info) != 0,
           let symbol = info.dli_sname, let start = info.dli_saddr, address >= UInt64(UInt(bitPattern: start)) {
            value += " · \(String(cString: symbol)) + \(address - UInt64(UInt(bitPattern: start)))"
        }
        #endif
        return CrumbLogSanitizer.sanitize(value)
    }
}
