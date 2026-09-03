# Install Crumb

Crumb `0.0.1-rc.3` supports native iOS, native Android, Expo development
builds, and bare React Native applications. Every integration uses the same
project key and ingestion URL from the Crumb dashboard.

## Choose your integration

| Application | Package | Minimum target |
| --- | --- | --- |
| Native iOS | Swift Package Manager or `CrumbSDK` on CocoaPods | iOS 15 |
| Native Android | `com.crumbsdk:crumb-ui` on Maven Central | Android API 26 |
| Expo | `@crumbsdk/react-native` with a development build | iOS 15.1 / Android API 26 |
| Bare React Native | `@crumbsdk/react-native` with native autolinking | React Native 0.79, iOS 15.1 / Android API 26 |

Before starting, copy these values from the SDK setup page in the dashboard:

- the project write key for the application;
- the ingestion API base URL;
- the environment name, such as `staging` or `production`.

The project key is designed to be embedded in an application. It authenticates
report ingestion only; it is not an account credential. Do not reuse it as a
dashboard, Firebase, or server secret.

## Native iOS

### Install with Swift Package Manager

In Xcode, select **File > Add Package Dependencies** and use:

```text
https://github.com/alexander126/crumb.git
```

Choose the exact `0.0.1-rc.3` release and add both `CrumbCore` and `CrumbUI` to
the application target.

For a manifest-managed project, use:

```swift
dependencies: [
    .package(
        url: "https://github.com/alexander126/crumb.git",
        exact: "0.0.1-rc.3"
    )
]
```

Then add both products to the application target dependencies:

```swift
.product(name: "CrumbCore", package: "crumb"),
.product(name: "CrumbUI", package: "crumb")
```

### Install with CocoaPods

Add the complete SDK to the application's `Podfile`:

```ruby
platform :ios, "15.0"

target "YourApp" do
  pod "CrumbSDK", "0.0.1-rc.3"
end
```

Then install the pods and open the generated workspace:

```sh
bundle exec pod install
open YourApp.xcworkspace
```

Use `pod install` directly if the application does not manage CocoaPods with
Bundler.

### Configure iOS

Start Crumb once during application launch, then install the reporter. Replace
the example key and URL with the values shown in the dashboard.

```swift
import CrumbCore
import CrumbUI
import UIKit

func configureCrumb() throws {
    let apiURL = URL(string: "https://api.example.com")!
    let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown"
    let buildNumber = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"

    try Crumb.start(
        CrumbConfiguration(
            projectKey: "crumb_sdk_replace_me",
            environment: "production",
            release: CrumbRelease(
                appVersion: appVersion,
                nativeBuild: buildNumber
            ),
            diagnostics: CrumbDiagnosticsOptions(
                healthCheckURL: apiURL.appendingPathComponent("health")
            ),
            reporter: CrumbReporterOptions(theme: .system),
            evidence: [.screenshot, .performance, .network, .logs, .threadStacks, .healthCheck],
            upload: CrumbUploadOptions(ingestionURL: apiURL)
        )
    )

    Crumb.installReporter()
}
```

Call `configureCrumb()` from `application(_:didFinishLaunchingWithOptions:)`
or the equivalent application startup path. Crumb can then open from a
foreground shake. A button can open it explicitly on the main actor:

```swift
Crumb.show()
```

Text fields and text views are masked automatically. Mark any additional UIKit
or SwiftUI region that must never appear in a Crumb screenshot:

```swift
paymentCardView.crumbMaskInScreenshots = true

PaymentCardView()
    .crumbMaskInScreenshots()
```

## Native Android

Ensure the application resolves dependencies from Maven Central:

```kotlin
repositories {
    google()
    mavenCentral()
}
```

Add the complete SDK to the app module. `crumb-ui` includes `crumb-core`
transitively:

```kotlin
dependencies {
    implementation("com.crumbsdk:crumb-ui:0.0.1-rc.3")
}
```

Crumb requires Android API 26 or newer and Java 17 bytecode:

```kotlin
android {
    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
```

Start Crumb once from the application's `Application` class and install the
reporter on the main thread:

```kotlin
import android.app.Application
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbReporterOptions
import dev.crumb.core.CrumbTheme
import dev.crumb.core.CrumbUploadOptions
import dev.crumb.ui.CrumbReporter

class App : Application() {
    override fun onCreate() {
        super.onCreate()

        val apiUrl = "https://api.example.com"
        Crumb.start(
            CrumbConfiguration(
                projectKey = "crumb_sdk_replace_me",
                environment = "production",
                release = CrumbRelease(
                    appVersion = BuildConfig.VERSION_NAME,
                    nativeBuild = BuildConfig.VERSION_CODE.toString(),
                ),
                diagnostics = CrumbDiagnosticsOptions(
                    healthCheckUrl = "$apiUrl/health",
                ),
                reporter = CrumbReporterOptions(theme = CrumbTheme.SYSTEM),
                evidence = CrumbEvidenceCategory.entries.toSet(),
                upload = CrumbUploadOptions(ingestionUrl = apiUrl),
            ),
        )
        CrumbReporter.install(this)
    }
}
```

Register the class in `AndroidManifest.xml`:

```xml
<application
    android:name=".App"
    ... />
```

Crumb can now open from a foreground shake. Open it from a button when needed:

```kotlin
CrumbReporter.show(this)
```

`EditText` is masked automatically. Mark any additional Android `View`,
`ComposeView`, or `WebView` region that must be excluded from the screenshot:

```kotlin
import dev.crumb.ui.maskInCrumbScreenshots

paymentCardView.maskInCrumbScreenshots()
```

## React Native

The React Native package is a Nitro Module over the same Swift and Kotlin SDKs.
Install both direct native dependencies at compatible versions:

```sh
npm install @crumbsdk/react-native@0.0.1-rc.3 \
  react-native-nitro-modules@0.37.1
```

The JavaScript setup is the same for Expo and bare React Native:

```ts
import Crumb from '@crumbsdk/react-native';

export async function configureCrumb(): Promise<void> {
  await Crumb.start({
    projectKey: 'crumb_sdk_replace_me',
    environment: __DEV__ ? 'development' : 'production',
    upload: {
      ingestionUrl: 'https://api.example.com',
    },
    diagnostics: {
      healthCheckUrl: 'https://api.example.com/health',
      logs: {
        captureConsole: true,
      },
      javascriptCrashCapture: {
        enabled: true,
      },
    },
    reporter: {
      theme: 'system',
      visibleFields: ['category', 'description'],
    },
    evidence: ['screenshot', 'performance', 'network', 'logs', 'thread_stacks', 'health_check'],
    customContext: {
      values: { account_tier: 'trial' },
      allowedKeys: ['account_tier'],
    },
    workspacePolicy: {
      url: 'https://policy.example.com/sdk/v1/policy',
    },
  });

  await Crumb.installReporter();
}
```

Call `configureCrumb()` once from the application startup path. Crumb reads the
native application version and build number automatically. For Expo Updates,
pass the active update identifier as `release.bundleVersion`.

JavaScript crash capture is optional and disabled by default. When enabled, the
React Native adapter preserves fatal JavaScript exceptions and unhandled promise
rejections through a bounded sanitized native handoff, chains existing host
handlers, and recovers the occurrence into the normal durable queue on the next
launch. It does not capture arbitrary native crashes or application state.

Open the reporter from application UI when needed:

```ts
await Crumb.show();
```

### Expo development builds

Crumb contains custom native code and does not run in Expo Go. Install a
development client and the build-properties plugin:

```sh
npx expo install expo-dev-client expo-build-properties
```

Set Crumb's native minimums in `app.json` or `app.config.ts`:

```json
{
  "expo": {
    "plugins": [
      [
        "expo-build-properties",
        {
          "android": { "minSdkVersion": 26 },
          "ios": { "deploymentTarget": "15.1" }
        }
      ]
    ]
  }
}
```

No Crumb-specific config plugin is required. Create a native development build;
Expo Prebuild and React Native autolinking add Crumb to both native projects:

```sh
npx expo run:ios
# or
npx expo run:android
```

After changing Crumb or another native dependency, rebuild the development
client. JavaScript-only changes can continue through `npx expo start` without a
new native build.

The repository includes a standalone [Expo consumer example](../examples/react-native/README.md)
that installs the public npm package and builds both generated native projects
in CI.

### Bare React Native

React Native autolinking discovers Crumb after the npm install. Install the iOS
pods, then rebuild both applications:

```sh
npx pod-install
npm run ios
# or
npm run android
```

Ensure the iOS application target is 15.1 or newer and the Android application
uses API 26 or newer. No manual `AppDelegate`, `MainApplication`, or package-list
registration is needed for the React Native adapter.

For a manually maintained native project, set `platform :ios, "15.1"` in the
Podfile and `minSdk = 26` in the Android app module before installing pods or
building Gradle.

## Verify the integration

Use a real application build or simulator/emulator build, not Expo Go:

1. Start the application and confirm Crumb configuration completes once.
2. Open the reporter from an application button.
3. Confirm a screenshot is present and sensitive fields are masked.
4. Submit a test report and confirm it appears in the correct dashboard project.
5. Shake a foreground physical device and confirm the small reporter prompt
   appears.

Leaving the ingestion URL unset keeps submitted reports in the SDK's local,
durable queue. Add it before expecting reports to reach the dashboard.

The complete configuration and privacy precedence rules, including the
description-only fail-closed state while a workspace policy is unavailable,
are documented in the [SDK configuration contract](contracts/sdk-configuration.md).

## Next references

- [React Native package reference](../packages/react-native/README.md)
- [Android diagnostics and log-provider details](../packages/android/README.md)
- [Native package identities and distribution](distribution/native.md)
- [Privacy and screenshot artifact contract](contracts/screenshot-artifacts.md)
