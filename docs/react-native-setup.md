# Guided React Native and Expo setup

This guide targets published `@crumbsdk/react-native@0.0.1-rc.6`. Guided setup
first shipped in rc.5 and is absent from rc.4. See the
[rc.6 release notes](releases/0.0.1-rc.6.md) and rebuild after upgrading.

## Install, configure, verify

Install `@crumbsdk/react-native` and the compatible `react-native-nitro-modules`
peer using your existing package manager. The SDK now includes its pinned
source-map uploader; do not install a second Crumb package manually. Build
commands require Node.js 22 or newer. The uploader is not imported into the app.

After installation, run the package's `crumb setup` command from the app folder:

```sh
npx --no-install crumb setup
```

The command detects Expo or bare React Native, asks whether to configure source
maps, previews which files it will edit, and requests confirmation. It preserves
existing plugins and wraps supported Metro/Xcode/Gradle configuration. Run it
again safely after an interrupted setup. Review the resulting version-control
diff before committing.

## Required for Expo: register the config plugin

**Complete this step before prebuild, even when source maps are disabled.**
`crumb.config.json` controls optional source-map uploads; it does not register
native dependencies. Keep `@crumbsdk/react-native` once in the active Expo
`plugins` array so prebuild can register the bundled iOS pods.

- **Only `app.json`:** apply the changes previewed by `crumb setup`, then confirm
  `expo.plugins` contains `"@crumbsdk/react-native"`. Keep your other plugin entries.
- **`app.config.ts`, `app.config.js` or another dynamic config:** add the plugin
  manually to the returned config's `plugins` array. Setup preserves dynamic
  config and prints this manual step; creating `crumb.config.json` does not
  complete it. An entry in `app.json` can be lost if the dynamic config replaces
  its plugins.

### Conditional configs and app variants

Keep your current selection logic and add the plugin after selecting a config.
For example, where `previewConfig` and `productionConfig` are your existing Expo
config objects with top-level `plugins`:

```ts
const selectedConfig =
  process.env.EXPO_PUBLIC_APP_VARIANT === 'preview'
    ? previewConfig
    : productionConfig;

export default {
  ...selectedConfig,
  plugins: [
    ...(selectedConfig.plugins ?? []),
    '@crumbsdk/react-native',
  ],
};
```

Keep the selected config's existing plugins. Add Crumb once, either in this
shared return value or in every variant you intend to build. If your selected
object is wrapped in `expo: { ... }`, merge into that object's `expo.plugins`
instead; Expo ignores sibling fields outside the wrapper. The environment
variable and variant names above are examples; use your app's existing selection.

### Verify the selected config, then rebuild

Run this with the same environment variables you use for prebuild or EAS. It
prints only plugin names and exits unsuccessfully if Crumb is missing:

```sh
npx expo config --type prebuild --json | node -e "
const config = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const names = (config.plugins ?? []).map(p => Array.isArray(p) ? p[0] : p);
console.log(names);
if (!names.includes('@crumbsdk/react-native')) process.exit(1);
"
```

Repeat for every variant you intend to build. The output must include
`@crumbsdk/react-native`. A successful `crumb doctor` check alone does not verify
that a dynamic config includes the plugin.

Rebuild the native development client after changing plugins. For local iOS:

```sh
npx expo prebuild --platform ios
npx expo run:ios
```

For Android, use `--platform android` and `npx expo run:android`, or your existing
EAS development-build workflow. Expo Go and restarting Metro cannot apply native
plugin changes. Continue with app initialization only after native setup.

## Optional source-map build hooks

For a reproducible noninteractive setup, copy the upload origin from your
project's integration instructions:

```sh
npx --no-install crumb setup --source-maps --upload-url https://upload.example.invalid --apply
```

The origin above is synthetic. Omitting `--apply` outside an interactive terminal
only previews the changes. Run from an installed project so `npx` resolves the
local Crumb executable.

Dynamic Expo config and ESM/TypeScript Metro files receive precise manual
instructions instead of automatic rewrites. Kotlin Gradle scripts and ambiguous
Xcode projects also require the manual hooks below. Setup does not guess which
of several app projects to modify or insert initialization into an unknown entry
point.

Add your dashboard's normal `Crumb.start` configuration. If you chose JavaScript
crash reporting, explicitly enable `diagnostics.javascriptCrashCapture.enabled`.
Remove manual `release.bundleVersion`: a release build now supplies the identity
for its actual JavaScript. Native app version/build default to the installed
binary and are frozen when a JavaScript failure occurs. A conflicting manual
bundle identity is rejected by `Crumb.start`; custom pipelines can omit the
automatic hooks and continue supplying the full explicit release configuration.

Ordinary bug reports work without source-map setup or an upload credential.

## Build secret and upload behavior

Create a dedicated source-map upload credential for the project and set
`CRUMB_SOURCE_MAP_TOKEN` in the environment running release builds. For EAS,
configure it as a build secret. Never place it in `crumb.config.json`, an app
initialization snippet, an `EXPO_PUBLIC_*` variable, or a command-line argument.

The checked-in configuration contains only:

```json
{
  "version": 1,
  "sourceMaps": {
    "enabled": true,
    "uploadUrl": "https://upload.example.invalid",
    "strict": false
  }
}
```

Native release hooks generate an immutable bundle identity before Metro runs.
Metro includes a small non-secret polyfill before app startup. The uploader
uses the final native bundle and composed Hermes source map, verifies that the
map contains that build identity, and calls the existing v1 upload contract.
Debug builds do not upload. The Expo plugin installs the same hooks during
prebuild; no separate EAS hook script is needed for native release builds.

Upload failures warn by default and preserve the native build. Set
`CRUMB_SOURCE_MAP_STRICT=1`, or `sourceMaps.strict: true`, to fail the release job
if artifacts cannot be verified. Set `CRUMB_SOURCE_MAP_DRY_RUN=1` for local
artifact validation without reading the upload credential or sending files;
this is not evidence of a successful hosted upload.

Each upload retains a copy of its exact bundle, map, release metadata, and retry
receipt under the build's Crumb directory. Keep these private and archive them
with release artifacts if your build workspace is disposable. Failed uploads
print the receipt location:

```sh
npx --no-install crumb retry --receipt /path/to/retained/upload-ios-1.0.0-42.json
```

Retry checks byte identity and does not rebuild. If retained bytes have changed,
restore the original files. The configured upload origin must still identify
the same project/environment. The upload-only credential cannot read reports.

## Local and dashboard verification

```sh
npx --no-install crumb doctor
```

Doctor checks installed dependencies, the Metro wrapper, and whether an upload
credential exists in this environment. It does not claim that a credential is
valid, that native hooks have executed, that files reached Crumb, or that a crash
was decoded. After a release build, send a synthetic fatal JavaScript crash,
relaunch the app, and confirm the dashboard shows its expected original source
file and line. Missing or mismatched maps must retain the raw crash explicitly.

## EAS Update

Keep the supported native release targets explicit: a runtime version or update
channel is not a unique native build. The upload contract requires one entry
for every eligible platform/version/build tuple. For example:

```json
[
  { "platform": "ios", "appVersion": "1.0.0", "nativeBuild": "42" },
  { "platform": "android", "appVersion": "1.0.0", "nativeBuild": "42" }
]
```

Save this as `crumb-targets.json`, then create and upload a new export:

```sh
npx --no-install crumb export --output dist/next-update --targets crumb-targets.json
```

The helper uses the app's installed Expo CLI, injects the export's own identity,
requests final source maps, and selects bundle files from Expo's export metadata.
All requested target artifacts are checked before uploads. An existing output
directory is never overwritten. The command does not publish an OTA update.
Use `--dry-run` to validate locally without uploading.

Publish that exact export with the project's pinned EAS CLI and its normal
environment/channel options, using `--input-dir dist/next-update --skip-bundler`.
Do not rebuild after upload. Embedded bundles and older/rolled-back updates each
carry their own identity. `.crumb/` holds local export metadata and is ignored by
setup; exported maps/bundles must also remain outside public source control.

Automatic discovery of all eligible native builds and arbitrary custom export
formats are not supported. Use the [advanced uploader](source-maps.md) for a
pipeline outside this supported path.

## Manual hooks for custom project layouts

Wrap the existing Metro configuration with `withCrumb` from
`@crumbsdk/react-native/metro`, preserving its other options. For CommonJS:

```js
const { withCrumb } = require('@crumbsdk/react-native/metro');
module.exports = withCrumb(existingConfig);
```

Expo apps must keep `@crumbsdk/react-native` in their config plugins. Rebuild the
native projects after configuration changes.

Bare Android applications apply the package's `tools/crumb.gradle` from their app
module after the React Native plugin. The hook connects to the actual bundle
tasks and reads final variant output versions; it does not assume a `release/`
artifact path. Kotlin DSL can apply the same Groovy script via `apply(from = ...)`.

Bare iOS applications keep the bundled-native Podfile helper and wrap their
existing bundle phase with `tools/ios.cjs`, passing the original shell command as
arguments. The wrapper preserves that phase's exit code and uses its Xcode build
settings and processed plist. Use setup's generated phase as the reference; never
replace a custom bundle command with a generic rebuild command.
