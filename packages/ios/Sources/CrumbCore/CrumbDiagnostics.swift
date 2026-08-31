import Foundation

public struct CrumbThreadDiagnostic: Equatable, Sendable {
    public let id: UInt64
    public let name: String
    public let state: String
    public let cpuUsagePercent: Double?

    public init(id: UInt64, name: String, state: String, cpuUsagePercent: Double?) {
        self.id = id
        self.name = name
        self.state = state
        self.cpuUsagePercent = cpuUsagePercent
    }
}

public enum CrumbStackTraceCaptureStatus: String, Equatable, Sendable {
    case captured
    case unavailable
}

public struct CrumbThreadStackDiagnostic: Equatable, Sendable {
    public let id: UInt64
    public let name: String
    public let state: String
    public let frames: [String]

    public init(id: UInt64, name: String, state: String, frames: [String]) {
        self.id = id
        self.name = name
        self.state = state
        self.frames = frames
    }
}

public struct CrumbStackTraceDiagnostic: Equatable, Sendable {
    public let status: CrumbStackTraceCaptureStatus
    public let scope: String
    public let threads: [CrumbThreadStackDiagnostic]
    public let truncated: Bool
    public let unavailableReason: String?

    public init(
        status: CrumbStackTraceCaptureStatus,
        scope: String,
        threads: [CrumbThreadStackDiagnostic],
        truncated: Bool,
        unavailableReason: String?
    ) {
        self.status = status
        self.scope = scope
        self.threads = threads
        self.truncated = truncated
        self.unavailableReason = unavailableReason
    }
}

public struct CrumbHealthCheckDiagnostic: Equatable, Sendable {
    public let host: String
    public let succeeded: Bool
    public let statusCode: Int?
    public let latencyMilliseconds: Int
    public let failure: String?

    public init(
        host: String,
        succeeded: Bool,
        statusCode: Int?,
        latencyMilliseconds: Int,
        failure: String?
    ) {
        self.host = host
        self.succeeded = succeeded
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.failure = failure
    }
}

public struct CrumbNetworkDiagnostic: Equatable, Sendable {
    public let status: String
    public let transport: String
    public let cellularGeneration: String?
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let healthCheck: CrumbHealthCheckDiagnostic?

    public init(
        status: String,
        transport: String,
        cellularGeneration: String?,
        isExpensive: Bool,
        isConstrained: Bool,
        healthCheck: CrumbHealthCheckDiagnostic?
    ) {
        self.status = status
        self.transport = transport
        self.cellularGeneration = cellularGeneration
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.healthCheck = healthCheck
    }
}

public struct CrumbDiagnosticsSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let location: String
    public let processName: String
    public let processID: Int32
    public let cpuUsagePercent: Double?
    public let residentMemoryBytes: UInt64?
    public let physicalFootprintBytes: UInt64?
    public let thermalState: String
    public let threadCount: Int
    public let busiestThreads: [CrumbThreadDiagnostic]
    public let gpuStatus: String
    public let network: CrumbNetworkDiagnostic
    public let logs: CrumbLogDiagnostic
    public let stackTraces: CrumbStackTraceDiagnostic

    public init(
        capturedAt: Date,
        location: String,
        processName: String,
        processID: Int32,
        cpuUsagePercent: Double?,
        residentMemoryBytes: UInt64?,
        physicalFootprintBytes: UInt64?,
        thermalState: String,
        threadCount: Int,
        busiestThreads: [CrumbThreadDiagnostic],
        gpuStatus: String,
        network: CrumbNetworkDiagnostic,
        logs: CrumbLogDiagnostic,
        stackTraces: CrumbStackTraceDiagnostic
    ) {
        self.capturedAt = capturedAt
        self.location = location
        self.processName = processName
        self.processID = processID
        self.cpuUsagePercent = cpuUsagePercent
        self.residentMemoryBytes = residentMemoryBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.thermalState = thermalState
        self.threadCount = threadCount
        self.busiestThreads = busiestThreads
        self.gpuStatus = gpuStatus
        self.network = network
        self.logs = logs
        self.stackTraces = stackTraces
    }
}
