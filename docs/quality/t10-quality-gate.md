# T10 quality gate

T10 passed on 2026-08-29. Automated privacy and boundary checks, exact minimum
Android compatibility, and the hosted physical-device matrix all passed.
Hosted BrowserStack build and session identifiers, videos, screenshots, and
device logs are retained with the release candidate. The repeatable setup is
documented in
[`browserstack-device-matrix.md`](browserstack-device-matrix.md).

## Supported platforms

| Platform | Supported floor | Required physical coverage |
| --- | --- | --- |
| iOS | iOS 15 | one device on the oldest available iOS 15 build and one on the current iOS release |
| Android | API 26 | exact API 26 Release emulator, nearest hosted physical API 27 device, and one device on the current Android release |

BrowserStack's available physical-device catalog starts at Android 8.1/API 27.
For `0.0.1`, the accepted API 26 exception is therefore an exact API 26 Release
emulator pass plus the nearest physical API 27 pass. The minimum SDK remains
26; field issues will trigger either a compatibility fix or a later
support-floor change.

The package manifests enforce these floors. The complete matrix covers
programmatic invocation, shake prompt, rotation or recreation, background and
foreground, screenshot preview/removal, local submission, offline recovery,
light and dark appearance, and the largest accessibility text size that keeps
all actions reachable.

## Release budgets

All latency values are warm p95 over 20 runs on a non-debug physical device.
Memory is measured after opening, reviewing, closing, and allowing a five-second
settling period.

| Budget | Limit |
| --- | ---: |
| `Crumb.start` wall time | 5 ms |
| `Crumb.start` disk and network activity | 0 bytes, 0 requests |
| invocation to usable form | 120 ms |
| diagnostics without a health probe | 500 ms |
| screenshot attachment ready | 750 ms |
| retained resident-memory increase after close | 20 MiB |
| Android `crumb-core` release AAR | 256 KiB |
| Android `crumb-ui` release AAR | 256 KiB |
| combined stripped iOS link contribution | 750 KiB |
| report envelope | 1 MiB |
| one screenshot artifact | 25 MiB |
| transport overhead above envelope and artifact payloads | 64 KiB |

When an optional Crumb health URL is configured, one `HEAD /health` request is
allowed after explicit report invocation. It has no request body and may take
the configured timeout plus 250 ms of scheduling tolerance. No other network
request is allowed before the report has committed to the private local queue.

## Privacy and security guarantees

- Diagnostics begin only after explicit programmatic or foreground-shake
  invocation. `start` does not sample, persist, or transmit diagnostics.
- Text inputs and host-marked regions are rendered opaque before screenshot
  encoding. Only the masked, bounded PNG is hashed, queued, and uploaded.
- Logs are prompt host snapshots, bounded by time, count, and bytes. Bearer
  values, credential-like keys, email addresses, payment-card-shaped numbers,
  URL query values, URL user information, and control characters are redacted
  on device.
- The project write key stays in transport settings and never enters UI,
  envelopes, artifacts, logs, or queue metadata. Header-unsafe and oversized
  configuration values are rejected at startup.
- Queue commits are app-private, atomic, integrity-checked, bounded, and never
  evict an existing report to accept a new one.
- The native SDKs do not install uncaught-exception handlers or initialize,
  configure, or wrap Sentry, Crashlytics, or the host logging system. The
  React Native adapter's opt-in JavaScript-only handler is covered by adapter
  tests for disabled mode, callback chaining, synchronous handoff failure, and
  unhandled-rejection capture.

## Accessibility, appearance, and localization

- Interactive targets are at least 44 pt on iOS and 48 dp on Android.
- iOS uses Dynamic Type; Android uses scalable text and avoids fixed-height text
  containers for report content. Modal content contains accessibility focus and
  announces diagnostic and save state changes.
- Semantic colors support light and dark appearance with contrast-safe primary
  actions. Screenshot previews expose image/button semantics instead of an
  editable-control role.
- User-facing reporter strings live in the Swift package and Android resource
  catalogs. `0.0.1` supplies English; additional translations can be added
  without changing the report wire values.
- Descriptions are capped at the envelope's 4,000-scalar/character boundary in
  the UI and are validated again while building the envelope.

## Repeatable checks

Run from the repository root:

```sh
npm run quality:verify
```

This runs the Swift and Kotlin suites, builds release AARs, enforces supported
OS floors, checks both localization catalogs, rejects native crash-handler or
crash-SDK initialization in native sources, and enforces Android binary
budgets. React Native package quality additionally exercises the opt-in
JavaScript capture and Nitro bridge surface.

The physical pass records device model, OS build, release configuration,
20-run p50/p95 latency, before/after memory, link contribution, request count,
payload bytes, and an accessibility/dark-mode result. Attach profiler traces to
the release candidate rather than committing machine-specific trace bundles.

## Development evidence — 2026-08-27

- iPhone 17 Pro simulator, iOS 26.4: no UI hangs or reported leaks; reporter
  construction sampled at 22 ms.
- Android API 36 emulator before optimization: screenshot drawing appeared on
  the main thread during reporter opening, with 25 janky frames in the profiled
  flow. After moving window copy to `PixelCopy` and masking, PNG encoding, and
  hashing to a worker thread, the profile contained 14 emulator jank frames and
  no screenshot capture or encoding on the main-thread stacks. The remaining
  long frames were dominated by QEMU/SurfaceFlinger waits and require physical
  device confirmation.
- Android release artifacts after the automated T10 pass were 145,786 bytes for
  core and 121,127 bytes for UI, both below budget.
- iPhone 17 Pro simulator in dark appearance and the largest accessibility text
  size kept the reporter scrollable with every action reachable; the masked
  preview exposed image/button semantics.
- Android API 36 emulator in dark appearance at 200% font scale kept report
  content and actions reachable, with 48 dp category and removal controls and
  image/button semantics on the masked preview.

## Physical-device sign-off — 2026-08-29

| Device | Coverage | Result | BrowserStack evidence |
| --- | --- | --- | --- |
| iPhone 13, iOS 15 | four lifecycle and local-draft flows | 4/4 passed | session `871a9af275b825c266982bb84c4e84af393bf6a0` |
| iPhone 17, iOS 26.6 | local draft, forced dark/large text, and 20-run budgets | 3/3 passed | build `85ac827a7a1a7e82af91a4a7a3668be0f75916fe`, session `16303a0ba93c3acfcdc0c8e73458c076f785590e` |
| Samsung Galaxy Note 9, Android 8.1/API 27 | complete native suite and 20-run budgets | 7/7 passed | build `1f6c844fd8ee7a27d2243ba6ba569a7a7a493ffd`, session `c06c256d5c48a4131ab06ce692499e52e20e6d7b` |
| Google Pixel 11, Android 17 | complete native suite and 20-run budgets | 7/7 passed | build `1f6c844fd8ee7a27d2243ba6ba569a7a7a493ffd`, session `60eda34a2e7f7972aa19a9d3be38d42574a04e38` |
| Android 8.0/API 26 emulator | exact supported-floor Release suite and 20-run budgets | 7/7 passed | local Release result retained under the Android test outputs |

Hosted videos, device logs, screenshots, and result bundles are retained in
BrowserStack. Representative ignored stills live under
`.browserstack/evidence/` and remain traceable to the build and session IDs.

## Measured performance

| Target | start p95 | form p95 | diagnostics p95 | screenshot p95 | retained memory |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPhone 17, iOS 26.6 | 0.002 ms | 68.865 ms | 341.317 ms | 61.284 ms | 5,128,240 B |
| Samsung Galaxy Note 9, API 27 | 0.061 ms | 26.400 ms | 381.928 ms | 267.111 ms | 0 B |
| Google Pixel 11, Android 17 | 0.027 ms | 13.001 ms | 300.673 ms | 166.311 ms | 0 B |
| Android 8.0/API 26 emulator | 0.026 ms | 15.188 ms | 248.314 ms | 108.873 ms | 0 B |

Android reported zero app-private storage and network deltas during `start` on
both hosted physical devices. Their hardened `/proc` configuration did not
expose the process write counter, so that counter is recorded as unavailable,
not zero; the exact API 26 run exposed it and measured zero. On iOS, automated
boundary tests verify that `start` cannot reach diagnostics, queue, or transport
work, while the physical harness records timing and retained memory.

The combined stripped iOS link contribution measured 561,690 bytes. Envelope,
single-artifact, and 64 KiB transport-overhead boundaries pass in both native
test suites.
