#if canImport(UIKit)
import UIKit

/// A background material for the reporter's custom floating surfaces.
@MainActor
final class CrumbGlassSurfaceView: UIView {
    private let fallbackColor: UIColor
    private let materialView = UIVisualEffectView(effect: nil)

    init(fallbackColor: UIColor) {
        self.fallbackColor = fallbackColor
        super.init(frame: .zero)
        clipsToBounds = true
        materialView.isUserInteractionEnabled = false
        materialView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(materialView)
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
        materialView.frame = bounds
        materialView.layer.cornerRadius = layer.cornerRadius
        materialView.layer.cornerCurve = layer.cornerCurve
    }

    @objc private func updateMaterial() {
        // Older SDKs can still build the iOS 15-compatible fallback.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *),
           !UIAccessibility.isReduceTransparencyEnabled,
           Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool != true {
            materialView.effect = UIGlassEffect(style: .regular)
            materialView.isHidden = false
            backgroundColor = .clear
            return
        }
        #endif
        materialView.effect = nil
        materialView.isHidden = true
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? fallbackColor.withAlphaComponent(1)
            : fallbackColor
    }
}
#endif
