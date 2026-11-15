import CrashReporter
import CrumbCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Live native thread stacks for an opted-in JavaScript failure.
///
/// This is the only code in Crumb that uses PLCrashReporter, and it lives in the
/// React Native adapter because the JavaScript failure handoff is the only
/// caller: a native iOS application links neither this file nor the dependency.
/// No crash, signal, or uncaught-exception handler is ever enabled; the reporter
/// is used solely to snapshot the threads that are running right now.
enum CrumbNativeStackCapture {
    private static let maximumReportBytes = 1_048_576

    /// Makes this capture the stack source for `Crumb.recordJavaScriptCrash`.
    /// CrumbCore invokes it only while thread-stack evidence is permitted, then
    /// sanitizes and bounds the result itself.
    static func install() {
        Crumb.setJavaScriptCrashStackProvider { capture() }
    }

    /// Live reports temporarily suspend threads. PLCrashReporter resumes them before
    /// returning, and symbol lookup happens only after that return.
    static func capture() -> CrumbNativeStackSnapshot? {
        let config = PLCrashReporterConfig(signalHandlerType: .BSD, symbolicationStrategy: [],
            shouldRegisterUncaughtExceptionHandler: false, basePath: NSTemporaryDirectory(),
            maxReportBytes: UInt(maximumReportBytes))
        guard let reporter = PLCrashReporter(configuration: config),
              let data = reporter.generateLiveReport(), data.count <= maximumReportBytes,
              let report = try? PLCrashReport(data: data),
              let captured = report.threads as? [PLCrashReportThreadInfo] else { return nil }
        let sorted = captured.sorted {
            if $0.crashed != $1.crashed { return $0.crashed }
            return $0.threadNumber < $1.threadNumber
        }
        // Format only what CrumbCore will keep; it applies the same limits again.
        var truncated = captured.count > CrumbNativeStackSnapshot.maximumThreads
        var threads: [CrumbNativeThreadSnapshot] = []
        for thread in sorted.prefix(CrumbNativeStackSnapshot.maximumThreads) {
            guard let frames = thread.stackFrames as? [PLCrashReportStackFrameInfo] else { truncated = true; continue }
            if frames.count > CrumbNativeStackSnapshot.maximumFramesPerThread { truncated = true }
            threads.append(CrumbNativeThreadSnapshot(number: thread.threadNumber, isCaptureThread: thread.crashed,
                frames: frames.prefix(CrumbNativeStackSnapshot.maximumFramesPerThread).map { format($0, report: report) }))
        }
        return CrumbNativeStackSnapshot(threads: threads, truncated: truncated)
    }

    /// Module name, image-relative offset and image UUID, never a file-system path.
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
        return value
    }
}
