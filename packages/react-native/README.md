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
    javascriptCrashCapture: {
      enabled: true,
      maximumBreadcrumbs: 32,
      maximumBreadcrumbBytes: 16_384,
    },
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

## JavaScript crash capture

JavaScript crash capture is opt-in and disabled by default. Set
`diagnostics.javascriptCrashCapture.enabled` to `true` to preserve fatal
JavaScript exceptions and unhandled promise rejections. The adapter performs a
bounded, sanitized synchronous handoff through Nitro before calling the
existing React Native or host handler, so Crashlytics, Sentry, and other host
handlers remain installed and continue to run.

After a relaunch, native code validates and deduplicates the pending record,
then commits it to the same durable report queue used by the reporter. Offline
reports remain pending until the normal uploader receives an acknowledgement.
The record includes the failure type, message, bounded stack, release/bundle
identity, recent Crumb breadcrumbs, and only custom-context keys explicitly
allowlisted by the host. It does not include native crash data, arbitrary
memory, Redux/store state, request bodies, or response bodies.

The native handoff also saves a bounded snapshot of the original process ID,
capture time, CPU, memory, thread count, thermal state and connectivity when the
corresponding evidence categories are enabled. These are measurements taken
while handling the JavaScript failure, not measurements from the next launch.
iOS reads task/thread counters (at most 256 threads for CPU) and waits at most
30 ms for a local connectivity observation. Android takes one 20 ms CPU sample
and reads current process/network metadata. Neither runs continuously, calls
app-provided log/health callbacks, probes HTTP, captures GPU utilization or
installs native fatal handlers. With thread-stack evidence enabled, iOS also
captures bounded native frames using PLCrashReporter's live report API, and
Android captures managed Java/Kotlin stacks. Native image offsets are not dSYM
source locations. An unavailable measurement remains unavailable.

Breadcrumbs come from `Crumb.log` and optional console capture. They remain
bounded and sanitized; disabling logs removes them at handoff and recovery.
Corrupt or oversized optional snapshot data is discarded without discarding an
otherwise valid crash. Existing records without snapshots still recover their
original JavaScript cause and breadcrumbs.

Opt into recent rendering evidence separately with
`diagnostics.renderingEnabled: true` (default `false`) and install the reporter.
This enables a foreground-only buffer of five one-second numeric buckets, capped
at 1,000 observations per bucket, cleared on background or disabled performance
evidence. The snapshot is frozen before failure stack collection and survives
relaunch only while current settings still allow it. No frame images are stored.

iOS reports `CADisplayLink` intervals and slow observations. Android reports
window frame duration and, on API 31+ when supplied by the OS, GPU frame duration.
Slow observations exceed 1.5 times the relevant frame budget. These are bounded
observations, not complete frame coverage, FPS, or GPU utilization. iOS GPU time
remains unavailable. Android zero GPU time is distinct from missing GPU time.
Envelopes with native stacks or rendering use version 1.1; upgrade the consuming
service before distributing an enabled SDK. Existing 1.0 reports remain valid.

The breadcrumb limits default to 32 entries and 16 KiB. They can be lowered or
raised within the package bounds (50 entries and 65,536 bytes maximum). A
native termination wrapper with the same fingerprint is folded into the
JavaScript occurrence without replacing its cause.

For a local fatal-fixture check, enable the option in one of the included
development-build examples and trigger the example's JavaScript failure action.
The next launch should show one recovered `javascript_crash` occurrence; do not
enable this option in production without first reviewing the collection notice
and handler interaction for the host application.

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

### Capture the active screen

Opt in to a static screen label so reports and recovered JavaScript crashes show
where the user was. This is separate from native controllers and the source file
identified by a crash stack. Existing reports cannot gain screen context retroactively.

For React Navigation, register once beside the root container. The helper handles
initial readiness, focused nested routes, modals, subsequent state changes and
listener cleanup without adding a navigation dependency to Crumb:

```tsx
import { useEffect } from 'react';
import { NavigationContainer, useNavigationContainerRef } from '@react-navigation/native';
import Crumb from '@crumbsdk/react-native';

function App() {
  const navigationRef = useNavigationContainerRef();
  useEffect(() => Crumb.trackReactNavigation(navigationRef), [navigationRef]);
  return <NavigationContainer ref={navigationRef}>{/* navigators */}</NavigationContainer>;
}
```

For Expo Router, put this in the root layout. `useSegments()` retains file-based
templates such as `/orders/[id]`; do not pass `usePathname()` or search parameters:

```tsx
import { Slot, useSegments } from 'expo-router';
import { useExpoRouterScreen } from '@crumbsdk/react-native';

export default function RootLayout() {
  useExpoRouterScreen(useSegments());
  return <Slot />;
}
```

For a custom navigator, set the current static label when the visible screen changes:

```ts
Crumb.setScreen('Checkout', { route: ['Shop', 'Checkout'] });
Crumb.setScreen(null); // Clear when no app screen is active.
```

Choose one owner for the current context. Each label is limited to 128 UTF-8 bytes
and the focused hierarchy to eight labels. Use static names, never user IDs,
account names, full URLs or search strings. Invalid manual input clears the
previous label and throws; integrations clear unavailable or invalid state.
Crumb never reads route parameters or records a navigation history. Standard
text redaction and the effective `custom_context` evidence policy apply.
The reporter freezes this context when it opens, including shake invocation;
a JavaScript failure freezes it at the native handoff. Recovery retains the
original screen and reapplies current privacy policy, without substituting the
relaunch screen. This does not identify the cause of a crash or add native fatal
crash interception.

Screen context uses envelope **1.2**. Deploy a consumer supporting 1.2 before
shipping an app with this integration. Reports without screen context retain
their existing 1.0/1.1 format.
