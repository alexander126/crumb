# BrowserStack real-device matrix

BrowserStack App Automate supplies the hosted physical devices used for the
wide T10 compatibility pass. A local phone remains useful for a real shake
smoke test, but contributors do not need to own the full support matrix.

The runner uses the native automation stack for each hosted OS target:

- XCUITest for current iOS, uploaded as `CrumbDemo.ipa` and an XCUI runner zip.
- BrowserStack-managed Appium/XCUITest for iOS 15, using the same IPA. This
  keeps the compatibility runner supplied and signed by BrowserStack instead
  of copying Apple-internal testing frameworks from a newer Xcode into the app.
- Espresso for Android, uploaded as the demo APK and instrumentation APK.

BrowserStack re-signs the disposable iOS build for its devices. Crumb's demo
contains only synthetic checkout data and a placeholder write key. Do not use a
production host application or real customer data in this matrix.

## One-time setup

1. Copy `.env.example` to `.env`.
2. Add the BrowserStack username and access key from the BrowserStack account
   settings. Never commit them or paste them into test output.
3. Add the Apple development team identifier used to build the XCUI runner.
4. Leave network logs and app profiling disabled for a new/free account. Enable
   them after the BrowserStack plan confirms those features are available.

The ignored `.env` file contains:

```dotenv
BROWSERSTACK_USERNAME=your_username
BROWSERSTACK_ACCESS_KEY=your_access_key
APPLE_DEVELOPMENT_TEAM=your_team_id
BROWSERSTACK_NETWORK_LOGS=false
BROWSERSTACK_APP_PROFILING=false
```

## Prepare and run

Build the uploadable artifacts without sending anything externally:

```sh
npm run browserstack:prepare
```

Confirm the account exposes the four required OS targets:

```sh
npm run browserstack:devices
```

The runner automatically selects one hosted real device for iOS 15, current
stable iOS, legacy Android, and current stable Android. It prefers Android
8.0/API 26, but explicitly falls back to Android 8.1/API 27 when BrowserStack's
catalog does not expose 8.0. The fallback is nearest-version evidence, not a
substitute for the API 26 gate. If an account tier does not permit the selected
model, set the corresponding exact `Device-OS` value in `.env`:

```dotenv
BROWSERSTACK_IOS_15_DEVICE=
BROWSERSTACK_IOS_CURRENT_DEVICE=
BROWSERSTACK_ANDROID_LEGACY_DEVICE=
BROWSERSTACK_ANDROID_CURRENT_DEVICE=
```

Upload both native demos and execute the matrix:

```sh
npm run browserstack:run
```

Platform-specific `prepare` and `run` scripts are available when only one side
needs to be repeated. `npm run browserstack:run:ios:current` runs only the
current-iOS quality suite, while `npm run browserstack:run:ios:legacy` repeats
only the iOS 15 Appium lifecycle flow. The command waits for BrowserStack to
finish and writes the non-secret build response to `.browserstack/results/`. Videos,
device logs, screenshots, result bundles, and optional performance reports
remain available in the BrowserStack dashboard.

For release evidence, retain at least one labeled still from the masked local
report flow on every successful device. BrowserStack recordings can be
downloaded through the session APIs and a representative frame stored in the
ignored `.browserstack/evidence/` directory. Keep the associated
build and session IDs beside the still so the image is traceable to its test
result.

## Coverage

The native suites cover programmatic invocation, compact shake confirmation,
dismissal and re-entry, rotation/recreation, background/foreground recovery,
masked screenshot preview/removal, report review, and local submission. Every
cloud session uses a fresh install and synthetic data. Current-device suites
also cover dark appearance, large-text reachability, and warm 20-run p50/p95
quality budgets.

The BrowserStack compatibility matrix is paired with these checks:

- An optional physical-motion shake smoke test on a locally available device.
  The cloud suites use the deterministic simulated-shake entry point because
  BrowserStack's sensor-shake support is plan and OS limited.
- Exact Android API 26 compatibility is run on the Release emulator suite when
  BrowserStack's catalog starts at Android 8.1/API 27. For `0.0.1`, this exact
  minimum-OS pass is paired with the nearest hosted physical API 27 pass.
- Binary and payload budgets enforced by `npm run quality:verify`.

Record BrowserStack build and session IDs in the release candidate evidence.
Do not commit uploaded apps, XCUI runners, APKs, videos, or trace bundles.

## BrowserStack references

- [XCUI test setup](https://www.browserstack.com/docs/app-automate/xcuitest/getting-started)
- [Appium session results and recordings](https://www.browserstack.com/docs/app-automate/api-reference/appium/sessions)
- [Espresso test setup](https://www.browserstack.com/docs/app-automate/espresso/getting-started)
- [XCUI session results and result bundles](https://www.browserstack.com/docs/app-automate/api-reference/xcuitest/sessions)
- [Real-device selection](https://www.browserstack.com/docs/app-automate/appium/set-up-tests/select-devices)
- [App performance profiling](https://www.browserstack.com/docs/app-automate/appium/debug-failed-tests/app-performance)
