# Crumb

Crumb is a native-first mobile issue-reporting SDK. Its first production slice
turns an explicit user report into a privacy-safe diagnostic packet that an
engineer can inspect without asking the reporter to recreate basic context.

## Current status

This repository owns the distributable native SDKs and their public report
protocol. The hosted API and customer dashboard live in the separate private
`alexander126/crumb-cloud` monorepo so cloud deployments and SDK releases can
move independently.

- iOS and Android are the product implementations.
- React Native is a thin Nitro Module adapter over the proven native SDKs, with
  an Expo development-build example and bounded JavaScript log capture.
- Both native demos stay idle until a button or foreground shake opens the
  reporter. They then mask text inputs in a screenshot and collect a one-time
  CPU, memory, thread, thermal, network, and bounded recent-log snapshot for a
  local draft.
- Each host installs the native reporter once after configuration. Crumb owns
  foreground shake sensing, duplicate suppression, dismissal, and report state
  restoration across rotation and backgrounding.
- iOS reads recent unified logs from the current application process. Android
  accepts an application-owned log provider and never requests broad logcat
  access.
- Android also attaches bounded live Java/Kotlin thread stacks. iOS marks
  all-thread stacks unavailable because obtaining them safely would require
  continuous sampling or invasive thread suspension.
- Explicitly submitted reports are atomically persisted in an app-private,
  size-bounded queue and survive restart. When an ingestion URL is configured,
  the native uploader drains that queue with idempotent lifecycle requests,
  bounded backoff, and connectivity recovery.
- The hosted cloud validates the versioned report envelope owned here and keeps
  PostgreSQL, object storage, Firebase administration, and customer web code out
  of the SDK distribution repository.
- A report is one occurrence; related occurrences may later form an issue.
- Diagnostics and screenshot artifacts stay on-device until explicit submission;
  upload never runs before the local atomic commit succeeds.
- Model-driven investigation is intentionally out of scope until ingestion and
  diagnostic quality are reliable.

## Repository layout

```text
packages/ios/       Swift SDK foundation
packages/android/   Kotlin SDK and native Android demo
packages/react-native/ Thin adapter (starts after native parity)
schemas/            Versioned wire contracts and fixtures
examples/           Native integration applications
docs/               Public integration contracts, invariants, and decisions
```

## Checks

```bash
npm install
npm test
```

The native integration shape is deliberately small:

```swift
try Crumb.start(configuration)
Crumb.installReporter()
Crumb.show() // optional programmatic invocation
```

```kotlin
Crumb.start(configuration)
CrumbReporter.install(application)
CrumbReporter.show(activity) // optional programmatic invocation
```

Set `CrumbUploadOptions.ingestionURL` on iOS or `ingestionUrl` on Android to
enable delivery. Leaving it unset keeps the durable queue local-only.
Hosts may separately opt in to report-time Crumb API reachability by setting
the diagnostics health URL to the ingestion service's public `/health` route.

Run the native demos from [examples/ios](examples/ios/README.md) and
[packages/android](packages/android/README.md).

React Native and Expo development-build setup is documented in
[packages/react-native](packages/react-native/README.md). Expo Go is not
supported because the adapter links the native Crumb SDKs.

The standalone [Expo consumer example](examples/react-native/README.md)
installs the published npm package, rather than linking the adapter source, and
is compiled independently on both platforms in CI.

The native package identities and their clean-consumer rehearsal are
documented in [docs/distribution/native.md](docs/distribution/native.md).

The T10 hosted physical-device pass is documented in
[docs/quality/browserstack-device-matrix.md](docs/quality/browserstack-device-matrix.md).

The repository split and hosted product boundary are recorded in
[docs/architecture/cloud-boundary.md](docs/architecture/cloud-boundary.md).

## License

The distributable Crumb native SDKs, examples, and public contracts in this
repository are licensed under the [Apache License 2.0](LICENSE). The hosted
Crumb API, dashboard, infrastructure, and operational code remain in the
separate private `crumb-cloud` repository and are not covered by this license.
