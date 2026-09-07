import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Network)
import Network
#endif

/// Local persistence only. Serialized reports continue to use envelope 1.0 diagnostics.
package struct CrumbJavaScriptFailureContext: Codable, Equatable, Sendable {
    package let capturedAt: Date
    package let processName: String
    package let processID: Int32
    package let cpuUsagePercent: Double?
    package let residentMemoryBytes: UInt64?
    package let physicalFootprintBytes: UInt64?
    package let threadCount: Int?
    package let thermalState: String
    package let networkStatus: String
    package let networkTransport: String
    package let networkExpensive: Bool
    package let networkConstrained: Bool

    package func validated() -> Self? {
        guard capturedAt.timeIntervalSince1970.isFinite,
              capturedAt.timeIntervalSince1970 > 0, processID > 0,
              !processName.isEmpty, processName.utf8.count <= 128,
              cpuUsagePercent.map({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }) ?? true,
              threadCount.map({ $0 >= 0 && $0 <= 10_000 }) ?? true,
              ["nominal", "fair", "serious", "critical", "unknown", "unavailable"].contains(thermalState),
              ["reachable", "unreachable", "unknown"].contains(networkStatus),
              ["wifi", "cellular", "ethernet", "other", "none", "unknown"].contains(networkTransport)
        else { return nil }
        return self
    }

    package func diagnostics() -> CrumbDiagnosticsSnapshot {
        CrumbDiagnosticsSnapshot(
            capturedAt: capturedAt, location: "react_native_javascript_failure",
            processName: CrumbLogSanitizer.sanitize(processName), processID: processID,
            cpuUsagePercent: cpuUsagePercent, residentMemoryBytes: residentMemoryBytes,
            physicalFootprintBytes: physicalFootprintBytes, thermalState: thermalState,
            threadCount: threadCount ?? 0, busiestThreads: [], gpuStatus: "unavailable_on_demand",
            network: CrumbNetworkDiagnostic(status: networkStatus, transport: networkTransport,
                cellularGeneration: nil, isExpensive: networkExpensive,
                isConstrained: networkConstrained, healthCheck: nil),
            logs: CrumbLogDiagnostic(status: .unavailable, sources: [], entries: [],
                truncated: false, droppedEntryCount: 0, failures: []),
            stackTraces: CrumbStackTraceDiagnostic(status: .unavailable, scope: "none",
                threads: [], truncated: false, unavailableReason: "native_stacks_not_captured_during_javascript_failure")
        )
    }

    /// Only invoked for an opted-in JavaScript handoff. No provider callbacks or HTTP probes.
    package static func capture(settings: CrumbReportSettings) -> Self {
        let capturedAt = Date()
        let performance = settings.evidence.contains(.performance)
        let memory = performance ? memorySnapshot() : nil
        let threads = performance ? threadSnapshot() : (nil, nil)
        let network = settings.evidence.contains(.network) ? networkSnapshot() : nil
        return Self(capturedAt: capturedAt,
            processName: String(CrumbLogSanitizer.sanitize(ProcessInfo.processInfo.processName).prefix(128)),
            processID: ProcessInfo.processInfo.processIdentifier,
            cpuUsagePercent: threads.1, residentMemoryBytes: memory?.0,
            physicalFootprintBytes: memory?.1, threadCount: threads.0,
            thermalState: performance ? thermalSnapshot() : "unavailable",
            networkStatus: network?.0 ?? "unknown", networkTransport: network?.1 ?? "unknown",
            networkExpensive: network?.2 ?? false, networkConstrained: network?.3 ?? false)
    }

    private static func memorySnapshot() -> (UInt64, UInt64)? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (UInt64(info.resident_size), UInt64(info.phys_footprint)) : nil
        #else
        return nil
        #endif
    }

    private static func threadSnapshot() -> (Int?, Double?) {
        #if canImport(Darwin)
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return (nil, nil) }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        // Count all threads, but never perform an unbounded per-thread diagnostic walk.
        guard count <= 256 else { return (Int(count), nil) }
        var cpu = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { return (Int(count), nil) }
            if info.flags & TH_FLAGS_IDLE == 0 { cpu += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100 }
        }
        return (Int(count), cpu)
        #else
        return (nil, nil)
        #endif
    }

    private static func thermalSnapshot() -> String {
        #if canImport(Darwin)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
        #else
        return "unavailable"
        #endif
    }

    private static func networkSnapshot() -> (String, String, Bool, Bool)? {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        let result = FailurePathBox()
        let ready = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in result.set(path); ready.signal() }
        monitor.start(queue: DispatchQueue(label: "dev.crumb.failure-connectivity"))
        defer { monitor.cancel() }
        // A local connectivity observation only; no network requests and no long wait on failure.
        guard ready.wait(timeout: .now() + .milliseconds(30)) == .success, let path = result.get() else { return nil }
        let transport = path.usesInterfaceType(.wifi) ? "wifi" :
            path.usesInterfaceType(.cellular) ? "cellular" :
            path.usesInterfaceType(.wiredEthernet) ? "ethernet" :
            path.status == .satisfied ? "other" : "none"
        return (path.status == .satisfied ? "reachable" : "unreachable", transport, path.isExpensive, path.isConstrained)
        #else
        return nil
        #endif
    }
}

#if canImport(Network)
private final class FailurePathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NWPath?
    func set(_ path: NWPath) { lock.lock(); defer { lock.unlock() }; value = path }
    func get() -> NWPath? { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
