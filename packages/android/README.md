# Crumb Android proof of concept

This Gradle project contains:

- `crumb-core`: inert configuration and the shared diagnostic models;
- `crumb-ui`: screenshot masking, one-time diagnostics, native reporter, local
  draft, and foreground shake detection;
- `demo`: a small native Kotlin host application.

Explicitly submitted reports are persisted in an app-private, size-bounded
queue and survive restart. With an ingestion URL configured, foreground
delivery uses signed artifact targets, bounded backoff, and connectivity
recovery. Nothing is sampled between initialization and report invocation.

Install the reporter once after configuration. The SDK then owns Activity
lifecycle handling and foreground-only shake detection:

```kotlin
Crumb.start(configuration)
CrumbReporter.install(application)

// Optional explicit entry point from any foreground Activity.
CrumbReporter.show(activity)
```

Enable delivery by adding transport configuration. Leave `ingestionUrl` null
for a local-only queue:

```kotlin
CrumbConfiguration(
    projectKey = "project_write_key",
    environment = "production",
    release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "100"),
    diagnostics = CrumbDiagnosticsOptions(
        healthCheckUrl = "https://ingestion.example.com/health",
    ),
    upload = CrumbUploadOptions(
        ingestionUrl = "https://ingestion.example.com",
    ),
)
```

The health probe is independently opt-in and uses one bounded `HEAD` request
only after the reporter opens. It records Crumb API availability separately
from Android's device connectivity observation and never gates local saving.

Both invocation paths respect `CrumbConfiguration.invocation`. Opening the
reporter renders the form first, then gathers the bounded diagnostic snapshot
on a worker thread. The active draft survives rotation and backgrounding.
Submitting the review screen atomically saves the report before Crumb confirms
it is safe to close.

Screenshot previews use the final bounded, masked PNG and may be removed before
review. `EditText` is masked automatically. Mark other sensitive Views with:

```kotlin
accountNumberView.maskInCrumbScreenshots()
```

The same interface can mask a whole `ComposeView` or `WebView`; Crumb does not
inspect individual composables or DOM elements in `0.0.1`. See
`docs/contracts/screenshot-artifacts.md` for the complete boundary.

Android applications can provide recent logs without granting system-log
access:

```kotlin
CrumbConfiguration(
    // project, environment, and release omitted
    diagnostics = CrumbDiagnosticsOptions(
        logs = CrumbLogOptions(
            provider = CrumbLogProvider { appLogger.recentEntries() },
        ),
    ),
)
```

The provider is invoked on the diagnostics worker only after a report opens.
It should return a prompt in-memory snapshot; Crumb applies time, count, byte,
and sanitization limits.

Build it with:

```bash
./gradlew :demo:assembleDebug
```

With an emulator or device connected, install it with:

```bash
./gradlew :demo:installDebug
```

The APK is also written to `demo/build/outputs/apk/debug/demo-debug.apk`.

For release-candidate staging delivery, use the ignored dogfood configuration
and the end-to-end checklist in [`docs/quality/t14-dogfood.md`](../../docs/quality/t14-dogfood.md).
The demo home screen states whether it is in local-only or staging-upload mode.
