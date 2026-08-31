# Screenshot artifacts and masking

This contract defines the native `0.0.1` screenshot boundary. Screenshot
capture is explicit report-time behavior; Crumb never captures in the
background.

## Artifact pipeline

1. Capture the host window before any Crumb interface is presented.
2. Find automatic text-input regions and host-marked custom regions.
3. Paint every region with fully opaque pixels in the render buffer.
4. Downscale to the configured maximum pixel dimension.
5. PNG-encode within the configured byte limit.
6. Compute SHA-256 from those exact encoded bytes and create the T01 artifact
   manifest.

The unmasked render buffer is never encoded, previewed, stored, hashed, or
handed to transport. If a masked PNG cannot be produced within the limits,
Crumb drops the screenshot and records capture/masking as unavailable/failed.
It must never fall back to an unmasked artifact.

The safe defaults are a 2,048-pixel longest edge and 5 MiB encoded size.
Hosts may configure 320–4,096 pixels and 64 KiB–25 MiB. The reporter previews
the final encoded image, not the original render. Removing it clears both the
encoded bytes and its manifest while preserving the fact that capture was
enabled for the session.

## Custom masking interfaces

### UIKit

Set the public property on any host view whose visible bounds must be opaque:

```swift
paymentCardView.crumbMaskInScreenshots = true
```

`UITextField` and `UITextView` are masked automatically by default. A marked
container masks its whole rectangular bounds.

### SwiftUI

Apply the public modifier to the rendered region:

```swift
AccountNumberView()
    .crumbMaskInScreenshots()
```

The modifier installs a transparent UIKit marker over that view. The marker
does not receive touches or accessibility focus. Layout transforms outside a
view's rectangular rendered bounds are not tracked separately; mark a larger
container when necessary.

### Android Views

Kotlin hosts can mark any `View`:

```kotlin
accountNumberView.maskInCrumbScreenshots()
```

Java hosts use `CrumbScreenshotMasking.setMasked(view, true)`. `EditText` is
masked automatically by default. A marked container masks its whole
rectangular visible bounds.

### Compose

The `0.0.1` SDK does not take a Compose dependency. A host can mark the
containing `ComposeView` through the Android View interface, including a
smaller nested `ComposeView` dedicated to sensitive content. Per-composable
mask geometry is not supported in `0.0.1`; split sensitive content into a
marked `ComposeView` or disable screenshot capture.

### WebView

Crumb does not inspect DOM content or run JavaScript. Mark the entire
`WKWebView` or Android `WebView` with the platform view interface. Element-level
DOM masking is outside the `0.0.1` boundary; if masking the full web surface is
too broad, disable screenshot capture for that integration.

Custom host marks are honored even when automatic text-input masking is
disabled. This makes an explicitly configured sensitive region fail closed.
