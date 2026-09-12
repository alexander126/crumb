# Crumb native SDK privacy boundary

This document describes the data-handling behavior of the Crumb iOS and Android
SDKs. It is product documentation, not a replacement for the host
application's privacy notice or data-processing agreement.

## Collection defaults and opt-ins

`Crumb.start` validates in-memory configuration. The native SDK does not
capture a screen, read logs, inspect diagnostics, write a report, or make a
network request. Crumb begins a one-time on-demand collection only after a
person explicitly opens the reporter through the host application's control or
a foreground shake.

The React Native adapter has a separate JavaScript-only option that is disabled
by default. When explicitly enabled, it listens for fatal JavaScript
exceptions and unhandled promise rejections so it can synchronously preserve a
small sanitized record before the runtime terminates. It chains the existing
React Native, host, Crashlytics, or Sentry handler and does not install a native
uncaught-exception hook.

A separate `diagnostics.renderingEnabled` option is also disabled by default.
After reporter installation, enabling it retains five foreground one-second
buckets of numeric frame observations in memory (up to 1,000 per bucket).
Backgrounding or disabled performance evidence clears the buffer. Reports can
attach display intervals on iOS, or frame duration and available GPU duration
on Android. No images, navigation trail, or GPU utilization are inferred.
Current collection settings are applied again when recovering a saved failure.

## Potential report contents

A submitted report can contain:

- the reporter's selected category and written description;
- an optional contact value when the host enables that field;
- a bounded screenshot captured before the reporter appears;
- app, device, operating-system, release, locale, display, memory, CPU,
  thermal, thread, and network-path context available on the platform;
- a bounded snapshot of recent host-provided or process-visible logs; and
- the result of one optional Crumb service-health request.

An opted-in React Native recovery report can additionally contain the
JavaScript failure type, message, bounded raw stack, release and bundle
identity, original-process metrics, bounded enabled platform thread stacks,
optional rendering aggregates, bounded Crumb breadcrumbs, and explicitly allowlisted string
context. It never includes arbitrary object graphs, Redux/store state,
request or response bodies, or native memory. A native termination wrapper is
stored only as a deduplicated marker and cannot replace the JavaScript cause.

Crumb does not install native crash handlers, inspect unrelated applications,
read Android system logcat or intercept
arbitrary application network bodies.

## On-device minimization

Text inputs and host-marked sensitive regions are rendered opaque before a
screenshot is encoded. The unmasked image is not persisted or uploaded. Logs
are constrained by age, count, and bytes and are sanitized on-device for known
credentials, authorization values, email addresses, payment-card-shaped
numbers, URL credentials and query values, and control characters.

The SDK rejects invalid or oversized report fields and artifacts before queue
commit. A project write key is transport configuration and is never added to a
report envelope, artifact, log, or queue manifest.

JavaScript crash handoffs are bounded independently at 50 occurrences, 32 KiB
per record, 2 MiB total, 32 breadcrumbs, and 16 KiB of breadcrumb data.
Corrupt handoff files are discarded safely; a full or unavailable store does
not change the host runtime's exception or rejection behavior.

## Storage and transmission

Drafts and submitted reports are stored in the host application's private
container. Submission commits atomically to a size-bounded local queue before
the reporter confirms completion. When the host configures an ingestion URL,
Crumb uploads queued reports over HTTPS with idempotency and bounded retry.
When no ingestion URL is configured, reports remain local.

The host application chooses the Crumb project, environment, collection
options, invocation controls, and whether upload is enabled. Server-side
retention, access, deletion, and regional processing are controlled by the
customer workspace and the hosted Crumb service terms.

## Host-application responsibilities

Applications integrating Crumb remain responsible for:

- accurately describing Crumb collection in their own privacy notice;
- selecting collection options appropriate for their users and jurisdiction;
- avoiding sensitive values in app-provided log snapshots;
- obtaining any consent required for screenshots, diagnostics, and contact
  information; and
- responding to end-user access or deletion requests through their configured
  Crumb workspace.

Security or privacy questions should be sent through the support contact named
in the customer's Crumb workspace until a public support address is announced.

Active screen context is a separate, explicit integration. It replaces one
bounded static screen name and focused hierarchy in memory, under the
`custom_context` evidence policy. Reports freeze it when the reporter opens;
JavaScript failures persist it at handoff, subject to the existing storage budget.
Recovery reapplies policy. React Navigation parameters are never read; Expo Router
uses template segments instead of actual paths or IDs. No navigation history is
recorded. Applications must supply static labels to the manual API.
