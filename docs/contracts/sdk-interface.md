# Native SDK interface v1

Swift and Kotlin should expose the same concepts even when language conventions
differ.

## External interface

| Operation | Behaviour |
| --- | --- |
| `start(configuration)` | Validates and stores configuration. It starts no sampler, tracker, or upload. Repeating the same configuration is harmless; replacing it requires a process restart. |
| `installReporter()` | Registers native lifecycle handling. When shake is configured, the accelerometer is enabled only while the app is foregrounded. It does not collect report diagnostics. Repeated installation is harmless. |
| `show()` | If programmatic invocation is configured, captures the host screen before presentation, opens the native reporter immediately, and starts one short diagnostic probe independently. It does not require a health endpoint. |
| React Native JavaScript crash capture | Optional and disabled by default. When enabled by the adapter, a fatal JavaScript exception or unhandled rejection is sanitized and synchronously handed to native storage; recovery later queues it through the normal durable report lifecycle. Native SDKs do not install native crash hooks. |

## Configuration

The minimum configuration contains:

- project write key;
- environment;
- app version and native build;
- optional JavaScript/OTA bundle version;
- allowed invocation methods;
- screenshot capture options, including a bounded maximum pixel dimension and
  encoded byte size;
- an optional public Crumb `/health` URL and a bounded 250–5000 ms probe
  timeout; the URL must be absolute HTTP(S) without credentials, query values,
  or a fragment;
- bounded recent-log options (enabled, lookback, entry count, and byte limit)
  plus an optional application log provider;
- privacy options whose defaults are safe.
- an optional built-in reporter theme and visible-field allowlist; the
  description remains required;
- an optional evidence allowlist covering screenshot, performance, network,
  logs, thread stacks, health checks, and explicitly allowlisted custom
  context;
- bounded application metadata and string-only custom context;
- an optional versioned workspace policy URL that can only narrow the local
  configuration;
- an optional ingestion base URL; leaving it unset disables network upload
  without disabling durable local submission.
- an optional React Native JavaScript crash-capture block. It can enable fatal
  JavaScript exception and unhandled-rejection capture and bound the attached
  breadcrumbs; it does not enable native crash capture.

The project key is an identifier and write credential embedded in an
application binary. It is not treated as a secret and never authorizes reads.

## Ordering and failure behaviour

- `start` validates configuration synchronously.
- A configured workspace policy is fetched and cached asynchronously. Before a
  valid fresh or cached policy exists, optional evidence and custom context are
  disabled while the required description-only report remains available.
- Workspace policy failures, expiry, and malformed documents never broaden the
  locally configured evidence or context allowlist.
- Calls made before a successful `start` have no external side effects.
- `installReporter` is called once after `start`; sensor ownership and lifecycle
  recovery stay inside the SDK rather than in each host screen.
- `show` refuses duplicate presentation while a reporter is already visible.
- A report session preserves its form or draft state across rotation and
  backgrounding. Destruction of its host without recreation ends the session.
- The screenshot is captured before Crumb UI is placed over the host app.
- Text inputs and host-marked regions are made fully opaque before the first
  PNG encoding. The final preview, SHA-256, manifest, storage, and transport all
  consume the same bounded encoded bytes.
- Removing a screenshot removes its bytes and manifest; it does not rewrite an
  enabled capture attempt as configuration-disabled.
- CPU, memory, app-owned threads, thermal state, and network state are sampled
  only after invocation. The SDK does not keep a rolling performance window.
- The optional Crumb API health check is a bounded `HEAD` probe. Only a final
  `2xx` is healthy. The stored diagnostic includes its host, outcome, status
  code, latency, and bounded failure classification—not response content.
- Device connectivity and Crumb API reachability are independent evidence. An
  unavailable API is recorded as context and never prevents local submission.
- Recent logs are collected only when a report opens. iOS may read the current
  process's unified-log history. Android only reads an application-supplied,
  in-memory provider; Crumb never requests privileged system-log access.
- Log providers return a prompt snapshot. Crumb filters it to the configured
  lookback, keeps the newest entries within both entry and byte limits, and
  sanitizes sensitive values before the draft can be submitted.
- Android captures a bounded live snapshot of managed Java/Kotlin thread
  stacks. iOS does not attach the collector's own call stack as if it explained
  the reported problem; all-thread stack capture is marked unavailable.
- Unsupported data is marked unavailable. In particular, neither production
  platform exposes a truthful instantaneous per-thread GPU measurement.
- Failure to capture one diagnostic source never fabricates a value or closes
  the reporter.
- A submitted report is committed to durable local storage before upload begins.
- The reporter confirms success only after the envelope and all referenced
  artifact bytes are durably committed as one queue item. A failed local commit
  leaves the review available to retry and does not evict an older report.
- Queue state is `pending`, `uploading`, or `failed`. Work found in `uploading`
  after process restart returns to `pending` for a future uploader retry.
- Reporter installation resumes queued delivery only while the host is in the
  foreground. Connectivity observation exists only while retryable queue work
  remains; retry delays grow from one second to a bounded 60 seconds.
- Cancelling foreground upload work returns its current report to `pending`.
  It never deletes the local report or changes the reporter's success result.
- The write key is available only to the transport settings seam. It is never
  placed in report-time UI settings, envelopes, stored failure reasons, or
  signed artifact requests.
- React Native JavaScript capture is disabled unless its `enabled` flag is
  true. Enabled handlers run the existing React Native, host, Crashlytics, or
  Sentry callback according to the host runtime's existing chain after Crumb's
  bounded synchronous handoff. A persistence failure never prevents the host
  callback from running.
- A recovered JavaScript occurrence is first committed to the same durable
  report queue as an on-demand report. It remains `pending` when offline and is
  removed only after the normal idempotent upload acknowledgement. A duplicate
  native termination wrapper is merged by fingerprint and cannot replace the
  stored JavaScript cause.

The full configuration, workspace-policy, precedence, bounds, and migration
contract is defined in [SDK configuration and privacy precedence](sdk-configuration.md).

The durable storage layout, integrity checks, limits, and recovery rules are
defined in [Local report queue](local-report-queue.md).
The delivery lifecycle and retry classification are defined in
[Native uploader](native-uploader.md).

General native crash reporting, analytics, session replay, automatic hang
detection, user identity, navigation tracking, attributes, and arbitrary
breadcrumbs are not part of this interface. The only breadcrumb-like data is
the bounded Crumb log snapshot explicitly attached to an opted-in React Native
JavaScript failure.

## Internal seams

Storage, capture, sanitization, transport, and clocks remain internal seams.
They are not exposed through the external interface merely to support tests.
Production and in-memory adapters may satisfy those seams inside each native SDK.
