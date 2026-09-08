# Android recovered JavaScript crash delivery

Issue: #22. Base: `748a9835279605bd6e78d4a48a3a870bfe5bbb62`.

## Failure and fix

Installing the reporter after an Activity had resumed missed its lifecycle
callback, leaving delivery paused. Recovery also committed reports without
notifying delivery, and a wake received during an upload pass was discarded.

Installation now seeds the supplied resumed Activity. React Native supplies it
only while its lifecycle state is RESUMED. The native recovery bridge notifies
delivery on the main thread after persistence. A wake during a running pass
requests another pass before accepting the earlier queue snapshot as empty.
Backgrounding still cancels delivery; absent transport configuration remains
local-only. No wire format, crash capture policy, or release setting changed.

## Regression evidence

The regression command is:

```sh
./packages/android/gradlew -p packages/android :crumb-ui:testDebugUnitTest \
  --tests dev.crumb.ui.CrumbRecoveryUploadTest --max-workers=2
```

Before the fix, installation into an already-resumed Activity left the queue
pending and completed zero uploads (expected one). Seeding the Activity fixed
that case. Separate tests then reproduced delayed recovery and a queue
notification arriving before the empty pass's main-thread completion callback.
Adding recovery notification fixed the first; preserving the wake fixed the
second. All three passed after their respective fixes.

Seven tests now exercise real queue persistence and HTTP delivery against a
loopback synthetic receiver:

- already-resumed installation;
- recovery on a worker thread after an empty pass;
- notification while an empty pass's completion is queued;
- attaching a resumed host after Application-only installation;
- recovery during an actual Activity pause, followed by Activity resume;
- disabled upload configuration and repeated recovery;
- repeated wake notifications without duplicate completion.

Tests clean up their synthetic files and reset SDK singleton process state
between Robolectric cases. Existing native worker tests retain offline retry
and in-flight cancellation coverage.

## Release demo acceptance

On 8 September 2026, an Android API 36 arm64 emulator ran the source-linked
React Native 0.83.10 / Expo 55 release demo using the changed SDK sources.
The disposable build used synthetic configuration and a loopback receiver,
with local HTTP explicitly enabled only in its generated test manifest.

Argent drove Start Crumb, the confirmed JavaScript fatal fixture, relaunch, and
Start Crumb again. The fatal action terminated the process. The recovered
report completed about 0.5 seconds after the second Start tap, while the app
remained foregrounded and before dismissing its ready dialog. No reporter was
opened and no additional background/foreground transition occurred.

The receiver observed exactly one completion with the original JavaScript
error, stack and bundle identity. Both the durable report queue and pending
failure-record directory were empty after acknowledgement. Raw device evidence,
receiver output and APK checksum remain private and outside this repository.

## Validation

- `npm ci` and `npm run contracts:check`: passed.
- `npm run test:android`: 67 tests passed (43 core, 21 UI, 3 demo).
- React Native `yarn install --immutable`, `yarn quality`, `yarn pack:check`:
  passed; quality includes 25 JavaScript tests and Nitro generation.
- Source-linked Android release bundle regeneration and `:app:assembleRelease`:
  passed with Java 17 and arm64-v8a.
- Independent read-only review: no blocking findings; its lifecycle test
  suggestion was incorporated before the final Android suite.

No physical-device or hosted-service acceptance was performed for this fix.
iOS code is unchanged; the iOS suite and release artifact gates are left to the
existing PR CI. No package was published and no service was deployed.
