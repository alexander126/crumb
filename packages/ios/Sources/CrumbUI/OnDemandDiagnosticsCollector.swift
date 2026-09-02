#if os(iOS)
import CoreTelephony
import CrumbCore
import Darwin
import Foundation
import Network

enum OnDemandDiagnosticsCollector {
    static func capture(
        location: String,
        options: CrumbDiagnosticsOptions,
        evidence: Set<CrumbEvidenceCategory> = Set(CrumbEvidenceCategory.allCases)
    ) -> CrumbDiagnosticsSnapshot {
        let capturesPerformance = evidence.contains(.performance)
        let threads = capturesPerformance ? threadDiagnostics() : []
        let cpuUsagePercent: Double? = if !capturesPerformance || threads.isEmpty {
            nil
        } else {
            threads.compactMap(\.cpuUsagePercent).reduce(0, +)
        }
        let memory = capturesPerformance ? memoryDiagnostics() : nil
        let network = evidence.contains(.network)
            ? networkDiagnostics(
                options: CrumbDiagnosticsOptions(
                    healthCheckURL: evidence.contains(.healthCheck) ? options.healthCheckURL : nil,
                    timeout: options.timeout,
                    logs: options.logs
                )
            )
            : CrumbNetworkDiagnostic(
                status: "unknown",
                transport: "unknown",
                cellularGeneration: nil,
                isExpensive: false,
                isConstrained: false,
                healthCheck: nil
            )
        let logs: CrumbLogDiagnostic
        if evidence.contains(.logs) {
            logs = OnDemandLogCollector.capture(options: options.logs)
        } else {
            logs = CrumbLogDiagnostic(
                status: options.logs.enabled ? .disabledByPolicy : .disabled,
                sources: [],
                entries: [],
                truncated: false,
                droppedEntryCount: 0,
                failures: options.logs.enabled ? ["disabled_by_policy"] : []
            )
        }
        let stackTraces = evidence.contains(.threadStacks)
            ? CrumbStackTraceDiagnostic(
                status: .unavailable,
                scope: "none",
                threads: [],
                truncated: false,
                unavailableReason: "all_thread_stacks_unavailable_without_sampling"
            )
            : CrumbStackTraceDiagnostic(
                status: .unavailable,
                scope: "none",
                threads: [],
                truncated: false,
                unavailableReason: "disabled_by_policy"
            )

        return CrumbDiagnosticsSnapshot(
            capturedAt: Date(),
            location: location,
            processName: ProcessInfo.processInfo.processName,
            processID: getpid(),
            cpuUsagePercent: cpuUsagePercent,
            residentMemoryBytes: memory?.resident,
            physicalFootprintBytes: memory?.footprint,
            thermalState: capturesPerformance ? thermalState() : "unavailable_by_policy",
            threadCount: threads.count,
            busiestThreads: Array(
                threads
                    .sorted { ($0.cpuUsagePercent ?? 0) > ($1.cpuUsagePercent ?? 0) }
                    .prefix(12)
            ),
            gpuStatus: "Unavailable on demand on iOS",
            network: network,
            logs: logs,
            stackTraces: stackTraces
        )
    }

    private static func memoryDiagnostics() -> (resident: UInt64, footprint: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }

    private static func threadDiagnostics() -> [CrumbThreadDiagnostic] {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return []
        }
        defer {
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                byteCount
            )
        }

        var snapshots: [CrumbThreadDiagnostic] = []
        snapshots.reserveCapacity(Int(threadCount))
        for index in 0..<Int(threadCount) {
            let thread = threadList[index]
            defer { mach_port_deallocate(mach_task_self_, thread) }

            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { rebound in
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }

            let cpu: Double? = (info.flags & TH_FLAGS_IDLE) == 0
                ? Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
                : 0
            snapshots.append(
                CrumbThreadDiagnostic(
                    id: UInt64(thread),
                    name: threadName(thread) ?? "thread-\(thread)",
                    state: threadState(info.run_state),
                    cpuUsagePercent: cpu
                )
            )
        }
        return snapshots
    }

    private static func threadName(_ thread: thread_t) -> String? {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            pthread_getname_np(pthread, pointer.baseAddress!, pointer.count)
        }
        guard result == 0 else { return nil }
        let name = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return name.isEmpty ? nil : name
    }

    private static func threadState(_ state: Int32) -> String {
        switch state {
        case TH_STATE_RUNNING: "running"
        case TH_STATE_STOPPED: "stopped"
        case TH_STATE_WAITING: "waiting"
        case TH_STATE_UNINTERRUPTIBLE: "uninterruptible"
        case TH_STATE_HALTED: "halted"
        default: "unknown"
        }
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func networkDiagnostics(
        options: CrumbDiagnosticsOptions
    ) -> CrumbNetworkDiagnostic {
        // Connectivity is useful context, but it must never consume the report-time
        // diagnostics budget. NWPathMonitor normally publishes immediately; when a
        // device does not, preserve an honest `unknown` value rather than blocking.
        let path = currentNetworkPath(timeout: min(options.timeout, 0.1))
        let transport = path.map(networkTransport) ?? "unknown"
        let health = options.healthCheckURL.map {
            CrumbInfrastructureHealthProbe.capture(url: $0, timeout: options.timeout)
        }
        return CrumbNetworkDiagnostic(
            status: path.map { $0.status == .satisfied ? "reachable" : "unreachable" } ?? "unknown",
            transport: transport,
            cellularGeneration: transport == "cellular" ? cellularGeneration() : nil,
            isExpensive: path?.isExpensive ?? false,
            isConstrained: path?.isConstrained ?? false,
            healthCheck: health
        )
    }

    private static func currentNetworkPath(timeout: TimeInterval) -> NWPath? {
        let monitor = NWPathMonitor()
        let result = LockedValue<NWPath>()
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            result.setIfEmpty(path)
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "dev.crumb.network-probe"))
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return result.value
    }

    private static func networkTransport(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        if path.usesInterfaceType(.loopback) { return "loopback" }
        return "other"
    }

    private static func cellularGeneration() -> String? {
        let technologies = CTTelephonyNetworkInfo()
            .serviceCurrentRadioAccessTechnology
            .map { Array($0.values) } ?? []
        guard let technology = technologies.first else { return nil }
        if #available(iOS 14.1, *),
           technology == CTRadioAccessTechnologyNR || technology == CTRadioAccessTechnologyNRNSA {
            return "5G"
        }
        if technology == CTRadioAccessTechnologyLTE { return "4G/LTE" }
        if [CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA,
            CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMAEVDORev0,
            CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB,
            CTRadioAccessTechnologyeHRPD].contains(technology) {
            return "3G"
        }
        return "2G"
    }

}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setIfEmpty(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        if storage == nil { storage = value }
    }
}
#endif
