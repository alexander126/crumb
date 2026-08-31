# Changelog

All notable changes to the native Crumb SDKs are documented here. Crumb follows
Semantic Versioning while the public API is released.

## [Unreleased]

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
