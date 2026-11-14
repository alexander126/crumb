# Changelog

All notable changes to the native Crumb SDKs are documented here. Crumb follows
Semantic Versioning while the public API is released.

## [Unreleased]

### Fixed

- iOS: the `CrumbSDKCore` and `CrumbSDKUI` pods are now static frameworks. Built
  as dynamic frameworks, which is how CocoaPods trunk validates a pod and how an
  application using `use_frameworks!` builds it, `CrumbSDKCore` placed
  PLCrashReporter's statically linked binary beneath a dynamic framework and
  CocoaPods refused the installation. This blocked the rc.7 trunk publication.
  The release checks now lint the pods with that linkage as well.

## [0.0.1-rc.7] - Candidate

See the [rc.7 release and migration notes](docs/releases/0.0.1-rc.7.md).
Publication and final installation/dogfood checks remain separate release gates.

### Security

- Native: credential-bearing values could survive on-device sanitization of
  logs, diagnostic text, failure text and custom context. Quoted and escaped
  JSON values, common token and secret key spellings, and partial authorization
  and cookie values are now redacted on iOS and Android.
- Native: report descriptions were persisted and uploaded unredacted. They now
  pass through the existing credential, authorization, URL, email and
  card-number redaction before serialization.
- Android: a sensitive view could stay visible in a screenshot after being
  scaled or rotated, because its mask used untransformed bounds. Masks now follow
  the full transform, and the whole screenshot is masked when geometry cannot be
  resolved safely.
- iOS: Remove on the review screen left the screenshot attached, so a second
  review could still include it.
- Native: after the project key or ingestion destination changed, an older
  queued report could be delivered to the new project. Each report now records an
  ownership fingerprint at commit and is delivered only to its own project.
  Reports already queued when an app upgrades are kept but not uploaded
  automatically, and an rc.6 or earlier SDK cannot read the new records; see the
  release notes before upgrading or rolling back.
- iOS: SDK requests used the host application's shared cookie, credential and
  cache storage. They now use an isolated session with all three disabled.
  Android cannot offer the same guarantee; see `PRIVACY.md`.
- Android: queue cleanup no longer follows symbolic links.

### Added

- iOS: SDK-owned required-reason privacy manifests for CrumbCore (System Boot
  Time `35F9.1`) and CrumbUI (also User Defaults `CA92.1`), in every distribution.
- Android: `com.crumbsdk:crumb-react-native`, which carries the React Native
  JavaScript crash handoff. `@crumbsdk/react-native` depends on it; native
  integrations do not need it.

### Fixed

- React Native Android: minified release builds could not construct the SDK,
  because R8 removed the adapter's concrete Nitro class.
- Android: Maven artifacts are consumable from Kotlin 2.0 projects again. Core and
  UI had published Kotlin 2.2 metadata and required the 2.2.0 standard library.
- Native: a queued report was deleted after any successful completion response,
  including `202 processing`. It is now removed only on an explicit `accepted`.
- Native: an automatic retry after a later failure re-sent an older report that
  had already failed terminally. Terminal failures now wait for the next
  foreground transition.
- Native: corrupt or unsupported queue metadata no longer blocks delivery of
  healthy reports. Damaged entries are isolated and still count toward quotas.
- iOS: oversized responses are refused before buffering, and refusing one now
  cancels the transfer. Android classifies an oversized response as terminal.
- iOS: a delivery request made during a running upload pass is honored, and
  installing while in the background no longer starts delivery.
- Android: installing into an already-foreground app starts delivery, and
  delivery no longer pauses while another Activity remains resumed.
- iOS: the reporter is presented, and screenshots taken, only from a
  foreground-active scene.
- iOS: log collection no longer relies on reverse unified-log enumeration and
  reports its real eviction count. A failed thread enumeration reads
  "Unavailable" instead of 0.
- Android: each diagnostic source is guarded individually and capture always
  completes. `Crumb.start` copies the configuration it is given, so later caller
  mutation cannot change it.
- Native: the reporter's evidence counts reflect what was actually captured.
- React Native: console capture coexists with other console wrappers, and the
  log provider survives a JavaScript reload.
- iOS: a CocoaPods installation of rc.4 or later could not be built with Xcode 27,
  which rejects PLCrashReporter's declared iOS 12.0 minimum. Trunk held only
  rc.3, which does not depend on PLCrashReporter, so no published pod was
  affected. A wrapper podspec now selects the same pinned binary at iOS 15.0.

### Changed

- The reporter closes after a report is saved instead of showing a "Report
  saved" popup.
- Report sheets follow downward drags and dismiss on a backdrop tap. Meaningful
  drafts still ask before discarding.
- iOS 26 and later: the report sheet, shake prompt and popup controls use native
  Liquid Glass. Earlier iOS versions keep their existing styling.
- The review screen no longer shows the local-only heading and notice, and its
  Edit and Remove controls align with the card edge.
- Android: the report queue is refused outside the application's main process.
  `CrumbReporter.install` returns `false` and `CrumbReportQueue.from` throws
  `CrumbReportQueueException.UnsupportedProcess`.
- Android: `crumb-core`'s release AAR is about 25 KiB smaller.

### Removed

- Android: `Crumb.recordJavaScriptCrash`, `Crumb.recoverJavaScriptCrashes` and
  `CrumbReporter.recoverJavaScriptCrashes`. Use
  `dev.crumb.reactnative.CrumbJavaScriptCrashes` from `crumb-react-native`.

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
