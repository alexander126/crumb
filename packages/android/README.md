# Crumb for Android

Crumb's native Android SDK owns reporter presentation, foreground shake
detection, privacy-safe screenshot capture, one-time diagnostics, durable local
storage, and report upload.

## Install in an application

The current public preview is `0.0.1-rc.3`. Add Maven Central and the UI
artifact; Core is included transitively:

```kotlin
repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("com.crumbsdk:crumb-ui:0.0.1-rc.3")
}
```

Crumb requires Android API 26 or newer and Java 17 bytecode. Follow the
[native Android installation guide](../../docs/getting-started.md#native-android)
for the complete Gradle, `Application`, and manifest setup.

## Configure

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
inspect individual composables or DOM elements in `0.0.1-rc.3`. See the
[screenshot artifact contract](../../docs/contracts/screenshot-artifacts.md)
for the complete boundary.

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

## Configuration and workspace privacy policy

The built-in reporter accepts `CrumbReporterOptions` for system/light/dark
appearance and category/description visibility, plus an `evidence` set for
optional screenshot, performance, network, logs, thread-stack, health-check,
and custom-context sources. The description is always retained.

Custom context is string-only and requires an explicit `allowedKeys` set. Crumb
sanitizes and bounds it before local persistence. To opt into a workspace-owned
privacy policy, add a public policy URL:

```kotlin
CrumbConfiguration(
    projectKey = "project_write_key",
    environment = "production",
    release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "100"),
    reporter = CrumbReporterOptions(theme = CrumbTheme.SYSTEM),
    evidence = CrumbEvidenceCategory.entries.toSet(),
    customContext = CrumbCustomContextOptions(
        values = mapOf("account_tier" to "trial"),
        allowedKeys = setOf("account_tier"),
    ),
    workspacePolicy = CrumbWorkspacePolicyOptions(
        url = "https://policy.example.com/sdk/v1/policy",
    ),
)
```

The fetch is asynchronous and cached app-locally. A valid policy can disable
locally enabled optional evidence or hide the optional category field; it can
never enable a locally disabled source. Until the first valid policy is
available, only the required description path remains active. See the [shared
configuration contract](../../docs/contracts/sdk-configuration.md) for the
versioned policy shape and migration rules.

## Develop the SDK

This Gradle project contains:

- `crumb-core`: inert configuration and the shared diagnostic models;
- `crumb-ui`: screenshot masking, one-time diagnostics, native reporter, local
  draft, and foreground shake detection;
- `demo`: a small native Kotlin host application.

Build the demo with:

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
