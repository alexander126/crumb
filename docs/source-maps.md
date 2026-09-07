# Upload React Native source maps from CI

The [source-map CLI](../packages/source-maps/README.md) and
[v1 upload contract](contracts/source-map-upload.md) bind release artifacts to
an exact crash release. The CLI is an implementation preview, pending package
publication and hosted compatibility validation. These instructions describe
the build inputs to prepare; they do not enable native crash capture.

## Keep the app and CI identity aligned

Supply an immutable `release.bundleVersion` to `Crumb.start`. Use that same
value for `--bundle-version`. The app version and native build number must also
match the distributed application. In a build pipeline, generate the metadata
once and pass it to both the app and upload step. Do not guess EAS auto-incremented
build numbers from a local config file.

```ts
// Synthetic release metadata. Replace with values from your build pipeline.
release: {
  appVersion: '1.2.3',
  nativeBuild: '42',
  bundleVersion: 'build-abc123',
}
```

This is the `release` object inside the existing
[Crumb configuration](../packages/react-native/README.md#configure). JavaScript
crash capture must separately be enabled there. The native queue preserves
captured JavaScript failures across relaunch; source maps do not add crash hooks.

Use the exact same build's bundle and final map. The upload CLI calculates both
SHA-256 hashes and can compare them to archived expected hashes. That detects
changed bytes, but cannot prove a map describes a bundle. Validate one known
synthetic crash location against the final artifacts before a release.

## Bare React Native with Hermes

Build the release normally. On Android, retain the final generated bundle and
composed map, typically:

```text
android/app/build/generated/assets/react/release/index.android.bundle
android/app/build/generated/sourcemaps/react/release/index.android.bundle.map
```

These are build-variant-dependent paths. Do not use the intermediate
`*.packager.map` by itself for Hermes bytecode frames. On iOS, set `SOURCEMAP_FILE`
in the React Native bundle build phase, then archive the final `main.jsbundle`
and the map from that same archive. The upstream
[release debugging guide](https://reactnative.dev/docs/debugging-release-builds)
explains source-map generation and checking a known trace with `metro-symbolicate`.

After your build completes, run this from the prepared CLI checkout (or replace
`node dist/cli.js` with the installed, pinned `crumb-source-maps` executable):

```sh
node dist/cli.js upload \
  --url "$CRUMB_UPLOAD_ORIGIN" \
  --platform android \
  --app-version "$APP_VERSION" \
  --native-build "$NATIVE_BUILD" \
  --bundle-version "$JS_BUNDLE_VERSION" \
  --bundle "$ANDROID_FINAL_BUNDLE" \
  --source-map "$ANDROID_FINAL_MAP"
```

Run again with `--platform ios` and the iOS binary's identity and artifacts.
Set `CRUMB_SOURCE_MAP_TOKEN` through CI secrets. The origin and file variables
above are explicit inputs from your release job, not values discovered by Crumb.
Add `--dry-run` first to check the inputs without credentials or uploads.

## Metro without a later Hermes compilation step

If a pipeline ships Metro's JavaScript output directly, create the bundle and
map together using the project's pinned React Native CLI:

```sh
npx react-native bundle --platform ios --dev false --entry-file index.js \
  --bundle-output artifacts/main.jsbundle \
  --sourcemap-output artifacts/main.jsbundle.map
```

Create the output directory first and use the application's actual entry file.
For Android use `--platform android` and distinct output paths. Upload this pair
only when these exact bytes are the distributed build. If the native pipeline
later compiles it to Hermes bytecode, upload that final bytecode and composed
map instead. Do not generate an unrelated Metro bundle after an EAS/native build.

## Expo development builds and EAS Build

Crumb requires native code and does not support Expo Go. For store binaries
built with EAS, preserve the final native build bundle and composed map inside
the build job, after native compilation, and invoke the same command shown above.
Use a build hook/custom job that runs where those files still exist; starting an
EAS build from local CI does not put its remote output files on the local disk.
Configure source-map generation through the application's native build setup.

Use the final native version/build chosen by EAS and the bundle identity embedded
in that artifact. Keep `CRUMB_SOURCE_MAP_TOKEN` as a build secret, never an
`EXPO_PUBLIC_*` value or part of the generated application. See Expo's
[environment-variable guidance](https://docs.expo.dev/eas/environment-variables/usage/).

## EAS Update / OTA exports

Choose an immutable bundle identity before exporting, include it in the app's
Crumb configuration, and load the intended build environment before the export.
Do not confuse a mutable update channel or runtime compatibility version with
a unique bundle version. Export with source maps using the project's pinned CLI:

```sh
npx expo export --platform all --source-maps --output-dir dist
```

The [Expo CLI export options](https://github.com/expo/expo/blob/main/packages/%40expo/cli/src/export/index.ts)
document source-map emission. For each platform, take the final bundle and its corresponding map from this
export. Use the export metadata/output to select exact files; do not take the
first file matching a wildcard. Upload them using the command above and the
native app version/build of the binaries eligible for this update. If several
native builds receive the update, register the pair for each exact release tuple.

When the release owner is ready to publish the update, preserve that export:

```sh
eas update --input-dir dist --skip-bundler --platform all \
  --channel "$EAS_CHANNEL" --environment "$EAS_ENVIRONMENT" --non-interactive
```

`--skip-bundler` reuses the exported bundle instead of generating another one.
The [EAS CLI reference](https://docs.expo.dev/eas/cli/#eas-update) documents these
flags. Pin the project's Expo/EAS versions and verify their output filenames and
Hermes behavior; the Crumb CLI does not infer paths, trigger a build or publish
an update. Publish only artifacts whose identity and source location have passed
your release verification.

## Acceptance before enabling a release

- Dry-run succeeds for both platform artifact pairs.
- A fixture or authorized service accepts each pair; repeating it returns the
  same upload ID, and changed bytes with the old release identity return a conflict.
- An opt-in synthetic JavaScript failure survives relaunch and reaches Crumb.
- The resulting report resolves to the expected original file, function and line.
- A missing or mismatched map is shown as unavailable, never guessed from a
  neighboring release. Uploading a map is not evidence this last step works.

The CLI tests use only synthetic artifacts and a local service. Hosted acceptance,
real release builds and package publication remain separate release validation.
