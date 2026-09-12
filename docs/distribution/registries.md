# Native registry publication

Crumb publishes immutable native releases from an exact Git tag only after the
same tag has a verified GitHub release. Registry publication is deliberately a
separate, manually confirmed workflow because CocoaPods and Maven Central do
not allow replacing an existing version.

## Public identities

- CocoaPods: `CrumbSDKCore`, `CrumbSDKUI`, and `CrumbSDK`
- Maven Central: `com.crumbsdk:crumb-core` and `com.crumbsdk:crumb-ui`

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
to become available. Maven Central receives one signed bundle containing both
Android artifacts, sources, documentation, POM metadata, Gradle
module metadata, signatures, and required checksums.

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
privacy manifest and compatibility first. Update the SPM/native podspec pins,
packaging URL/SHA-256 and bundled podspec together, then rerun both SPM and packed
consumer checks. Do not silently fall back to downloading a missing dependency
on a customer's machine.
