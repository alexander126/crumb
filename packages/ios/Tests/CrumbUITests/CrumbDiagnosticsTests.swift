#if os(iOS)
import CrumbCore
import Testing
@testable import CrumbUI

struct CrumbDiagnosticsTests {
    @Test
    func disabledPerformanceRemainsUnavailable() {
        let diagnostics = OnDemandDiagnosticsCollector.capture(
            location: "TestViewController",
            options: CrumbDiagnosticsOptions(),
            evidence: []
        )

        #expect(diagnostics.cpuUsagePercent == nil)
        #expect(diagnostics.threadCount == 0)
        #expect(diagnostics.thermalState == "unavailable_by_policy")
    }
}
#endif
