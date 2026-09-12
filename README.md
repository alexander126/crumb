# Crumb

Crumb is a native-first mobile issue-reporting SDK. Its first production slice
turns an explicit user report into a privacy-safe diagnostic packet that an
engineer can inspect without asking the reporter to recreate basic context.

> **rc.4 candidate:** current source is being prepared for `0.0.1-rc.4`.
> See [release notes and migration](docs/releases/0.0.1-rc.4.md). Published
> rc.3 quickstarts remain versioned until candidate artifacts are available.

## Install Crumb

The current public preview is `0.0.1-rc.3`.

| Application | Install | Full quickstart |
| --- | --- | --- |
| React Native & Expo | `@crumbsdk/react-native@0.0.1-rc.3` + Nitro `0.37.1` | [React Native, including Expo](website/content/docs/quickstarts/react-native.mdx) |
| Native iOS | SPM or `pod "CrumbSDK", "0.0.1-rc.3"` | [iOS](website/content/docs/quickstarts/ios.mdx) |
| Native Android | `com.crumbsdk:crumb-ui:0.0.1-rc.3` from Maven Central | [Android](website/content/docs/quickstarts/android.mdx) |

Each guide covers installation, configuration, invocation, verification and
troubleshooting. Expo Go is unsupported because Crumb includes native code.
[Run the branded documentation site locally](website/README.md), or browse the
[public guides](website/content/docs/index.mdx). See [release availability](website/content/docs/releases.mdx)
for the distinction between published rc.3 and unreleased main-branch features.

## Current status

The following describes the main-branch implementation, including unreleased
features. The quickstarts above target the published packages.

This repository owns the distributable native SDKs and their public report
protocol. The hosted API and customer dashboard live in the separate private
`alexander126/crumb-cloud` monorepo so cloud deployments and SDK releases can
move independently.

- iOS and Android are the product implementations.
- React Native is a thin Nitro Module adapter over the proven native SDKs, with
  an Expo development-build example, bounded JavaScript log capture, and an
  opt-in JavaScript-only crash handoff that is disabled by default.
- Both native demos stay idle until a button or foreground shake opens the
  reporter. They then mask text inputs in a screenshot and collect a one-time
  CPU, memory, thread, thermal, network, and bounded recent-log snapshot for a
  local draft.
- Each host installs the native reporter once after configuration. Crumb owns
  foreground shake sensing, duplicate suppression, dismissal, and report state
  restoration across rotation and backgrounding.
- Native iOS and Android use application-owned log providers; neither hooks
  logging calls or requests broad system-log access. The React Native adapter
  supplies a bounded, sanitized JavaScript log buffer.
- JavaScript failure handoff can attach bounded iOS native frames and Android
  managed Java/Kotlin stacks. Native frame offsets are not symbolicated source
  locations; unsupported measurements remain unavailable.
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
- When enabled by a React Native host, fatal JavaScript exceptions and
  unhandled promise rejections survive a relaunch as one deduplicated,
  sanitized report occurrence. Native crash hooks remain outside the SDK.
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
website/            Fumadocs site and customer integration guides
```

## Checks

```bash
npm install
npm test
```

## Integration references

The [source-map upload guide](docs/source-maps.md) covers preparing exact React
Native release artifacts and the CI upload CLI implementation preview.

Run the native demos from [examples/ios](examples/ios/README.md) and
[packages/android](packages/android/README.md). The React Native API and its
JavaScript log boundary are documented in
[packages/react-native](packages/react-native/README.md).

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
