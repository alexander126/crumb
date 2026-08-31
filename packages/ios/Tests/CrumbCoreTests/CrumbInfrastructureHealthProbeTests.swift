import Foundation
import Testing
@testable import CrumbCore

struct CrumbInfrastructureHealthProbeTests {
    @Test
    func recordsAHealthyCrumbHeadResponse() throws {
        let url = try #require(URL(string: "https://ingestion.crumb.dev/health"))
        let diagnostic = CrumbInfrastructureHealthProbe.capture(
            url: url,
            timeout: 1.25
        ) { request, timeout in
            #expect(request.httpMethod == "HEAD")
            #expect(request.url == url)
            #expect(timeout == 1.25)
            return CrumbHealthHeadResult(
                statusCode: 204,
                latencyMilliseconds: 18,
                failure: nil
            )
        }

        #expect(diagnostic.host == "ingestion.crumb.dev")
        #expect(diagnostic.succeeded)
        #expect(diagnostic.statusCode == 204)
        #expect(diagnostic.latencyMilliseconds == 18)
        #expect(diagnostic.failure == nil)
    }

    @Test
    func turnsAnUnavailableCrumbApiIntoEvidenceInsteadOfAnError() throws {
        let url = try #require(URL(string: "https://ingestion.crumb.dev/health"))
        let diagnostic = CrumbInfrastructureHealthProbe.capture(
            url: url,
            timeout: 1.25
        ) { _, _ in
            CrumbHealthHeadResult(
                statusCode: nil,
                latencyMilliseconds: 1_250,
                failure: "timeout"
            )
        }

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.statusCode == nil)
        #expect(diagnostic.latencyMilliseconds == 1_250)
        #expect(diagnostic.failure == "timeout")
    }

    @Test
    func doesNotTreatAnUnhealthyHttpResponseAsSuccess() throws {
        let url = try #require(URL(string: "https://ingestion.crumb.dev/health"))
        let diagnostic = CrumbInfrastructureHealthProbe.capture(
            url: url,
            timeout: 1
        ) { _, _ in
            CrumbHealthHeadResult(statusCode: 503, latencyMilliseconds: 9, failure: nil)
        }

        #expect(!diagnostic.succeeded)
        #expect(diagnostic.statusCode == 503)
    }
}
