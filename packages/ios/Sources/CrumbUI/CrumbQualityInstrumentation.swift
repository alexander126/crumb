import Foundation

public enum CrumbQualityEventKind: String, Sendable {
    case formReady
    case diagnosticsReady
    case screenshotReady
    case reporterClosed
}

public struct CrumbQualityEvent: Sendable {
    public let kind: CrumbQualityEventKind
    public let elapsedMilliseconds: Double
}

@MainActor
public enum CrumbQualityInstrumentation {
    private static var observer: ((CrumbQualityEvent) -> Void)?

    /// Intended for Crumb's release harness, not application analytics.
    @_spi(Quality)
    public static func observe(_ observer: ((CrumbQualityEvent) -> Void)?) {
        self.observer = observer
    }

    static func record(kind: CrumbQualityEventKind, startedAtNanoseconds: UInt64) {
        guard let observer else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAtNanoseconds) / 1_000_000
        observer(CrumbQualityEvent(kind: kind, elapsedMilliseconds: elapsed))
    }
}
