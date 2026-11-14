# Install Crumb

The published preview is **0.0.1-rc.7**. The full public documentation now lives
in the [Fumadocs site](../website/README.md), with three quickstarts and separate
feature guides. Preview features on the SDK main branch are not necessarily in
the published packages; check [release availability](../website/content/docs/releases.mdx).
See the [rc.7 release and migration notes](releases/0.0.1-rc.7.md) when upgrading.

## Native iOS

Use Swift Package Manager with `https://github.com/alexander126/crumb.git` at
exact version `0.0.1-rc.7`, linking both CrumbCore and CrumbUI. Requires iOS 15
or newer. New native releases use SPM; the older rc.3 CocoaPods installation is
a separate legacy path, not an rc.7 pod release.

Crumb pods from rc.4 onward depend on `PLCrashReporter`, whose upstream pod
declares an iOS minimum of 12.0. Xcode 27 rejects that, and CocoaPods applies a
pod's own declared minimum even when the Podfile asks for a higher platform, so
such an installation built with Xcode 27 must also select Crumb's
`PLCrashReporter` wrapper podspec from its Podfile. The legacy rc.3 pods do not
depend on PLCrashReporter and are unaffected, as are SPM installations.

Follow the [iOS quickstart](../website/content/docs/quickstarts/ios.mdx) for
installation, startup, invocation, masking, verification and troubleshooting.

## Native Android

Add `com.crumbsdk:crumb-ui:0.0.1-rc.7` from Maven Central. Requires Android API
26 or newer and Java 17 bytecode.

Follow the [Android quickstart](../website/content/docs/quickstarts/android.mdx)
for Gradle, Application and manifest setup through your first dashboard report.

Start Crumb in your application's main process. The local report queue is
single-process, so the SDK refuses to run in a secondary process declared with
`android:process` — `CrumbReporter.install` returns `false` there.

## React Native

Install `@crumbsdk/react-native@0.0.1-rc.7` with
`react-native-nitro-modules@0.37.1`. Requires React Native 0.79+, iOS 15.1+ and
Android API 26+.

Run `npx --no-install crumb setup` for guided configuration, or follow the manual
steps in the quickstart. rc.7 bundles its iOS dependencies: Expo needs the Crumb
config plugin, and bare iOS apps need the supplied Podfile helper. Rebuild the
native app after installation. The source-map uploader is included automatically.

The [React Native quickstart](../website/content/docs/quickstarts/react-native.mdx)
contains both setup paths and one shared configuration and verification flow.

### Expo development builds

**Before prebuild, add `"@crumbsdk/react-native"` to your active Expo `plugins`
array.** Guided setup can edit `app.json`, but dynamic `app.config.ts`/`.js`
files require a manual edit. Preserve existing plugins and ensure every selected
variant includes Crumb; see [the config example and verification step](react-native-setup.md#required-for-expo-register-the-config-plugin).
This step is required even when source maps are disabled.

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
