import CrumbCore
import Foundation

struct DemoCrumbConfiguration {
    let crumb: CrumbConfiguration
    let modeDescription: String

    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> DemoCrumbConfiguration {
        let projectKey = resolvedValue(
            environment["CRUMB_DOGFOOD_PROJECT_KEY"],
            bundle.object(forInfoDictionaryKey: "CrumbDogfoodProjectKey") as? String
        )
        let ingestionValue = resolvedValue(
            environment["CRUMB_DOGFOOD_INGESTION_URL"],
            bundle.object(forInfoDictionaryKey: "CrumbDogfoodIngestionURL") as? String
        )
        let configuredEnvironment = resolvedValue(
            environment["CRUMB_DOGFOOD_ENVIRONMENT"],
            bundle.object(forInfoDictionaryKey: "CrumbDogfoodEnvironment") as? String
        )
        let ingestionURL = ingestionValue.flatMap(validHTTPURL)
        let uploadEnabled = projectKey != nil && ingestionURL != nil
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let nativeBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        return DemoCrumbConfiguration(
            crumb: CrumbConfiguration(
                projectKey: uploadEnabled ? (projectKey ?? "poc_write_key") : "poc_write_key",
                environment: uploadEnabled ? (configuredEnvironment ?? "staging") : "local",
                release: CrumbRelease(
                    appVersion: appVersion ?? "0.1.0",
                    nativeBuild: nativeBuild ?? "1"
                ),
                diagnostics: CrumbDiagnosticsOptions(
                    healthCheckURL: uploadEnabled ? ingestionURL?.appendingPathComponent("health") : nil
                ),
                upload: CrumbUploadOptions(ingestionURL: uploadEnabled ? ingestionURL : nil)
            ),
            modeDescription: uploadEnabled ? "Staging upload enabled" : "Local-only mode"
        )
    }

    private static func resolvedValue(_ candidates: String?...) -> String? {
        candidates.lazy.compactMap { candidate in
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !value.contains("$(") else { return nil }
            return value
        }.first
    }

    private static func validHTTPURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}
