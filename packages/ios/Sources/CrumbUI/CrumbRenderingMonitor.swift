#if canImport(UIKit)
import UIKit
import CrumbCore

@MainActor
final class CrumbRenderingMonitor: NSObject {
    static let shared = CrumbRenderingMonitor()
    private var link: CADisplayLink?
    private var previousBudget = 0.0
    private var previous: Double?
    private var installed = false
    func install() {
        guard !installed, (try? Crumb.reportSettings().diagnostics.renderingEnabled) == true else { return }
        installed = true
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pause), name: UIApplication.willResignActiveNotification, object: nil)
        if UIApplication.shared.applicationState == .active { resume() }
    }
    @objc private func resume() {
        guard link == nil else { return }
        previous = nil
        let next = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link = next; next.add(to: .main, forMode: .common)
    }
    @objc private func pause() {
        link?.invalidate(); link = nil; previous = nil; CrumbRenderingBuffer.shared.clear()
    }
    @objc private func tick(_ sender: CADisplayLink) {
        guard let settings = try? Crumb.reportSettings(), settings.diagnostics.renderingEnabled,
              settings.evidence.contains(.performance) else {
            previous = nil; CrumbRenderingBuffer.shared.clear(); return
        }
        defer { previous = sender.timestamp; previousBudget = (sender.targetTimestamp - sender.timestamp) * 1000 }
        guard let previous else { return }
        CrumbRenderingBuffer.shared.record(now: ProcessInfo.processInfo.systemUptime,
            frameMs: (sender.timestamp - previous) * 1000,
            budgetMs: previousBudget)
    }
}
#endif
