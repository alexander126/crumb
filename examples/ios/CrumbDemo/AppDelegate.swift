import CrumbCore
@_spi(Quality) import CrumbUI
import Darwin
import Foundation
import OSLog
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let logger = Logger(subsystem: "dev.crumb.nativepoc.ios", category: "lifecycle")
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let demoConfiguration = DemoCrumbConfiguration.make()
        do {
            try Crumb.start(demoConfiguration.crumb)
            if DemoQualityRecorder.isEnabled {
                CrumbQualityInstrumentation.observe { event in
                    DemoQualityRecorder.shared.record(event)
                }
                DemoQualityRecorder.shared.measureWarmStarts(configuration: demoConfiguration.crumb)
            }
            logger.notice("Crumb demo initialized in \(demoConfiguration.modeDescription, privacy: .public)")
        } catch {
            assertionFailure("Crumb failed to start: \(error)")
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        if ProcessInfo.processInfo.environment["CRUMB_TEST_APPEARANCE"] == "dark" {
            window.overrideUserInterfaceStyle = .dark
        }
        window.rootViewController = UINavigationController(
            rootViewController: MainViewController(modeDescription: demoConfiguration.modeDescription)
        )
        window.makeKeyAndVisible()
        self.window = window
        Crumb.installReporter()
        return true
    }
}

@MainActor
final class DemoQualityRecorder {
    static let shared = DemoQualityRecorder()
    static let isEnabled = ProcessInfo.processInfo.environment["CRUMB_QUALITY_METRICS"] == "1"

    var onUpdate: ((String) -> Void)?
    private var startSamples: [Double] = []
    private var samples: [CrumbQualityEventKind: [Double]] = [:]
    private var memoryBaseline: UInt64?
    private var memoryGeneration = 0
    private var retainedMemoryBytes: UInt64?

    func measureWarmStarts(configuration: CrumbConfiguration) {
        startSamples = (0..<20).compactMap { _ in
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try Crumb.start(configuration)
                return Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            } catch {
                return nil
            }
        }
        publish()
    }

    func beginReport() {
        memoryGeneration += 1
        retainedMemoryBytes = nil
        memoryBaseline = Self.residentMemoryBytes()
        publish()
    }

    func record(_ event: CrumbQualityEvent) {
        samples[event.kind, default: []].append(event.elapsedMilliseconds)
        if event.kind == .reporterClosed {
            let generation = memoryGeneration
            let baseline = memoryBaseline
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.memoryGeneration == generation,
                      let baseline, let current = Self.residentMemoryBytes() else { return }
                self.retainedMemoryBytes = current > baseline ? current - baseline : 0
                self.publish()
            }
        }
        publish()
    }

    var summary: String {
        let form = Array(samples[.formReady, default: []].prefix(20))
        let diagnostics = Array(samples[.diagnosticsReady, default: []].prefix(20))
        let screenshot = Array(samples[.screenshotReady, default: []].prefix(20))
        return [
            "start_p50=\(percentile(startSamples, 0.50))",
            "start_p95=\(percentile(startSamples, 0.95))",
            "form_p50=\(percentile(form, 0.50))",
            "form_p95=\(percentile(form, 0.95))",
            "diagnostics_p50=\(percentile(diagnostics, 0.50))",
            "diagnostics_p95=\(percentile(diagnostics, 0.95))",
            "screenshot_p50=\(percentile(screenshot, 0.50))",
            "screenshot_p95=\(percentile(screenshot, 0.95))",
            "retained_bytes=\(retainedMemoryBytes.map(String.init) ?? "pending")"
        ].joined(separator: " ")
    }

    private func publish() {
        onUpdate?(summary)
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
}
