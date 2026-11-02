import Testing
@testable import CrumbUI

private struct FakeWindow: Equatable {
    let name: String
    let isKey: Bool
}

struct CrumbWindowSelectionTests {
    /// The defect this fixes: selection took the first key window across every
    /// connected scene. `isKeyWindow` is per scene, so a background or inactive
    /// scene's key window could win — and the screenshot is taken from whatever
    /// window is chosen.
    @Test
    func aBackgroundScenesKeyWindowIsNeverChosen() {
        let scenes = [
            (isForegroundActive: false, windows: [FakeWindow(name: "background", isKey: true)]),
            (isForegroundActive: true, windows: [FakeWindow(name: "active", isKey: true)])
        ]
        let legacy = scenes.flatMap(\.windows).first { $0.isKey }

        let selected = CrumbWindowSelection.presentationWindow(
            scenes: scenes,
            isKeyWindow: \.isKey
        )

        #expect(legacy?.name == "background")
        #expect(selected?.name == "active")
    }

    @Test
    func orderAmongScenesDoesNotDecideTheOutcome() {
        let selected = CrumbWindowSelection.presentationWindow(
            scenes: [
                (isForegroundActive: true, windows: [FakeWindow(name: "active", isKey: true)]),
                (isForegroundActive: false, windows: [FakeWindow(name: "inactive", isKey: true)])
            ],
            isKeyWindow: \.isKey
        )

        #expect(selected?.name == "active")
    }

    @Test
    func noForegroundActiveSceneSelectsNothing() {
        let selected = CrumbWindowSelection.presentationWindow(
            scenes: [
                (isForegroundActive: false, windows: [FakeWindow(name: "background", isKey: true)]),
                (isForegroundActive: false, windows: [FakeWindow(name: "inactive", isKey: false)])
            ],
            isKeyWindow: \.isKey
        )

        #expect(selected == nil)
    }

    /// An active scene is still the right scene even when nothing reports as key.
    @Test
    func anActiveSceneWithoutAKeyWindowStillWins() {
        let selected = CrumbWindowSelection.presentationWindow(
            scenes: [
                (isForegroundActive: false, windows: [FakeWindow(name: "background", isKey: true)]),
                (isForegroundActive: true, windows: [FakeWindow(name: "active-first", isKey: false)])
            ],
            isKeyWindow: \.isKey
        )

        #expect(selected?.name == "active-first")
    }

    @Test
    func aSingleSceneApplicationIsUnchanged() {
        let selected = CrumbWindowSelection.presentationWindow(
            scenes: [
                (
                    isForegroundActive: true,
                    windows: [
                        FakeWindow(name: "secondary", isKey: false),
                        FakeWindow(name: "key", isKey: true)
                    ]
                )
            ],
            isKeyWindow: \.isKey
        )

        #expect(selected?.name == "key")
    }

    @Test
    func noScenesSelectNothing() {
        let selected = CrumbWindowSelection.presentationWindow(
            scenes: [] as [(isForegroundActive: Bool, windows: [FakeWindow])],
            isKeyWindow: \.isKey
        )

        #expect(selected == nil)
    }
}
