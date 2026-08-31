# Native distribution preparation

Task 9 prepares and tests Crumb's native package shapes without publishing a
public release. The first registry publication, release candidate, license and
privacy documents, checksums, and public tag remain Task 14 work.

## Package identities

The repository `VERSION` file is the SDK version source of truth. Running
`npm run version:sync` regenerates the public native constants used in report
envelopes:

- Swift Package products: `CrumbCore` and `CrumbUI`;
- CocoaPods: `CrumbCore`, `CrumbUI`, and the `Crumb` convenience pod;
- Maven: `dev.crumb:crumb-core` and `dev.crumb:crumb-ui`.

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

## Future public installation

These forms become public only after Task 14 creates and publishes the approved
release. They document the prepared consumer interface; they are not a claim
that the registries contain `0.0.1` today.

```swift
.package(url: "https://github.com/alexander126/crumb.git", from: "0.0.1")
```

```ruby
pod "Crumb", "0.0.1"
```

```kotlin
implementation("dev.crumb:crumb-ui:0.0.1")
```

Do not create a tag, push a podspec, or target a public Maven repository as
part of Task 9. The SDK source and artifacts are licensed under Apache-2.0;
the hosted `crumb-cloud` product remains private and proprietary.
