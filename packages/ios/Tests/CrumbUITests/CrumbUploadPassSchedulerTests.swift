import Testing
@testable import CrumbUI

struct CrumbUploadPassSchedulerTests {
    @Test
    func aWakeWhileIdleStartsAPass() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()

        let started = scheduler.requestWake()

        #expect(started)
        #expect(scheduler.isRunning)
    }

    /// The defect this fixes: the request raised by a report committed during a
    /// running pass was dropped, and the pass already in flight had taken its
    /// queue snapshot before that report existed.
    @Test
    func aWakeDuringAPassIsHonoredWhenThePassFinishes() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()
        let firstPassStarted = scheduler.requestWake()

        let secondPassStarted = scheduler.requestWake()
        let wasRemembered = scheduler.isWakeRequested
        let restarts = scheduler.passDidFinish()
        let followUpStarted = scheduler.requestWake()

        #expect(firstPassStarted)
        #expect(secondPassStarted == false)
        #expect(wasRemembered)
        #expect(restarts)
        #expect(followUpStarted)
    }

    @Test
    func repeatedWakesDuringOnePassProduceExactlyOneFollowUpPass() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()
        _ = scheduler.requestWake()
        let duringPass = (0..<3).map { _ in scheduler.requestWake() }

        let restarts = scheduler.passDidFinish()
        let followUpStarted = scheduler.requestWake()
        let restartsAgain = scheduler.passDidFinish()

        #expect(duringPass.allSatisfy { $0 == false })
        #expect(restarts)
        #expect(followUpStarted)
        #expect(restartsAgain == false)
    }

    @Test
    func aPassWithNoPendingRequestDoesNotRestart() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()
        _ = scheduler.requestWake()

        let restarts = scheduler.passDidFinish()

        #expect(restarts == false)
        #expect(scheduler.isRunning == false)
        #expect(scheduler.isWakeRequested == false)
    }

    @Test
    func aWakeWhileBackgroundedStartsNothing() {
        var scheduler = CrumbUploadPassScheduler()

        let started = scheduler.requestWake()

        #expect(started == false)
        #expect(scheduler.isRunning == false)
        #expect(scheduler.isWakeRequested == false)
    }

    @Test
    func leavingTheForegroundClearsAPendingRequest() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()
        _ = scheduler.requestWake()
        _ = scheduler.requestWake()

        scheduler.leaveForeground()
        let restarts = scheduler.passDidFinish()

        #expect(scheduler.isWakeRequested == false)
        #expect(restarts == false)
    }

    @Test
    func returningToTheForegroundStartsAPassAgain() {
        var scheduler = CrumbUploadPassScheduler()
        scheduler.enterForeground()
        _ = scheduler.requestWake()
        scheduler.leaveForeground()
        _ = scheduler.passDidFinish()

        scheduler.enterForeground()
        let started = scheduler.requestWake()

        #expect(started)
    }
}
