/// Decides when an upload pass may start.
///
/// A pass reads the queue once, before it begins uploading, so a report that is
/// committed while the pass is in flight cannot be part of it. Dropping the wake
/// request raised by that commit would leave the report waiting for the next
/// foreground transition, so the request is remembered and honored when the
/// running pass completes.
///
/// Kept free of UIKit and networking so foreground gating and wake coalescing
/// are testable on any host.
struct CrumbUploadPassScheduler: Equatable, Sendable {
    private(set) var isForeground = false
    private(set) var isRunning = false
    private(set) var isWakeRequested = false

    mutating func enterForeground() {
        isForeground = true
    }

    mutating func leaveForeground() {
        isForeground = false
        isWakeRequested = false
    }

    /// Returns `true` when the caller should start a pass now. A request raised
    /// while a pass is running is remembered instead; repeated requests during
    /// one pass coalesce into a single follow-up pass.
    mutating func requestWake() -> Bool {
        guard isForeground else { return false }
        guard !isRunning else {
            isWakeRequested = true
            return false
        }
        isWakeRequested = false
        isRunning = true
        return true
    }

    /// Returns `true` when a request arrived during the pass that just finished
    /// and the SDK is still in the foreground.
    mutating func passDidFinish() -> Bool {
        isRunning = false
        let pending = isWakeRequested && isForeground
        isWakeRequested = false
        return pending
    }
}
