import CrumbCore
#if canImport(UIKit) && canImport(CoreMotion)
import CoreMotion
import UIKit

public extension Crumb {
    /// Installs foreground-only automatic reporter invocation. Call once after `start`.
    @MainActor
    @discardableResult
    static func installReporter() -> Bool {
        CrumbReporterLifecycle.shared.install()
    }
}

@MainActor
final class CrumbReporterLifecycle: NSObject {
    static let shared = CrumbReporterLifecycle()

    private let motionManager = CMMotionManager()
    private var recognizer = CrumbShakeGestureRecognizer()
    private var sampleTimer: Timer?
    private var isInstalled = false

    func install() -> Bool {
        guard (try? Crumb.reportSettings()) != nil else { return false }
        guard !isInstalled else {
            startShakeMonitoringIfNeeded()
            return true
        }

        isInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        Task {
            try? await CrumbReportQueue.shared.recoverInterruptedUploads()
        }
        CrumbUploadCoordinator.shared.resume()
        startShakeMonitoringIfNeeded()
        return true
    }

    func reporterPresentationDidBegin() {
        stopShakeMonitoring()
    }

    func reporterPresentationDidEnd() {
        startShakeMonitoringIfNeeded()
    }

    func reportDidQueue() {
        CrumbUploadCoordinator.shared.reportDidQueue()
    }

    @objc private func applicationDidBecomeActive() {
        CrumbUploadCoordinator.shared.resume()
        startShakeMonitoringIfNeeded()
    }

    @objc private func applicationWillResignActive() {
        CrumbUploadCoordinator.shared.pause()
        stopShakeMonitoring()
    }

    private func startShakeMonitoringIfNeeded() {
        guard isInstalled,
              UIApplication.shared.applicationState == .active,
              let settings = try? Crumb.reportSettings(),
              settings.invocation.contains(.shake),
              motionManager.isAccelerometerAvailable,
              sampleTimer == nil else {
            return
        }

        recognizer.reset()
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleMotion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func stopShakeMonitoring() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        motionManager.stopAccelerometerUpdates()
        recognizer.reset()
    }

    private func sampleMotion() {
        guard let acceleration = motionManager.accelerometerData?.acceleration else { return }
        let didShake = recognizer.record(
            accelerationX: acceleration.x,
            y: acceleration.y,
            z: acceleration.z,
            at: ProcessInfo.processInfo.systemUptime
        )
        if didShake {
            Crumb.show(trigger: .shake)
        }
    }
}
#endif
