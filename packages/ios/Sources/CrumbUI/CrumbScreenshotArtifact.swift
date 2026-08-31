import CrumbCore
#if canImport(UIKit)
import CryptoKit
import ObjectiveC
import UIKit

private enum CrumbScreenshotMaskAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}

public extension UIView {
    /// Marks this view's visible bounds as an opaque region in Crumb screenshots.
    var crumbMaskInScreenshots: Bool {
        get {
            (objc_getAssociatedObject(self, &CrumbScreenshotMaskAssociation.key) as? Bool) == true
        }
        set {
            objc_setAssociatedObject(
                self,
                &CrumbScreenshotMaskAssociation.key,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

package struct CrumbScreenshotArtifact {
    package let preview: UIImage
    package let encodedData: Data
    package let manifest: CrumbArtifactManifest
    package let maskingState: CrumbScreenshotMaskingState
}

@MainActor
package enum CrumbScreenshotArtifactPipeline {
    package static func capture(
        window: UIWindow,
        capture: CrumbCaptureOptions,
        privacy: CrumbPrivacyOptions
    ) -> CrumbScreenshotArtifact? {
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }

        let maskViews = sensitiveViews(
            in: window,
            includeTextInputs: privacy.maskAllTextInputs
        )
        let maskingConfigured = privacy.maskScreenshotsBeforeUpload
            || privacy.maskAllTextInputs
            || !maskViews.isEmpty

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { renderer in
            window.layer.render(in: renderer.cgContext)
            renderer.cgContext.setFillColor(UIColor.black.cgColor)
            for view in maskViews where isVisible(view) {
                let frame = view.convert(view.bounds, to: window)
                    .insetBy(dx: -3, dy: -3)
                    .intersection(window.bounds)
                guard !frame.isNull, !frame.isEmpty else { continue }
                renderer.cgContext.fill(frame)
            }
        }

        guard let encoded = encode(
            rendered,
            maximumDimension: capture.maximumScreenshotDimension,
            maximumBytes: capture.maximumScreenshotBytes
        ) else { return nil }

        let digest = SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let maskingState: CrumbScreenshotMaskingState = maskingConfigured ? .applied : .notApplicable
        return CrumbScreenshotArtifact(
            preview: encoded.image,
            encodedData: encoded.data,
            manifest: CrumbArtifactManifest(
                id: "art_\(token)",
                kind: "screenshot",
                mimeType: "image/png",
                byteSize: encoded.data.count,
                sha256: digest,
                redactionState: maskingConfigured ? "masked" : "not_applicable",
                uploadID: "upl_\(token)"
            ),
            maskingState: maskingState
        )
    }

    private static func sensitiveViews(
        in view: UIView,
        includeTextInputs: Bool
    ) -> [UIView] {
        var matches: [UIView] = []
        if view.crumbMaskInScreenshots
            || (includeTextInputs && (view is UITextField || view is UITextView)) {
            matches.append(view)
        }
        for child in view.subviews {
            matches.append(contentsOf: sensitiveViews(in: child, includeTextInputs: includeTextInputs))
        }
        return matches
    }

    private static func isVisible(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0 && view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
    }

    private static func encode(
        _ image: UIImage,
        maximumDimension: Int,
        maximumBytes: Int
    ) -> (image: UIImage, data: Data)? {
        var current = resized(image, maximumDimension: maximumDimension)
        for _ in 0..<10 {
            guard let data = current.pngData() else { return nil }
            if data.count <= maximumBytes {
                return (current, data)
            }

            let pixelSize = pixels(of: current)
            guard pixelSize.width > 160, pixelSize.height > 160 else { return nil }
            let ratio = sqrt(Double(maximumBytes) / Double(data.count)) * 0.9
            let nextMaximum = max(160, Int(max(pixelSize.width, pixelSize.height) * min(0.9, ratio)))
            guard nextMaximum < Int(max(pixelSize.width, pixelSize.height)) else { return nil }
            current = resized(current, maximumDimension: nextMaximum)
        }
        return nil
    }

    private static func resized(_ image: UIImage, maximumDimension: Int) -> UIImage {
        let pixelSize = pixels(of: image)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > CGFloat(maximumDimension) else { return image }

        let scale = CGFloat(maximumDimension) / longest
        let target = CGSize(
            width: max(1, floor(pixelSize.width * scale)),
            height: max(1, floor(pixelSize.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func pixels(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}

#if canImport(SwiftUI)
import SwiftUI

public extension SwiftUI.View {
    /// Marks this SwiftUI view's rendered bounds as an opaque region in Crumb screenshots.
    func crumbMaskInScreenshots(_ masked: Bool = true) -> some SwiftUI.View {
        overlay(CrumbScreenshotMaskRegion(masked: masked).allowsHitTesting(false))
    }
}

private struct CrumbScreenshotMaskRegion: UIViewRepresentable {
    let masked: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.isUserInteractionEnabled = false
        view.crumbMaskInScreenshots = masked
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.crumbMaskInScreenshots = masked
    }
}
#endif
#endif
