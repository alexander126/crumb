import CrumbCore
#if canImport(Network)
import Foundation
import Network

@MainActor
final class CrumbUploadCoordinator {
    static let shared = CrumbUploadCoordinator()

    private let monitorQueue = DispatchQueue(label: "dev.crumb.upload-connectivity")
    private var worker: CrumbReportUploadWorker?
    private(set) var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var retryStep = 0
    private var isForeground = false
    private var foregroundRetryRequested = false
    private(set) var connectivityGeneration = 0
    private let observesConnectivity: Bool

    init(worker: CrumbReportUploadWorker? = nil, observesConnectivity: Bool = true) {
        self.worker = worker
        self.observesConnectivity = observesConnectivity
    }

    func resume() {
        if !isForeground { foregroundRetryRequested = true }
        isForeground = true
        wake()
    }

    func pause() {
        isForeground = false
        foregroundRetryRequested = false
        retryTask?.cancel()
        retryTask = nil
        uploadTask?.cancel()
        stopConnectivityMonitoring()
    }

    func reportDidQueue() {
        wake()
    }

    private func wake() {
        guard isForeground else { return }
        if worker == nil {
            guard let settings = try? Crumb.uploadSettings() else { return }
            worker = CrumbReportUploadWorker(settings: settings)
        }
        guard let worker else { return }

        startConnectivityMonitoring()
        guard uploadTask == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        let retryTerminalReports = foregroundRetryRequested
        foregroundRetryRequested = false
        uploadTask = Task { [weak self] in
            if retryTerminalReports { await worker.prepareForForegroundPass() }
            let result = await worker.runPass()
            guard let self else { return }
            self.uploadTask = nil
            self.handle(result)
        }
    }

    private func handle(_ result: CrumbUploadPassResult) {
        guard isForeground else { return }
        if foregroundRetryRequested {
            wake()
            return
        }
        if result.remainingReportCount == 0 {
            retryStep = 0
            stopConnectivityMonitoring()
            return
        }
        if result.wasCancelled {
            wake()
        } else if result.shouldRetry {
            scheduleRetry()
        } else {
            // Permanent failures remain durable, but do not consume battery in a retry loop.
            stopConnectivityMonitoring()
        }
    }

    private func scheduleRetry() {
        let delays: [UInt64] = [1, 2, 4, 8, 16, 32, 60]
        let seconds = delays[min(retryStep, delays.count - 1)]
        retryStep = min(retryStep + 1, delays.count - 1)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.retryTask = nil
            self.wake()
        }
    }

    private func startConnectivityMonitoring() {
        guard observesConnectivity, pathMonitor == nil else { return }
        connectivityGeneration += 1
        let generation = connectivityGeneration
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                self?.connectivityDidBecomeAvailable(generation: generation)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: monitorQueue)
    }

    private func stopConnectivityMonitoring() {
        connectivityGeneration += 1
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func connectivityDidBecomeAvailable(generation: Int) {
        guard isForeground, generation == connectivityGeneration else { return }
        retryStep = 0
        retryTask?.cancel()
        retryTask = nil
        wake()
    }
}
#endif
