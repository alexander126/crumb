# Active screen context — issue 27

Synthetic validation on 2026-09-07:
- Root `npm ci`, public contract fixtures and version check: passed.
- Swift tests: 52 passed, including frozen context, restart serialization,
  privacy denial and bounded failure-store fallback.
- Android tests: core 43, UI 14, demo 3 passed; queue storage behavior preserved.
- React Native `yarn quality`: 25 tests plus lint, types, module output and
  Nitrogen generation passed. No mandatory navigation dependency was added.
- React Native iOS Release and Android Debug demo builds passed.
- Native distribution verification passed (CocoaPods, SwiftPM and Maven consumer).
- Final iOS link contribution: 1,028,246 / 1,048,576 bytes.
- Final Android Core AAR: 261,756 / 262,144 bytes; UI: 144,034 / 262,144.
  Unused generated methods in private persistence DTOs were replaced with narrow
  copy methods/fields. Public model semantics and file formats remain intact.

Argent drove the iPhone 17 Pro Max running iOS 26.4.1 simulator. A JavaScript
fatal fixture on Checkout saved the current screen; relaunch on Home and recovery
retained Checkout in envelope 1.2. A normal report also saved Checkout; the native
review preview displayed Checkout. Only synthetic labels and local packets were
used; raw records and device artifacts remain outside this public repository.

Unit tests separately cover React Navigation readiness, nested focus, modals,
parameter avoidance and cleanup; Expo Router template segments and cleanup;
manual clearing/limits; and JS report invocation before asynchronous presentation.
This is not native fatal-crash interception, navigation history or a claim that
the active screen caused the failure. Physical-device performance and hosted
rollout were not tested in this change.

Gate: a consumer supporting envelope 1.2 must be available before apps enable
screen capture. Older reports remain unchanged. No publication, deployment or
merge was performed by the implementation worker.
