# Install Crumb

The published preview is **0.0.1-rc.3**. The full public documentation now lives
in the [Fumadocs site](../website/README.md), with three quickstarts and separate
feature guides. Preview features on the SDK main branch are not necessarily in
the published packages; check [release availability](../website/content/docs/releases.mdx).

## Native iOS

Use Swift Package Manager with `https://github.com/alexander126/crumb.git` at
exact version `0.0.1-rc.3`, linking both CrumbCore and CrumbUI, or install
`pod "CrumbSDK", "0.0.1-rc.3"`. Requires iOS 15 or newer.

Follow the [iOS quickstart](../website/content/docs/quickstarts/ios.mdx) for
installation, startup, invocation, masking, verification and troubleshooting.

## Native Android

Add `com.crumbsdk:crumb-ui:0.0.1-rc.3` from Maven Central. Requires Android API
26 or newer and Java 17 bytecode.

Follow the [Android quickstart](../website/content/docs/quickstarts/android.mdx)
for Gradle, Application and manifest setup through your first dashboard report.

## React Native

Install `@crumbsdk/react-native@0.0.1-rc.3` with
`react-native-nitro-modules@0.37.1`. Requires React Native 0.79+, iOS 15.1+ and
Android API 26+.

The [React Native quickstart](../website/content/docs/quickstarts/react-native.mdx)
contains both setup paths and one shared configuration and verification flow.

### Expo development builds

Use the Expo tab in the React Native quickstart. Expo Go is unsupported; create
a native development build with local Expo tools or EAS. Rebuild after native
dependency changes.

### Bare React Native

Use the bare-app tab in the same quickstart. Autolinking discovers Crumb; install
iOS pods and rebuild the native application.

## Verify the integration

Copy the project key and ingestion URL from SDK setup, initialize once, open the
reporter from a button, inspect screenshot masking and submit a synthetic report.
Find it in the matching dashboard project and environment. Reports saved without
an ingestion URL remain in the app-private queue.

For missing reports or evidence, use the [troubleshooting guide](../website/content/docs/troubleshooting.mdx).
