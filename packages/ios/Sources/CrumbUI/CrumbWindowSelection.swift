import Foundation

/// Chooses the window the reporter presents in — and therefore the window the
/// screenshot comes from.
///
/// `UIApplication.connectedScenes` includes inactive and background scenes, and
/// `isKeyWindow` is per scene rather than per application, so picking the first
/// key window across all scenes can resolve to a window the user is not looking
/// at. On iPad with two windows of the same app, Stage Manager, an external
/// display or a CarPlay scene, that would attach a screenshot of content the
/// user never chose to send.
///
/// Expressed over abstract scenes so the rule is testable without UIKit.
enum CrumbWindowSelection {
    /// Returns the window to present in, or nil when no scene is
    /// foreground-active. A caller that gets nil must decline to present rather
    /// than fall back to an arbitrary window.
    static func presentationWindow<Window>(
        scenes: [(isForegroundActive: Bool, windows: [Window])],
        isKeyWindow: (Window) -> Bool
    ) -> Window? {
        let active = scenes.filter(\.isForegroundActive)
        for scene in active {
            if let key = scene.windows.first(where: isKeyWindow) { return key }
        }
        // An active scene with no key window is still the right scene to
        // present in; an inactive scene never is.
        return active.lazy.flatMap(\.windows).first
    }
}
