# T14 release-candidate dogfood

This runbook validates the latest `0.0.1` release candidate against the isolated Crumb
staging control plane before any public `0.0.1` tag or package publication.

## Safety boundary

- Create a separate, revocable SDK write key for this run. It may ingest only
  into the selected staging project.
- Never use a Firebase credential, Railway token, database URL, object-storage
  credential, user access token, or administrative key in a demo application.
- Keep the real key only in the ignored local configuration files below. Do not
  paste it into source, test evidence, CI logs, screenshots, or chat.
- Revoke or rotate the dogfood key after the run.
- The checked-in configuration remains local-only. Both demo home screens must
  say `Staging upload enabled` before an end-to-end staging test is accepted.

Staging ingestion base URL:

```text
https://api.staging.crumbsdk.com
```

## iOS host

From the repository root:

```bash
cp examples/ios/Dogfood.xcconfig.example examples/ios/Dogfood.xcconfig
```

Add the revocable key to `examples/ios/Dogfood.xcconfig`, then build or test with
the ignored configuration:

```bash
xcodebuild test \
  -project examples/ios/CrumbDemo.xcodeproj \
  -scheme CrumbDemo \
  -xcconfig examples/ios/Dogfood.xcconfig \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The same `-xcconfig` flag can be used for a physical-device archive or build.
Runtime environment variables named `CRUMB_DOGFOOD_PROJECT_KEY`,
`CRUMB_DOGFOOD_INGESTION_URL`, and `CRUMB_DOGFOOD_ENVIRONMENT` override the
Info.plist values when a test harness needs a temporary configuration.

## Android host

From `packages/android`:

```bash
cp local.properties.example local.properties
```

Add the revocable key to `local.properties`, then build and install:

```bash
./gradlew :demo:assembleDebug
./gradlew :demo:installDebug
```

The equivalent Gradle properties are `crumbDogfoodProjectKey`,
`crumbDogfoodIngestionUrl`, and `crumbDogfoodEnvironment`.

## Required flow on each platform

1. Install a clean release-candidate demo build and confirm its home screen says
   `Staging upload enabled`.
2. Open the reporter with the button and again with a physical shake. Confirm
   duplicate presentation is prevented.
3. Confirm the card-number field is masked in the final screenshot artifact.
   Remove and restore the screenshot once before submission.
4. Enter a short synthetic problem report, review the evidence receipt, and
   submit it.
5. Repeat with connectivity disabled. Close and reopen the app, reconnect, and
   confirm the queued report uploads exactly once.
6. In the staging web app, find both occurrences in the intended project inbox.
   Open report detail and confirm sanitized evidence, environment, release,
   device, network, logs, stack sample, and Crumb service-health state.
7. Confirm neither occurrence is visible from another organization or project.
8. Revoke or rotate the dogfood SDK key and confirm the old key can no longer
   initialize an upload.

Record the device/OS, commit SHA, artifact checksums, report IDs, timestamps,
and pass/fail result in the release evidence. Keep screenshots and recordings
in the private release evidence location; do not commit device artifacts,
credentials, APKs, IPAs, videos, or trace bundles to this repository.

## Release gate

T14 is not complete until:

- CI passes for the exact release-candidate commit;
- release artifacts and `SHA256SUMS` verify independently;
- this flow passes on iOS and Android against staging;
- the product name, package metadata, privacy text, and license are approved;
- the latest release candidate is accepted before the final `0.0.1` tag.
