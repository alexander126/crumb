#if canImport(UIKit)
import UIKit

@MainActor
enum CrumbDesign {
    enum Color {
        static let ink = UIColor(crumbLight: 0x16181D, dark: 0xF4F5F7)
        static let accent = UIColor(crumbLight: 0x0FB489, dark: 0x2DD4A7)
        static let accentDark = UIColor(crumbLight: 0x077056, dark: 0x72E2C1)
        static let actionFill = UIColor(crumbLight: 0x0FB489, dark: 0x2DD4A7)
        static let canvas = UIColor(crumbLight: 0xFBFBFD, dark: 0x121419)
        static let elevatedSurface = UIColor(crumbLight: 0xFFFFFF, dark: 0x191C22)
        static let surface = UIColor(crumbLight: 0xF7F8FB, dark: 0x191C22)
        static let mutedSurface = UIColor(crumbLight: 0xEEF0F5, dark: 0x22262E)
        static let readySurface = UIColor(crumbLight: 0xE4F6F0, dark: 0x18392F)
        static let divider = UIColor(crumbLight: 0xE4E6EC, dark: 0x323842)
        static let secondaryText = UIColor(crumbLight: 0x4C535F, dark: 0xB9C0CB)
        static let mutedText = UIColor(crumbLight: 0x6E7684, dark: 0xA3ACB9)
        static let tertiaryText = UIColor(crumbLight: 0x9AA1AE, dark: 0x8993A2)
        static let disabled = UIColor(crumbLight: 0xC6CBD5, dark: 0x59616D)
        static let danger = UIColor(crumbLight: 0xD2543C, dark: 0xFF8D78)
        static let paleDanger = UIColor(crumbLight: 0xFBEBE7, dark: 0x3A201B)
        static let warning = UIColor(crumbLight: 0x9A6500, dark: 0xF4C15D)
        static let paleWarning = UIColor(crumbLight: 0xFBF3E2, dark: 0x352B17)
        static let darkSurface = UIColor(crumbLight: 0x22252C, dark: 0x090B0F)
        static let textOnDark = UIColor(crumbLight: 0xD5D8E0, dark: 0xE4E7ED)
        static let markTile = UIColor(crumb: 0x16181D)
    }

    enum Spacing {
        static let page: CGFloat = 20
        static let section: CGFloat = 18
        static let row: CGFloat = 12
        static let compact: CGFloat = 8
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 12
        static let button: CGFloat = 14
    }

    static func sectionLabel(_ value: String) -> UILabel {
        let label = UILabel()
        label.text = value.uppercased()
        label.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        label.textColor = Color.mutedText
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func label(
        _ value: String? = nil,
        style: UIFont.TextStyle = .body,
        weight: UIFont.Weight = .regular,
        color: UIColor = Color.ink
    ) -> UILabel {
        let label = UILabel()
        label.text = value
        label.font = .preferredFont(forTextStyle: style).withWeight(weight)
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func statusDot(color: UIColor) -> UILabel {
        let dot = label("●", style: .caption1, color: color)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.accessibilityElementsHidden = true
        return dot
    }

    static func styleCard(
        _ view: UIView,
        fill: UIColor = Color.surface,
        border: UIColor = Color.divider
    ) {
        view.backgroundColor = fill
        view.layer.cornerRadius = Radius.card
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = border.cgColor
    }

    static func primaryButton(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = Color.actionFill
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = Radius.button
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
            return outgoing
        }
        return configuration
    }

    static func metadataLabel(_ value: String) -> UILabel {
        let label = UILabel()
        label.text = value.uppercased()
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedSystemFont(ofSize: 10, weight: .medium)
        )
        label.textColor = Color.tertiaryText
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func navigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Color.canvas
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: Color.ink,
            .font: UIFont.preferredFont(forTextStyle: .headline).withWeight(.semibold)
        ]
        return appearance
    }
}

private extension UIColor {
    convenience init(crumb hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }

    convenience init(crumbLight light: UInt32, dark: UInt32) {
        self.init { traits in
            UIColor(crumb: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = [UIFontDescriptor.TraitKey.weight: weight]
        let descriptor = fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
