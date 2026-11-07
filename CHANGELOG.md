# Changelog

All notable changes to the native Crumb SDKs are documented here. Crumb follows
Semantic Versioning while the public API is released.

## [Unreleased]

### Fixed

- iOS: a CocoaPods installation could not be built with Xcode 26 or later. The
  upstream `PLCrashReporter` pod declares an iOS minimum of 12.0 and those
  toolchains reject any target below 15.0, so `pod install` succeeded and the
  build then failed on the generated `PLCrashReporter` targets. CocoaPods applies
  a pod's own declared minimum even when the Podfile asks for a higher platform,
  so the floor had to be corrected on the dependency itself.

  `distribution/cocoapods/PLCrashReporter.podspec` wraps the same official
  release archive, pinned by the same SHA-256, with Crumb's supported iOS
  minimum declared instead. It keeps the pod name `PLCrashReporter`, so it
  replaces the upstream pod rather than linking a second copy of
  `CrashReporter.xcframework`, and no new public package identity is published.

  **A CocoaPods consumer on Xcode 26 or later must add one Podfile line** to
  select it; the [iOS quickstart](website/content/docs/quickstarts/ios.mdx) gives
  the exact form. Swift Package Manager installations are unaffected and need no
  equivalent line, because SPM applies the consuming target's deployment target
  rather than the dependency's. The React Native package was already unaffected:
  it ships its own wrapper declaring the same 15.0 minimum. Upgrading the pin
  would not have helped, as PLCrashReporter 1.12.2 also declares 12.0.

### Changed

- Android: the React Native JavaScript crash handoff moved out of `crumb-core`
  into a new `com.crumbsdk:crumb-react-native` artifact. `crumb-core`'s release
  AAR is about 25 KiB smaller, which a native-only Android application no longer
  carries for machinery it never calls. `@crumbsdk/react-native` depends on the
  new artifact; native integrations do not and should not add it. The React
  Native JavaScript API is unchanged, and so is the on-disk handoff format.

### Removed

- Android: `Crumb.recordJavaScriptCrash` and `Crumb.recoverJavaScriptCrashes`
  are no longer on `dev.crumb.core.Crumb`, and `CrumbReporter` exposes
  `reportDidQueue()` in place of its `recoverJavaScriptCrashes(context)` bridge.
  The entry point is now
  `dev.crumb.reactnative.CrumbJavaScriptCrashes.record` / `.recover` in the new
  `crumb-react-native` artifact. A native integration that called the old
  functions directly should add `com.crumbsdk:crumb-react-native` and use the
  new entry point.

  `@crumbsdk/react-native` calls the new entry point and depends on the new
  artifact. The repository's example resolves the native projects directly
  through Gradle composite substitution, so this is verified locally and in CI;
  a published install resolves `com.crumbsdk:crumb-react-native` from Maven
  Central, which the next release must publish alongside Core and UI.

## [0.0.1-rc.6] - Candidate

See the [rc.6 release and migration notes](docs/releases/0.0.1-rc.6.md).
Publication and final installation/dogfood checks remain separate release gates.

### Fixed

- The React Native archive's bundled PLCrashReporter pod wrapper now matches
  Crumb's existing iOS 15 deployment floor, so native consumers do not compile
  the wrapper against an unsupported iOS 12 target.
- Native failure-stack tests share the existing serialized capture test suite,
  preventing competing tests from contending for the process-wide capture lock.

## [0.0.1-rc.5] - Candidate

See the [rc.5 release and migration notes](docs/releases/0.0.1-rc.5.md).
Publication and final installation/dogfood checks remain separate release gates.

### Added

- Guided React Native and Expo setup, local configuration checks, and an included
  source-map uploader; installing a second Crumb package is no longer required.
- Release build hooks for immutable JavaScript bundle identities and uploads of
  final composed source maps, with retained artifacts for retries and optional
  strict CI failure handling.
- An Expo export helper for explicit native release targets, preserving the
  exported bundle identity without publishing an OTA update.

### Fixed

- Recovered JavaScript failures retain the native version/build at capture time,
  including when the app binary changes before relaunch.
- Android React Native Release packaging excludes the dependency-owned duplicate
  Nitro library.
- Source-map CLI package checks accept the npm 12 archive metadata format.

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
