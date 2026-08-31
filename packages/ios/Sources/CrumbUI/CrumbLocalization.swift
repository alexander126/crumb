import Foundation

private final class CrumbLocalizationBundleToken {}

private let crumbLocalizationBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    let containingBundle = Bundle(for: CrumbLocalizationBundleToken.self)
    let candidates = [containingBundle, Bundle.main]
    for candidate in candidates {
        if let url = candidate.url(forResource: "CrumbUI", withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
    }
    return containingBundle
#endif
}()

func crumbLocalized(_ key: String) -> String {
    crumbLocalizationBundle.localizedString(forKey: key, value: key, table: nil)
}
