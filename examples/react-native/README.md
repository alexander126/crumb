# Crumb React Native consumer example

This Expo development-build app installs the public
`@crumbsdk/react-native` package from npm. It is intentionally separate from
the package-local example, which links the SDK source during library
development.

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

As of Expo SDK 55, npm reports a moderate `uuid` advisory through Expo CLI's
native project-generation dependency chain. npm's automated remediation would
downgrade Expo to SDK 46, so the example intentionally stays on the current
SDK and relies on Expo to update that transitive build-time dependency.
