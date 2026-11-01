import Foundation
import Testing
@testable import CrumbCore

struct CrumbQueueOwnerFingerprintTests {
    @Test
    func matchesTheVersionedUtf8FramingVectors() throws {
        let destination = try #require(URL(string: "https://ingestion.example.invalid/base"))

        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_write_key", ingestionURL: destination)
            == "82ceb1c04d3054205b81c7ba7e5e73811d182b2e5793e5bac5afda3590802629")
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key_☃", ingestionURL: destination)
            == "c53bbbd95a08bd9a3e752264e981be5e9bd1c03e404b81841a89aa6e4a10fec9")
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_write_key", ingestionURL: nil)
            == "7ce7a235c1c39847d6b35e91ba5f90846ee4b4ef5ae4c59c488adbf876ff21b9")
    }

    @Test(arguments: [
        "HTTPS://INGESTION.EXAMPLE.INVALID:443/base/",
        "https://ingestion.example.invalid/base/",
        "https://ingestion.example.invalid/base"
    ])
    func normalizesEquivalentDestinations(value: String) throws {
        let destination = try #require(URL(string: value))
        let canonical = try #require(URL(string: "https://ingestion.example.invalid/base"))

        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: destination)
            == CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: canonical))
    }

    @Test
    func preservesPathCaseEncodedSeparatorsAndNonDefaultPorts() throws {
        let base = try #require(URL(string: "https://ingestion.example.invalid/base"))
        let expected = CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: base)
        for value in [
            "https://ingestion.example.invalid/Base", "https://ingestion.example.invalid/base%2Fchild",
            "https://ingestion.example.invalid/base/child", "https://ingestion.example.invalid:8443/base",
            "http://ingestion.example.invalid/base"
        ] {
            #expect(CrumbQueueOwnerFingerprint.make(
                projectKey: "synthetic_key", ingestionURL: try #require(URL(string: value))
            ) != expected)
        }
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "replacement_key", ingestionURL: base) != expected)
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: nil) != expected)
        let encoded = try #require(URL(string: "https://ingestion.example.invalid/base%2Fchild"))
        let separator = try #require(URL(string: "https://ingestion.example.invalid/base/child"))
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: encoded)
            != CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: separator))
    }

    @Test
    func preservesRepeatedTrailingSeparatorsWhenTheTransportPreservesThem() throws {
        let base = try #require(URL(string: "https://ingestion.example.invalid/api"))
        let repeated = try #require(URL(string: "https://ingestion.example.invalid/api//"))
        #expect(base.appendingPathComponent("sdk").path != repeated.appendingPathComponent("sdk").path)
        #expect(CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: base)
            != CrumbQueueOwnerFingerprint.make(projectKey: "synthetic_key", ingestionURL: repeated))
    }
}
