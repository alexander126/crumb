# Native distribution preparation

Task 9 prepared and tested Crumb's native package shapes without publishing a
public release. Task 14 owns immutable release candidates, final registry
publication, license and privacy documents, checksums, and public tags.

`0.0.1-rc.1` established the reproducible GitHub release path. The package
identities below are finalized in `0.0.1-rc.2` after the unscoped `Crumb`
CocoaPods name was found to be owned by another publisher.

## Package identities

The repository `VERSION` file is the SDK version source of truth. Running
`npm run version:sync` regenerates the public native constants used in report
envelopes:

- Swift Package products: `CrumbCore` and `CrumbUI`;
- CocoaPods: `CrumbSDKCore`, `CrumbSDKUI`, and the `CrumbSDK` convenience pod;
- Maven: `com.crumbsdk:crumb-core` and `com.crumbsdk:crumb-ui`.

The CocoaPods distribution names are registry-safe package identities. Their
Swift module names remain `CrumbCore` and `CrumbUI`, so installation through
CocoaPods or Swift Package Manager exposes the same imports. The Maven group is
owned through `crumbsdk.com`; Android source packages remain under `dev.crumb`
to preserve the native API.

The Android UI artifact exposes Core as an API dependency, so an application
that installs `crumb-ui` receives `crumb-core` transitively. Both AARs include
source JARs and consumer shrinking rules.

## Rehearsal gate

Run the local package rehearsal with:

```bash
npm run distribution:verify
```

It performs the following work in temporary directories:

1. checks that generated native version constants match `VERSION`;
2. publishes both Android modules to a temporary Maven repository;
3. checks their coordinates, source JARs, POM dependency scope, and packaged
   consumer rules;
4. builds a separate Android application using only the staged Maven artifact;
5. builds and import-validates all three podspecs without pushing to CocoaPods;
6. builds a separate Swift executable against both package products.

After a commit is pushed, validate the actual remote Swift Package at that
immutable commit without creating a tag:

```bash
npm run distribution:verify:remote -- <full-commit-sha>
```

This repeats the same gates and makes the Swift consumer clone the GitHub
repository at the supplied revision. A branch name is intentionally not
accepted because it can move during verification.

## Current public installation

Release candidate `0.0.1-rc.3` is public through Swift Package Manager,
CocoaPods, and Maven Central. Pin the exact prerelease while the SDK is in
preview; the eventual stable `0.0.1` release will use the same package names.

```swift
.package(
    url: "https://github.com/alexander126/crumb.git",
    exact: "0.0.1-rc.3"
)
```

```ruby
pod "CrumbSDK", "0.0.1-rc.3"
```

```kotlin
implementation("com.crumbsdk:crumb-ui:0.0.1-rc.3")
```

The SDK source and artifacts are licensed under Apache-2.0; the hosted
`crumb-cloud` product remains private and proprietary.

The separately confirmed public publication workflow and its credential
boundary are documented in [Native registry publication](registries.md).
