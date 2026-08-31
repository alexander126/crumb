# @crumbsdk/react-native

The official Nitro Module adapter for Crumb. It is intentionally thin: the
published Swift and Kotlin SDKs continue to own reporter presentation,
screenshot masking, diagnostics, durable storage, and upload.

## Requirements

- React Native 0.79 or newer
- iOS 15.1 or newer (the native Crumb SDK itself remains iOS 15)
- Android API 26 or newer
- An Expo development build or a native React Native app

Crumb contains native code and therefore does not run in Expo Go.

## Install

```sh
yarn add @crumbsdk/react-native react-native-nitro-modules
cd ios && pod install
```

Expo apps should create a development build after installation:

```sh
npx expo prebuild
npx expo run:ios
# or
npx expo run:android
```

No Crumb-specific Expo config plugin is required. React Native autolinking installs
`CrumbSDKCore` and `CrumbSDKUI` from CocoaPods on iOS and `crumb-ui` from Maven
Central on Android. The package uses
[`react-native-nitro-modules`](https://nitro.margelo.com/) for its JSI bridge.

## Configure

```ts
import Crumb from '@crumbsdk/react-native';

await Crumb.start({
  projectKey: 'crumb_sdk_replace_me',
  environment: __DEV__ ? 'development' : 'production',
  release: {
    // Optional. Crumb reads the native app version and build automatically.
    bundleVersion: 'ota-update-id',
  },
  upload: {
    ingestionUrl: 'https://your-crumb-api.example.com',
  },
  diagnostics: {
    healthCheckUrl: 'https://your-crumb-api.example.com/health',
    logs: {
      captureConsole: true,
    },
  },
});

await Crumb.installReporter();
```

For Expo Updates, pass the active update identifier as `bundleVersion`. Crumb
does not depend on `expo-updates`, so applications remain in control of how
their OTA identity is sourced.

Open the reporter from application UI when needed:

```ts
const opened = await Crumb.show();
```

Shake invocation is enabled by default while the app is foregrounded. Configure
`invocation: ['programmatic']` to disable it.

## JavaScript logs

```ts
Crumb.log('info', 'Checkout started', { cartItems: 3 });
Crumb.log('error', 'Checkout failed', { error });
```

The adapter keeps a bounded in-memory log buffer and mirrors entries into the
native SDK as they occur. This means opening the native reporter never waits on
the JavaScript thread. Metadata is depth- and size-bounded before it crosses the
native boundary, then sanitized again by the native SDK before submission.

Optional console capture wraps only `console.warn` and `console.error`, preserves
the original methods, and can be disabled at any time:

```ts
Crumb.disableConsoleCapture();
```

Crumb never captures network bodies, Redux state, navigation history, arbitrary
application object graphs, or analytics events.

## Development

This package was created with `create-react-native-library` and includes an Expo
development-build example.

```sh
corepack yarn install
corepack yarn nitrogen
corepack yarn quality
corepack yarn example ios
corepack yarn example android
```
