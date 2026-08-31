import CrumbCore
#if canImport(UIKit) && canImport(Network)
import Network
import UIKit

@MainActor
final class CrumbUploadCoordinator {
    static let shared = CrumbUploadCoordinator()

    private let monitorQueue = DispatchQueue(label: "dev.crumb.upload-connectivity")
    private var worker: CrumbReportUploadWorker?
    private var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var retryStep = 0
    private var isForeground = false

    private init() {}

    func resume() {
        isForeground = true
        wake()
    }

    func pause() {
        isForeground = false
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
        uploadTask = Task { [weak self] in
            let result = await worker.runPass()
            guard let self else { return }
            self.uploadTask = nil
            self.handle(result)
        }
    }

    private func handle(_ result: CrumbUploadPassResult) {
        if result.remainingReportCount == 0 {
            retryStep = 0
            stopConnectivityMonitoring()
            return
        }
        guard isForeground else { return }
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
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isForeground else { return }
                self.retryStep = 0
                self.retryTask?.cancel()
                self.retryTask = nil
                self.wake()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: monitorQueue)
    }

    private func stopConnectivityMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}
#endif
