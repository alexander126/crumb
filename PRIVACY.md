# Crumb native SDK privacy boundary

This document describes the data-handling behavior of the Crumb iOS and Android
SDKs. It is product documentation, not a replacement for the host
application's privacy notice or data-processing agreement.

## Collection starts only after invocation

`Crumb.start` validates in-memory configuration. It does not capture a screen,
read logs, inspect diagnostics, write a report, or make a network request.
Crumb begins a one-time collection only after a person explicitly opens the
reporter through the host application's control or a foreground shake.

The React Native adapter has a separate, disabled-by-default JavaScript crash
capture option. When the host explicitly enables it, the adapter may observe
fatal JavaScript exceptions and unhandled promise rejections, chain the host's
existing handlers, and persist one bounded sanitized occurrence for recovery on
the next launch. This is the only automatic occurrence path; native crash
handlers are not installed.

## Potential report contents

A submitted report can contain:

- the reporter's selected category and written description;
- an optional contact value when the host enables that field;
- a bounded screenshot captured before the reporter appears;
- app, device, operating-system, release, locale, display, memory, CPU,
  thermal, thread, and network-path context available on the platform;
- a bounded snapshot of recent host-provided or process-visible logs; and
- the result of one optional Crumb service-health request; and
- for an explicitly enabled React Native JavaScript crash occurrence, the
  sanitized error type, message, raw JavaScript stack, release-bundle identity,
  bounded breadcrumbs, and explicitly allowlisted custom context.

Native Crumb does not install a crash handler, inspect unrelated applications,
read Android system logcat, continuously sample the process, or intercept
arbitrary application network bodies. The React Native adapter's opt-in
JavaScript wrappers do not capture arbitrary memory, Redux or store state,
request or response bodies, or unallowlisted context.

## On-device minimization

Text inputs and host-marked sensitive regions are rendered opaque before a
screenshot is encoded. The unmasked image is not persisted or uploaded. Logs
are constrained by age, count, and bytes and are sanitized on-device for known
credentials, authorization values, email addresses, payment-card-shaped
numbers, URL credentials and query values, and control characters.

The SDK rejects invalid or oversized report fields and artifacts before queue
commit. A project write key is transport configuration and is never added to a
report envelope, artifact, log, or queue manifest.

## Storage and transmission

Drafts, recovered JavaScript crash occurrences, and submitted reports are stored
in the host application's private container. Submission commits atomically to a
size-bounded local queue before the reporter confirms completion. When the host
configures an ingestion URL, Crumb uploads queued reports over HTTPS with
idempotency and bounded retry. When no ingestion URL is configured, reports
remain local.

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
