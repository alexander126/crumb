# Crumb iOS proof of concept

This is a normal UIKit application that consumes the local `CrumbUI` Swift
package. Submitted reports persist in the app-private queue. The checked-in demo
configuration leaves upload disabled because it has no real project write key.

The demo exercises:

- `Crumb.start`;
- one-time `Crumb.installReporter()` lifecycle installation;
- programmatic and physical-device shake invocation;
- screenshot capture before reporter presentation;
- default masking of text inputs;
- one-time CPU, memory, app-thread, thermal, and network diagnostics;
- optional CPU pressure in the demo app to validate report-time capture;
- a native report form;
- an in-memory diagnostic snapshot and local draft summary.
- durable local submission and the foreground uploader lifecycle.

Crumb does not collect anything between initialization and report invocation.
The installation hook only enables shake sensing while the application is
active. The form opens before its one-time diagnostics finish, and its state is
preserved through rotation and backgrounding.

```swift
try Crumb.start(configuration)
Crumb.installReporter()

// Optional explicit entry point.
Crumb.show()
```

Enable delivery in a host application by supplying transport configuration:

```swift
CrumbConfiguration(
    projectKey: "project_write_key",
    environment: "production",
    release: CrumbRelease(appVersion: "1.0.0", nativeBuild: "100"),
    diagnostics: CrumbDiagnosticsOptions(
        healthCheckURL: URL(string: "https://ingestion.example.com/health")
    ),
    upload: CrumbUploadOptions(
        ingestionURL: URL(string: "https://ingestion.example.com")
    )
)
```

The optional health probe is a bounded `HEAD` request made only after explicit
report invocation. Crumb stores its result separately from the device network
path, and an unavailable API never blocks the reporter or local queue commit.

Generate the Xcode project when the source list changes:

```bash
ruby generate_project.rb
```

Then open `CrumbDemo.xcodeproj`, select an iPhone simulator, and run.

For release-candidate staging delivery, use the ignored dogfood configuration
and the end-to-end checklist in [`docs/quality/t14-dogfood.md`](../../docs/quality/t14-dogfood.md).
The demo home screen states whether it is in local-only or staging-upload mode.

Run its complete local-draft UI check from the repository root with:

```bash
xcodebuild test \
  -project examples/ios/CrumbDemo.xcodeproj \
  -scheme CrumbDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
