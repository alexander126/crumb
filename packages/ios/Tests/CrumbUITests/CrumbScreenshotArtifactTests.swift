#if canImport(UIKit)
import CryptoKit
import CrumbCore
import Testing
import UIKit
@testable import CrumbUI

struct CrumbScreenshotArtifactTests {
    @MainActor
    @Test
    func customMaskIsAppliedBeforeTheBoundedPngIsHashed() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 480))
        let host = UIViewController()
        host.view.backgroundColor = .systemRed
        let sensitive = UIView(frame: CGRect(x: 40, y: 120, width: 160, height: 80))
        sensitive.backgroundColor = .systemGreen
        sensitive.crumbMaskInScreenshots = true
        host.view.addSubview(sensitive)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let artifact = try #require(CrumbScreenshotArtifactPipeline.capture(
            window: window,
            capture: CrumbCaptureOptions(
                maximumScreenshotDimension: 320,
                maximumScreenshotBytes: 262_144
            ),
            privacy: CrumbPrivacyOptions(
                maskAllTextInputs: false,
                maskScreenshotsBeforeUpload: false
            )
        ))

        let cgImage = try #require(artifact.preview.cgImage)
        #expect(max(cgImage.width, cgImage.height) <= 320)
        #expect(artifact.encodedData.count <= 262_144)
        #expect(artifact.manifest.byteSize == artifact.encodedData.count)
        #expect(artifact.manifest.mimeType == "image/png")
        #expect(artifact.manifest.redactionState == "masked")
        #expect(artifact.maskingState == .applied)

        let digest = SHA256.hash(data: artifact.encodedData)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(artifact.manifest.sha256 == digest)

        let sample = sampleColor(
            in: artifact.preview,
            at: CGPoint(x: 120.0 / 1.5, y: 160.0 / 1.5)
        )
        #expect(sample.red < 0.03)
        #expect(sample.green < 0.03)
        #expect(sample.blue < 0.03)
        #expect(sample.alpha > 0.99)
    }

    @MainActor
    private func sampleColor(in image: UIImage, at point: CGPoint) -> ColorComponents {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let sampled = UIGraphicsImageRenderer(
            size: CGSize(width: 1, height: 1),
            format: format
        ).image { _ in
            image.draw(at: CGPoint(x: -point.x, y: -point.y))
        }
        let data = sampled.cgImage!.dataProvider!.data!
        let pixel = CFDataGetBytePtr(data)!
        return ColorComponents(
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255,
            alpha: Double(pixel[3]) / 255
        )
    }

    private struct ColorComponents {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }
}
#endif
