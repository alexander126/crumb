import Foundation

/// An explicitly supplied static screen name and focused route hierarchy, never navigation history.
public struct CrumbScreenContext: Codable, Equatable, Sendable {
    public let name: String
    public let route: [String]
    public let source: String

    package func validated() -> Self? {
        func valid(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                value.utf8.count <= 128 && !value.contains("://") &&
                !value.contains("?") && !value.contains("#") &&
                value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard ["manual", "react_navigation", "expo_router"].contains(source),
              valid(name), !route.isEmpty, route.count <= 8, route.allSatisfy(valid) else { return nil }
        let cleanName = CrumbLogSanitizer.sanitize(name)
        let cleanRoute = route.map { CrumbLogSanitizer.sanitize($0) }
        guard valid(cleanName), cleanRoute.allSatisfy(valid) else { return nil }
        return Self(name: cleanName, route: cleanRoute, source: source)
    }

    package static func decode(_ json: String) -> Self? {
        guard json.utf8.count <= 2048, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return value.validated()
    }
}
