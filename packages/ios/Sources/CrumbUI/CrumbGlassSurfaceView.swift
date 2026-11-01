#if canImport(UIKit)
import UIKit

/// A background material for the reporter's custom floating surfaces.
@MainActor
final class CrumbGlassSurfaceView: UIView {
    private let fallbackColor: UIColor
    private let isInteractive: Bool
    private let showsFallbackShadow: Bool
    private let materialView = UIVisualEffectView(effect: nil)

    /// Host controls here so UIKit can apply the material's vibrancy and touch response.
    var contentView: UIView { materialView.contentView }

    init(fallbackColor: UIColor, isInteractive: Bool = false, showsFallbackShadow: Bool = false) {
        self.fallbackColor = fallbackColor
        self.isInteractive = isInteractive
        self.showsFallbackShadow = showsFallbackShadow
        super.init(frame: .zero)
        isOpaque = false
        materialView.isOpaque = false
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMaterial),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
        updateMaterial()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            materialView.cornerConfiguration = .corners(radius: .fixed(layer.cornerRadius))
            return
        }
        #endif
        materialView.layer.cornerRadius = layer.cornerRadius
        materialView.layer.cornerCurve = layer.cornerCurve
    }

    @objc private func updateMaterial() {
        // Older SDKs can still build the iOS 15-compatible fallback.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *),
           !UIAccessibility.isReduceTransparencyEnabled,
           Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool != true {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = isInteractive
            materialView.effect = glass
            backgroundColor = .clear
            // The native material draws its own edge and depth. Clipping its
            // wrapper or adding the old card shadow flattens that appearance.
            clipsToBounds = false
            materialView.clipsToBounds = false
            layer.shadowOpacity = 0
            return
        }
        #endif
        materialView.effect = nil
        // The content container stays visible and interactive with no effect.
        clipsToBounds = false
        materialView.clipsToBounds = true
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? fallbackColor.withAlphaComponent(1)
            : fallbackColor
        layer.shadowColor = CrumbDesign.Color.ink.cgColor
        layer.shadowOpacity = showsFallbackShadow ? 0.16 : 0
        layer.shadowRadius = 17
        layer.shadowOffset = CGSize(width: 0, height: 12)
    }
}
#endif
