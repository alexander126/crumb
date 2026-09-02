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

Install the public package and its required Nitro runtime as direct
dependencies:

```sh
npm install @crumbsdk/react-native@0.0.1-rc.3 \
  react-native-nitro-modules@0.37.1
```

### Expo

Crumb contains native code and does not run in Expo Go. Add a development
client and configure the native minimum targets:

```sh
npx expo install expo-dev-client expo-build-properties
```

```json
{
  "expo": {
    "plugins": [
      [
        "expo-build-properties",
        {
          "android": { "minSdkVersion": 26 },
          "ios": { "deploymentTarget": "15.1" }
        }
      ]
    ]
  }
}
```

Create or rebuild the native development client:

```sh
npx expo run:ios
# or
npx expo run:android
```

No Crumb-specific Expo config plugin is required. Expo Prebuild and React
Native autolinking install `CrumbSDKCore` and `CrumbSDKUI` from CocoaPods on
iOS and `crumb-ui` from Maven Central on Android.

### Bare React Native

React Native autolinking discovers Crumb after installation. Install iOS pods,
then rebuild the applications:

```sh
npx pod-install
npm run ios
# or
npm run android
```

No manual `AppDelegate`, `MainApplication`, or package-list registration is
needed. Set `platform :ios, "15.1"` in a manually maintained Podfile and
`minSdk = 26` in the Android app module. The package uses
[`react-native-nitro-modules`](https://nitro.margelo.com/) for its JSI bridge.

The [complete all-platform guide](../../docs/getting-started.md) covers Expo,
bare React Native, native iOS, and native Android from installation through a
submitted test report.

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
  javascriptCrashCapture: {
    enabled: true,
  },
  reporter: {
    theme: 'system',
    visibleFields: ['category', 'description'],
  },
  evidence: ['screenshot', 'performance', 'network', 'logs', 'thread_stacks', 'health_check'],
  customContext: {
    values: { account_tier: 'trial' },
    allowedKeys: ['account_tier'],
  },
  workspacePolicy: {
    url: 'https://policy.example.com/sdk/v1/policy',
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

Reporter theme, evidence, custom context, and workspace policy use the same
native-owned contract as Swift and Kotlin. A configured policy fetch is
non-blocking and fail-closed: optional evidence stays disabled until a fresh or
valid cached policy is accepted, while the description-only report path
remains available. See the [shared configuration contract](../../docs/contracts/sdk-configuration.md).

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

## Optional JavaScript crash capture

JavaScript crash capture is disabled unless `javascriptCrashCapture.enabled` is
explicitly `true`. When enabled, the adapter installs a small wrapper around
React Native's `ErrorUtils` fatal handler and the global
`onunhandledrejection` hook. It records the sanitized JavaScript error before
calling the existing host handler, then calls that handler exactly once with
the original arguments and return behavior. Existing Sentry, Crashlytics, and
host handlers must be installed before Crumb so the chain is preserved.

```ts
await Crumb.start({
  projectKey: 'crumb_sdk_replace_me',
  environment: 'development',
  release: { bundleVersion: 'ota-update-id' },
  javascriptCrashCapture: {
    enabled: true,
    maximumBreadcrumbs: 20,
    maximumBreadcrumbBytes: 16_384,
  },
});
```

The native SDK synchronously stores a bounded, app-private handoff when the
runtime permits. On the next `installReporter()` call, it becomes one normal
durable queue item and follows the existing offline retry and server
acknowledgement lifecycle. JavaScript failures and a later native termination
wrapper are deduplicated by a bounded fingerprint without replacing the
JavaScript cause.

Only the error type, message, raw JavaScript stack, release/bundle identity,
bounded Crumb breadcrumbs, and explicitly allowlisted custom context are
eligible. Request/response bodies, Redux or store state, arbitrary object
graphs, and general native crash hooks remain outside the feature. Disabling
the option installs no JavaScript crash or rejection handlers.

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

## Publishing

Releases publish from the immutable `react-native-v<version>` Git tag through
the `react-native-npm-publish.yml` GitHub Actions workflow. The workflow uses
npm trusted publishing (OIDC), so no long-lived npm write token is stored in
GitHub.

Configure the package's npm trusted publisher with these exact values:

- Provider: GitHub Actions
- Organization or user: `alexander126`
- Repository: `crumb`
- Workflow: `react-native-npm-publish.yml`
- Environment: leave empty
- Allowed action: `npm publish`

Use the `next` distribution tag for prereleases and `latest` for stable
versions. The workflow verifies the package version, immutable Git tag,
distribution tag, and explicit publication confirmation before it publishes.
