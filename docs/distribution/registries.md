# Native registry publication

Crumb publishes immutable native releases from an exact Git tag only after the
same tag has a verified GitHub release. Registry publication is deliberately a
separate, manually confirmed workflow because CocoaPods and Maven Central do
not allow replacing an existing version.

## Public identities

- CocoaPods: `CrumbSDKCore`, `CrumbSDKUI`, and `CrumbSDK`
- Maven Central: `com.crumbsdk:crumb-core`, `com.crumbsdk:crumb-ui`, and
  `com.crumbsdk:crumb-react-native`

The CocoaPods package names intentionally differ from the installed Swift
modules, which remain `CrumbCore` and `CrumbUI`. The Maven group differs from
the Android source packages, which remain under `dev.crumb`.

## Repository secrets

The `Publish native registries` workflow requires:

- `COCOAPODS_TRUNK_TOKEN`
- `CENTRAL_TOKEN_USERNAME`
- `CENTRAL_TOKEN_PASSWORD`
- `MAVEN_GPG_PRIVATE_KEY`
- `MAVEN_GPG_PASSPHRASE`

Credentials are stored only as GitHub Actions secrets. The Maven signing key's
public half must be published to a key server supported by Maven Central.

## Publication gate

Run the workflow manually with:

1. the exact release tag;
2. `both`, `cocoapods`, or `maven` as the registry target; and
3. the exact confirmation text `publish <tag>`.

The workflow checks out the tag rather than the branch tip. CocoaPods publishes
Core, UI, and the umbrella pod in dependency order and waits for each new spec
to become available. Maven Central receives one signed bundle containing all
three Android artifacts, sources, documentation, POM metadata, Gradle
module metadata, signatures, and required checksums.

`com.crumbsdk:crumb-react-native` is new since `0.0.1-rc.6` and
`@crumbsdk/react-native` depends on it, so the first release that publishes it
must publish it alongside Core and UI. A published React Native install cannot
resolve its JavaScript crash handoff without it; the repository's own example
resolves the native projects directly, so this is the one gap a local build
does not surface.

After publication, the workflow waits for registry propagation. It reads the
canonical CocoaPods metadata and builds a clean Android consumer using Maven
Central rather than the locally staged repository.

## Local bundle rehearsal

Maven Central bundle preparation requires an ASCII-armored signing key through
Gradle's in-memory signing properties:

```bash
npm run registry:bundle:maven
```

The generated bundle is written beneath `dist/registry/maven/<version>/` and is
ignored by Git. Never commit signing keys, registry tokens, or generated
publication bundles.

## CocoaPods trunk transition

CocoaPods trunk is scheduled to become read-only on 2 December 2026, with a
rehearsal on 1–7 November. Existing publications remain installable. New native
iOS integrations should use SPM. CocoaPods publication is a legacy compatibility
channel, not a prerequisite for future SPM or npm releases. Select `maven`, not
`both`, when publishing native registries after the freeze.

### PLCrashReporter and the native pods

The native pods and the Swift package have no third-party dependency. From rc.4
to rc.7 `CrumbSDKCore` depended on the trunk pod `PLCrashReporter`, although
only the React Native JavaScript failure handoff used it. That pod declares an
iOS minimum of 12.0, which Xcode 27 rejects, and CocoaPods applies a pod's own
declared minimum even when the Podfile asks for a higher platform. A native
CocoaPods consumer on Xcode 27 therefore needed a wrapper podspec, and
`pod trunk push`, which validates against trunk's own copy, needed an older
Xcode. None of those candidates reached trunk, which held only rc.3 until rc.8.

The thread-stack capture now lives in the React Native adapter, which is the
only component that links PLCrashReporter. `npm run distribution:verify` and the
podspec lint fail if `Package.swift` or a native podspec names it again, and the
lint supplies no third-party podspec, so it resolves exactly what trunk would.
The **Publish native registries** CocoaPods job uses the runner image's Xcode.

The pinned version and SHA-256 live in the React Native wrapper that reads the
npm-bundled framework, `packages/react-native/scripts/PLCrashReporter.podspec`,
and in `packages/react-native/scripts/prepare-ios.mjs`. The adapter podspec and
`packages/react-native/ios-tests/Package.swift` name the same version.
`npm run distribution:verify` fails if they drift. Update all four together when
bumping PLCrashReporter. The wrapper stays necessary inside the npm package
because 1.12.2 still declares iOS 12.0.

The React Native npm release bundles Crumb's canonical iOS sources, local
podspecs and PLCrashReporter 1.12.0's official XCFramework, license and privacy
manifest. `yarn prepare:ios` checks the native version and dependency pins and
verifies the upstream archive SHA-256 before extraction. `prepack` runs it for
both npm publication and Yarn packing; consumers do not run a download script.
An optional `CRUMB_PLCRASH_ARCHIVE` points to an already-downloaded official
archive for offline release preparation; the same checksum is mandatory.

Run `yarn test:packaging`, `yarn pack:check` and, on macOS,
`yarn pack:check:ios` from `packages/react-native`. The last check extracts a
real npm archive outside the checkout, uses an empty local spec repository,
rejects any resolved spec-repository dependencies and builds the native iOS
products for the simulator. Expo CI uses the public config plugin instead of
source-checkout pod overrides. Keep `crumbNativeVersion`, root `VERSION`,
Swift source version and packaged sources aligned when preparing a release.

When updating PLCrashReporter, review its source, release provenance, license,
privacy manifest and compatibility first. Update the adapter podspec and test
package pins, packaging URL/SHA-256 and bundled podspec together, then rerun
`npm run test:ios` and the packed consumer checks. Do not silently fall back to downloading a missing dependency
on a customer's machine.
