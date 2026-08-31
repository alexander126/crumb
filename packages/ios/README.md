# Crumb for iOS

Crumb's native iOS SDK owns reporter presentation, foreground shake detection,
privacy-safe screenshot capture, one-time diagnostics, durable local storage,
and report upload.

## Install in an application

The current public preview is `0.0.1-rc.3`.

- Swift Package Manager: add `https://github.com/alexander126/crumb.git` at the
  exact release and link both `CrumbCore` and `CrumbUI`.
- CocoaPods: add `pod "CrumbSDK", "0.0.1-rc.3"`.

The supported target is iOS 15 or newer. Follow the
[native iOS installation guide](../../docs/getting-started.md#native-ios) for a
complete startup configuration and verification checklist.

## Public integration surface

```swift
import CrumbCore
import CrumbUI

try Crumb.start(configuration)
Crumb.installReporter()

// Optional application-owned entry point.
Crumb.show()
```

The application supplies its project write key, environment, native release
identity, and ingestion URL through `CrumbConfiguration`. Leaving the ingestion
URL unset keeps submitted reports in the app-private durable queue.

Crumb masks `UITextField` and `UITextView` automatically. Additional UIKit and
SwiftUI regions can opt into masking:

```swift
paymentCardView.crumbMaskInScreenshots = true

PaymentCardView()
    .crumbMaskInScreenshots()
```

## Develop the SDK

From the repository root:

```sh
swift test
```

The sample application and its configuration are documented in the
[iOS example guide](../../examples/ios/README.md).
