# Changelog

All notable changes to the native Crumb SDKs are documented here. Crumb follows
Semantic Versioning while the public API is released.

## [Unreleased]

### Added

- Added the strict-TypeScript `@crumbsdk/react-native` Nitro Module with
  autolinked CocoaPods and Maven dependencies, native reporter invocation,
  inferred native release identity, OTA bundle identity, and an Expo
  development-build example.
- Added bounded structured JavaScript logs and opt-in `console.warn` and
  `console.error` capture. Entries are mirrored into native memory as they are
  written, so native report presentation never waits on a blocked JavaScript
  thread.
- Added disabled-by-default React Native JavaScript crash capture for fatal
  exceptions and unhandled promise rejections, with chained host handlers,
  bounded sanitized native persistence, relaunch recovery, and deduplication of
  native termination wrappers.

### Fixed

- Made CocoaPods publication resilient to post-publication service errors and
  removed ambiguous fuzzy package lookup from the public verification gate.
- Declared the Swift language version on the dependency-only umbrella pod.

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
