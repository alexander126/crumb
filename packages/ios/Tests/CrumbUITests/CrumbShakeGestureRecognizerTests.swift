import Testing
@testable import CrumbUI

struct CrumbShakeGestureRecognizerTests {
    @Test
    func requiresTwoHitsInsideWindow() {
        var recognizer = CrumbShakeGestureRecognizer()

        let firstHit = recognizer.record(linearMagnitudeG: 2.5, at: 1.0)
        let secondHit = recognizer.record(linearMagnitudeG: 2.5, at: 1.4)

        #expect(!firstHit)
        #expect(secondHit)
    }

    @Test
    func rejectsSeparatedHitsAndCooldownDuplicates() {
        var recognizer = CrumbShakeGestureRecognizer()

        let firstHit = recognizer.record(linearMagnitudeG: 2.5, at: 1.0)
        let separatedHit = recognizer.record(linearMagnitudeG: 2.5, at: 1.7)
        let firstTrigger = recognizer.record(linearMagnitudeG: 2.5, at: 1.9)
        let cooldownHit = recognizer.record(linearMagnitudeG: 2.5, at: 2.1)
        let cooldownDuplicate = recognizer.record(linearMagnitudeG: 2.5, at: 2.3)
        let postCooldownHit = recognizer.record(linearMagnitudeG: 2.5, at: 3.6)
        let secondTrigger = recognizer.record(linearMagnitudeG: 2.5, at: 3.8)

        #expect(!firstHit)
        #expect(!separatedHit)
        #expect(firstTrigger)
        #expect(!cooldownHit)
        #expect(!cooldownDuplicate)
        #expect(!postCooldownHit)
        #expect(secondTrigger)
    }

    @Test
    func ignoresSubThresholdMotion() {
        var recognizer = CrumbShakeGestureRecognizer()

        let first = recognizer.record(linearMagnitudeG: 1.9, at: 1.0)
        let second = recognizer.record(linearMagnitudeG: 2.1, at: 1.2)

        #expect(!first)
        #expect(!second)
    }
}
