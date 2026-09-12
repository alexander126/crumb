# Automatic screen tracking demos

These fixtures use real React Navigation 7 and Expo Router, independently of the
manual screen example. Dependencies are example-only and are not shipped in the SDK.

From `packages/react-native`, run `corepack yarn install --immutable` and
`corepack yarn nitrogen`. In ignored `example/.env.local`, choose one entry:

```dotenv
EXPO_PUBLIC_CRUMB_NAVIGATION=react-navigation
EXPO_PUBLIC_CRUMB_BUNDLE_VERSION=navigation-react-local-1
```

Use `expo-router` for the other entry and a new bundle version for every build.
Omit the navigation variable to run the existing manual-screen example.
Run `corepack yarn example expo prebuild --clean` to regenerate the native demo
projects (this replaces generated native files). Build a release app to exercise
fatal JavaScript crash recovery:

```sh
cd example
SOURCEMAP_FILE=/tmp/navigation-ios.map xcodebuild ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  -workspace ios/CrumbReactNativeExample.xcworkspace -scheme CrumbReactNativeExample \
  -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO
cd android
./gradlew :app:createBundleReleaseJsAndAssets --rerun-tasks -PreactNativeArchitectures=arm64-v8a
./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a
```

Rebuild after changing the entry. The explicit Android bundle task prevents
reuse of a bundle with old environment values. These are simulator/emulator
builds, not store-distribution artifacts.

Both navigation fixtures keep reports on the device. They use a synthetic key
by default and do not configure an upload destination. Choose **Start Crumb**
after each launch; this also recovers a saved JavaScript failure.

React Navigation: Home → Open Shop → nested Checkout → Open Receipt (modal) →
Dismiss Receipt → Checkout → Go Home. The container installs
`Crumb.trackReactNavigation` once and unsubscribes when unmounted. Synthetic
customer ID and query values are navigation parameters, not screen labels.

Expo Router: Home → Open Order → `/orders/[id]` → Open Receipt → Dismiss Receipt
→ `/orders/[id]` → Go Home. The root layout passes `useSegments()` to
`useExpoRouterScreen`. The `synthetic-order-42` ID and `synthetic-query` value
must never appear in screen context; the dynamic segment remains `[id]`.

At each transition, open the reporter, enter a synthetic description, review
**Screen at the time**, and submit locally. On Checkout/Order details, choose
**Trigger JS fatal fixture → Crash now**. Relaunch on Home and choose Start
Crumb; the recovered envelope must retain Checkout or `/orders/[id]`, not Home.
Inspect the local queue with platform test tooling. Keep raw device files and
local configuration out of public issues and pull requests.

See [validation evidence](../../../docs/quality/29-navigation-validation.md).
Integration references: [React Navigation screen tracking](https://reactnavigation.org/docs/screen-tracking/)
and [Expo Router segments](https://docs.expo.dev/versions/v55.0.0/sdk/router/#usesegments).
