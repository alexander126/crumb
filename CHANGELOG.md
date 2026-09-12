# Changelog

All notable changes to the native Crumb SDKs are documented here. Crumb follows
Semantic Versioning while the public API is released.

## [Unreleased]

## [0.0.1-rc.4] - Candidate

This candidate is prepared from current source; registry publication and the
final installation/dogfood gates are tracked separately. See the
[rc.4 release and migration notes](docs/releases/0.0.1-rc.4.md).

### Added

- Opt-in React Native JavaScript fatal-exception and unhandled-rejection
  capture, bounded native persistence, relaunch recovery and deduplication.
- Failure-time native diagnostics and platform stacks, with separately opted-in
  recent rendering measurements. Unavailable measurements remain explicit.
- Manual screen labels, React Navigation and Expo Router integrations that
  preserve the original screen in reports/crashes without route parameter values.
- Reporter theme and field configuration, evidence selection, bounded custom
  context and privacy-policy precedence.
- The standalone `@crumbsdk/source-maps` CLI for explicit, authenticated uploads
  of exact release bundles and final composed maps.
- Configurable source-linked Release crash fixtures and navigation examples.

### Changed

- React Native npm archives now include Crumb's iOS sources and pinned
  PLCrashReporter dependency. Expo uses the Crumb config plugin; bare React
  Native uses the Podfile helper. Native Swift applications should use SPM.
  New iOS SDK releases no longer require a new CocoaPods trunk publication.
- Version synchronization and release checks cover Swift, Kotlin, the React
  Native package/native dependency pin and the source-map CLI/lockfile.
- React Native publication requires its tag and native tag to identify the same
  source commit.

### Fixed

- Android starts uploading recovered JavaScript failures without another
  background/foreground transition.
- Native Android demo accessibility tests apply dark appearance and large text
  before Activity resources are created.
- Source-linked demo Release instructions prepare bundled iOS dependencies and
  regenerate Android bundles after configuration changes.

## [0.0.1-rc.3] - 2026-08-31

### Added

- Manual, immutable publication workflows for `CrumbSDK`, `CrumbSDKCore`, and
  `CrumbSDKUI` on CocoaPods.
- Signed Maven Central bundles for `com.crumbsdk:crumb-core` and
  `com.crumbsdk:crumb-ui`, including sources, documentation, POM metadata,
  checksums, and clean-consumer verification.

## [0.0.1-rc.2] - 2026-08-31

### Changed

- Reserved collision-free CocoaPods identities under `CrumbSDK` and aligned
  Maven Central coordinates with the verified `com.crumbsdk` domain namespace.
- Made the clean Swift consumer check independent of the local checkout folder
  name and verified the final package identities inside release archives.

## [0.0.1-rc.1] - 2026-08-31

### Added

- Native iOS and Android report flows with foreground shake and programmatic
  invocation.
- Masked screenshots, bounded diagnostics, sanitized host logs, and optional
  infrastructure health evidence collected only after explicit invocation.
- App-private durable report queues and idempotent uploads to project-isolated
  ingestion.
- Swift Package Manager, CocoaPods, and Maven-compatible distribution shapes.
- Minimum-platform, accessibility, privacy, binary-size, and physical-device
  quality gates.

### Release-candidate gate

- Apache-2.0 licensing for the distributable native SDK repository; hosted
  cloud code remains private and proprietary.
- Reproducible GitHub CI, native package rehearsal, immutable release archives,
  a machine-readable manifest, and SHA-256 checksums.
- Local-by-default iOS and Android dogfood hosts that enable staging delivery
  only when a revocable project write key and ingestion URL are supplied in
  ignored local configuration.
- The final `0.0.1` tag remains blocked on staging dogfood evidence for both
  platforms.
