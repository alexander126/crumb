# Source-linked React Native demo

This Expo demo links the React Native adapter and both native SDKs from this
checkout. It includes reporting, logs, a deliberate fatal JavaScript error and
an unhandled rejection. Expo Go cannot load its native code.

## Configure and build

From `packages/react-native`:

```sh
corepack yarn install --immutable
corepack yarn nitrogen
corepack yarn prepare:ios
cp example/.env.example example/.env.local
```

Edit the ignored `.env.local` with your project's SDK write key. Set the
ingestion URL to upload reports, or omit it to keep reports local. Use a new
immutable bundle version for every release bundle/map pair. These values are
embedded in the app; never use an account credential or source-map upload
credential as the SDK write key. Keep private build logs, files and recordings
outside the public repository.

Generate the native projects with `corepack yarn example expo prebuild --clean`.
This replaces generated native files, so keep any native customization in the
Expo configuration/plugin. The existing `build:ios` and `build:android` scripts
build debug apps. For crash/source-map acceptance, use release builds instead:

```sh
cd example
mkdir -p /tmp/crumb-demo-maps
SOURCEMAP_FILE=/tmp/crumb-demo-maps/main.jsbundle.map \
xcodebuild ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -workspace ios/CrumbReactNativeExample.xcworkspace \
  -scheme CrumbReactNativeExample -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO

cd android
./gradlew :app:createBundleReleaseJsAndAssets --rerun-tasks \
  -Dorg.gradle.jvmargs=-Xmx4g -PreactNativeArchitectures=arm64-v8a
./gradlew :app:assembleRelease -Dorg.gradle.jvmargs=-Xmx4g \
  -PreactNativeArchitectures=arm64-v8a
```

The explicit Android bundle step is required after changing `.env.local`:
Gradle can otherwise reuse an older bundle because those environment values
are not tracked as task inputs. Package the regenerated bundle with the second
command, then retain its final map and verify the report's bundle version and
environment before uploading release files.

The iOS command targets an Apple Silicon simulator. The Android command targets
an arm64 emulator and uses the example's development signing configuration.
Neither is a store-distribution build. Both default to app version `1.0.0`,
native build `1`; use the actual installed identity if you customize them.

## Verify crash recovery

1. Install and launch the release demo on the selected test device.
2. Choose **Start Crumb**.
3. Choose **Trigger JS fatal fixture**, then **Cancel** to verify cancellation.
4. Choose the fatal fixture again and confirm **Crash now**. It should terminate
   the app. The named `crashDemoAtKnownSourceLine` function is the known source.
5. Relaunch the same app without reinstalling it, then choose **Start Crumb**.
   This recovers the saved failure and, if configured, uploads it.
6. Before uploading maps, verify that the crash report retains the captured
   stack with an explicit missing-map state.
7. Upload the exact final bundle/map pair and verify the fixture's source
   function and line. A mismatch must retain the captured stack.

The unhandled-rejection action is separate; it may record evidence without
terminating the app. Do not equate that behavior with the fatal test.

## Retain the exact files

- iOS bundle: `ios/build/Build/Products/Release-iphonesimulator/CrumbReactNativeExample.app/main.jsbundle`
- iOS final map: the absolute `SOURCEMAP_FILE` supplied above.
- Android bundle: `android/app/build/generated/assets/react/release/index.android.bundle`
- Android final map: `android/app/build/generated/sourcemaps/react/release/index.android.bundle.map`
- Android APK: `android/app/build/outputs/apk/release/app-release.apk`

The iOS bundle inside the `.app` is final Hermes bytecode. Its sibling outside
the `.app` is an intermediate JavaScript bundle. Do not upload intermediate
packager/compiler maps, regenerate maps after the build, or use a different
bundle version. See [the source-map guide](../../../docs/source-maps.md) for
CLI upload and build-pipeline integration.
