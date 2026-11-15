# Crumb React Native consumer example

This Expo development-build app installs the public
`@crumbsdk/react-native` package from npm. It is intentionally separate from
the package-local example, which links the SDK source during library
development.

The example runs on Expo SDK 58 with React Native 0.88.1 and targets iOS 16.4
or newer and Android API 26 or newer. iOS 16.4 is the minimum Expo SDK 58
allows. Its app template adopts the UIKit scene life cycle, which iOS 27
requires of any app built with Xcode 27. These are the example's own versions:
`@crumbsdk/react-native` supports React Native 0.79 or newer and iOS 15.1 or
newer.

## Configure

```sh
cd examples/react-native
npm install
cp .env.example .env.local
```

Replace `EXPO_PUBLIC_CRUMB_PROJECT_KEY` with a write key from the Crumb
dashboard. Keep `EXPO_PUBLIC_CRUMB_INGESTION_URL` to upload reports, or remove
it to keep reports local-only.

These values are compiled into the development app. The project write key is
designed for SDK ingestion, but it should still be managed as app
configuration and never reused as an account credential.

## Run

Crumb includes native code, so this app requires an Expo development build and
does not run in Expo Go.

```sh
npm run ios
# or
npm run android
```

In the app, choose **Start Crumb**, then **Open reporter**. Shaking a physical
device also opens the reporter after installation.

## Verify the integration

```sh
npm run typecheck
npm run build:ios
npm run build:android
```

Each native build script performs a clean platform prebuild first so it proves
the package autolinks from a generated consumer project.

The app keeps `@crumbsdk/react-native` and `react-native-nitro-modules` as
direct, exact dependencies because both ship native code and must resolve as a
single copy in the host application.

## Dependency audit note

As of Expo 58.0.25, npm reports a moderate `minimatch` advisory through
`@expo/fingerprint`, which Expo uses at build time to hash the native project.
npm counts it three times, once each for `minimatch`, `@expo/fingerprint` and
`expo`. Its automated remediation would downgrade Expo to SDK 52, so the
example intentionally stays on the current SDK and relies on Expo to update
that transitive build-time dependency.
