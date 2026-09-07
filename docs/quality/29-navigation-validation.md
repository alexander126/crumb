# Automatic navigation tracking — issue 29

Validated on 2026-09-07 with real navigation libraries and release-mode Hermes
bundles. React Native 0.83.10, Expo 55.0.31, React Navigation 7.3.18,
native-stack 7.18.10, Expo Router 55.0.18, react-native-screens 4.23.0,
safe-area-context 5.6.2 and Nitro 0.37.1.

| Integration | iPhone 17 Pro Max, iOS 26.4.1 | Android 16/API 36, arm64 emulator |
| --- | --- | --- |
| React Navigation | Passed | Passed |
| Expo Router | Passed | Passed |

For each combination, Argent exercised initial Home capture, a modal report,
a report after modal dismissal, navigation back to Home and into the nested
screen again, and a deliberate fatal JavaScript fixture. The app relaunched on
Home; explicit Start Crumb recovered the original failure. Three normal reports
and one recovered crash were checked per combination: 16 envelope assertions.

React Navigation saved Home (`[Home]`), Receipt (`[Receipt]`) and Checkout
(`[Shop, Checkout]`) with source `react_navigation`. Both recovered failures
retained Checkout. Synthetic customer IDs and query values were absent from
serialized envelopes.

Expo Router saved `/` (`[/]`), `/receipt` (`[receipt]`) and `/orders/[id]`
(`[orders, [id]]`) with source `expo_router`. Both recovered failures retained
`/orders/[id]`. The actual synthetic order ID and query value were absent from
serialized envelopes. Screen context contained only name, route and source.
Native review previews showed the same logical screen names.

Both fixtures intentionally omit an upload destination and use local synthetic
configuration. Raw device files, screenshots and build logs remain in temporary
private evidence storage; no real customer data, credentials or hosted settings
are included here. Device tooling required a simulator reconnection and a
correction for Android's letterboxed tap coordinates; these were test-harness
issues, not SDK changes.

Validation:
- `yarn install --immutable`, `yarn quality`: passed (25 tests, lint, typecheck,
  module/declaration output and Nitrogen generation).
- `yarn pack:check`: passed; navigation dependencies and fixtures stay in the
  example workspace, outside the distributable SDK.
- iOS Release and Android Release builds: passed for both selected entries.
- Existing unit tests cover listener cleanup, invalid labels, readiness,
  bounded nested focus and asynchronous report invocation. Listener cleanup was
  not separately induced by unmounting the live demo.
- Native SDK implementation, protocol, package version and release artifacts are
  unchanged. This is JavaScript crash recovery, not native fatal-crash interception.
- Physical devices and hosted upload were not part of this local navigation matrix.

Repeat the flows using [the navigation demo guide](../../packages/react-native/example/NAVIGATION.md).
