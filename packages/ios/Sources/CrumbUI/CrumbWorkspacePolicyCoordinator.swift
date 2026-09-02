import CrumbCore
#if canImport(UIKit)
import Foundation
import UIKit

/// Loads only the small, versioned privacy policy document. The request is
/// best-effort and never delays reporter presentation or local report saving.
@MainActor
final class CrumbWorkspacePolicyCoordinator {
    static let shared = CrumbWorkspacePolicyCoordinator()

    private var isInstalled = false
    private var fetchTask: Task<Void, Never>?

    private init() {}

    func install() {
        guard !isInstalled else {
            refresh()
            return
        }
        isInstalled = true
        loadCachedPolicy()
        refresh()
    }

    func refresh() {
        guard fetchTask == nil,
              let settings = try? Crumb.workspacePolicyFetchSettings(),
              let settings else {
            return
        }
        Crumb.beginWorkspacePolicyFetch()
        fetchTask = Task { [weak self] in
            await self?.fetch(settings)
        }
    }

    private func loadCachedPolicy() {
        guard let key = try? Crumb.workspacePolicyCacheKey(),
              let data = UserDefaults.standard.data(forKey: key) else {
            Crumb.markWorkspacePolicyUnavailable()
            return
        }
        guard let policy = CrumbPolicyCache.load(data: data) else {
            UserDefaults.standard.removeObject(forKey: key)
            Crumb.markWorkspacePolicyUnavailable()
            return
        }
        Crumb.applyWorkspacePolicy(policy, source: .cached)
    }

    private func fetch(_ settings: CrumbPolicyFetchSettings) async {
        defer { fetchTask = nil }
        var request = URLRequest(
            url: settings.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: settings.timeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(settings.projectKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count <= CrumbPolicyCache.maximumBytes,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw PolicyFetchError.invalidResponse
            }
            let policy = try CrumbWorkspacePolicy.decode(data)
            let accepted = Crumb.applyWorkspacePolicy(policy, source: .fresh)
            if accepted, let key = try? Crumb.workspacePolicyCacheKey() {
                UserDefaults.standard.set(data, forKey: key)
            }
        } catch is CancellationError {
            return
        } catch {
            Crumb.markWorkspacePolicyUnavailable()
        }
    }
}

private enum PolicyFetchError: Error {
    case invalidResponse
}
#endif
