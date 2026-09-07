# SDK ingestion contract v1

## Infrastructure health

`HEAD /health` is an unauthenticated, bodyless process-liveness probe and
`GET /health` returns the small versioned health document. The endpoint does not
query PostgreSQL or object storage. Its precise behavior is defined in
[Crumb infrastructure health](infrastructure-health.md).

## Authentication

SDK routes accept a bearer project write key. The key is scoped to one project
and may only initialize, complete, or cancel SDK report uploads. Project and
tenant identity are resolved by the server and are never trusted from an SDK
payload.

Dashboard sessions and administrative credentials are not accepted on these
routes.

## Lifecycle

### `POST /sdk/v1/reports/init`

Creates or retrieves an upload session for the client-generated `report_id`.
The request carries envelope metadata and artifact manifests, but not large
artifact bytes. The response provides short-lived, narrowly scoped upload
locations.

Request:

```json
{ "envelope": { "schema_version": "1.0", "report_id": "rpt_..." } }
```

The elided envelope must satisfy `schemas/report-envelope.schema.json`. The
response has this shape:

```json
{
  "report_id": "rpt_...",
  "status": "initialized",
  "artifacts": [
    {
      "id": "art_...",
      "upload_id": "upl_...",
      "method": "PUT",
      "url": "https://short-lived-upload-location",
      "headers": { "content-type": "image/png" },
      "expires_at": "2026-08-24T09:15:00.000Z"
    }
  ]
}
```

Each URL names exactly one project/report/upload object key. An artifact body is
never proxied through the ingestion process.

### `POST /sdk/v1/reports/{reportId}/complete`

Marks an upload ready for server-side sanitization and processing. Completion is
idempotent and verifies artifact size and digest before accepting the report.
The response status is `accepted`; no report becomes visible to later processing
when an object is absent, oversized, truncated, or has a different SHA-256.
Verified bytes are copied to a sealed object key before the database transaction
marks the report accepted. A previously issued PUT URL therefore cannot mutate
the artifact referenced by an accepted report.

### `POST /sdk/v1/reports/{reportId}/cancel`

Cancels an unfinished upload. Cancellation is idempotent and cannot delete a
completed report.

## Persistence and isolation

- PostgreSQL keys reports and idempotency records by the authenticated project.
- Object keys begin with the server-resolved project UUID. A project identifier
  is never read from the envelope or request path.
- Write keys are stored only as SHA-256 hashes. They authorize no list, read,
  dashboard, project-management, or cross-project operation.
- The server re-applies sensitive-value sanitization to user description and
  diagnostic evidence before persisting the envelope.
- Report rows advance from `initialized` to `accepted` or `cancelled`. Artifact
  rows advance from `pending` to `verified` or `cancelled`.

## Idempotency

- The SDK generates `report_id` before it has network access.
- All lifecycle requests include `Idempotency-Key: <report_id>:<operation>`.
- Retrying the same operation with the same content returns the same durable
  session result. Init may refresh an expired short-lived upload URL without
  creating another report or artifact record.
- Reusing an idempotency key with different content is rejected.
- Idempotency keys are scoped to the authenticated project, so identical mobile
  report IDs in two projects remain independent.

## Limits

Concrete limits are server-configurable, but the v1 client must enforce its own
smaller bounds before writing to the offline queue. Oversized optional
artifacts are dropped with a local diagnostic; the user's description and
bounded on-demand diagnostic snapshot are retained.

The current server accepts at most a 1 MiB envelope, 10 artifacts, 25 MiB per
artifact, and 26 MiB for the combined envelope and declared artifact payload.
The native queue's bounds are no larger than these ingestion bounds.

## Errors

Errors use `{ "error": { "code": "...", "message": "..." } }`. Authentication
failures are `401`; malformed idempotency keys are `400`; invalid reports and
artifact verification failures are `422`; conflicting or terminal lifecycle
operations are `409`; and reports outside the authenticated project resolve as
`404`.

## Native thread stacks and rendering (envelope 1.1)

`schemas/report-envelope.v1.1.schema.json` adds the `native_threads` stack scope.
The original 1.0 schema remains unchanged and continues to cover managed
Java/Kotlin and React Native frames. Both platforms emit 1.1 when rendering
evidence is present; iOS also emits 1.1 for native stacks. Other reports retain 1.0. Deploy compatible ingestion
before distributing an SDK that emits 1.1; a 1.0-only service rejects 1.1.

During an explicitly enabled JavaScript failure handoff, `thread_stacks`
evidence captures native iOS frames or Android Java/Kotlin stacks. It does not
capture arbitrary native crashes or install a native exception handler.
Android C/C++ stacks and the original JavaScript failure stack are separate
from managed stacks. iOS thread IDs are indexes within this snapshot and
`capture_thread` identifies the handoff thread, not the origin of a native crash.

Saved optional stacks are capped at 12 KiB, 32 threads, 16 frames per thread,
and 512 UTF-8 bytes per frame, with a truncation marker. Empty frames are not
counted as evidence. Capture and recovery obey the thread-stack privacy policy;
record pressure drops stacks before existing metrics and then drops optional
metrics before the core JavaScript failure. No health probe is performed.

The iOS implementation uses PLCrashReporter 1.12.0 live reports, without enabling
its crash handler or asynchronous local symbolication. Its bounded temporary
report (at most 1 MiB) is removed by the live-report API. Only sanitized stack
frames are retained by Crumb. Available symbols are resolved after other threads
resume. Image basename, UUID and offset are retained when present; source files
and line numbers require separate native symbolication and are not claimed.
The dependency is pinned to the same published version for SwiftPM and CocoaPods.

`diagnostics.rendering` contains only numeric aggregates plus a source enum:
`ios_display_link` or `android_frame_metrics`. Required fields are `sample_count`
(1–5,000), `slow_frame_count`, `mean_frame_ms`, `max_frame_ms`, `gpu_sample_count`
and `last_frame_age_ms`. GPU durations (`mean_gpu_ms`, `max_gpu_ms`) are omitted
without GPU observations. iOS always has zero GPU observations. Millisecond
values are bounded to 5,000; capture requires a last observation younger than
five seconds. Slow counts use each observation's frame budget × 1.5.
Attached rendering uses `privacy.diagnostics_capture:
on_demand_with_rendering_buffer`. It requires the explicit rendering option and
performance evidence at capture and recovery; it does not represent GPU
utilization. Storage pressure drops stacks, then rendering, then older optional
metrics, preserving the original JavaScript failure.

## Active screen context (envelope 1.2)

`schemas/report-envelope.v1.2.schema.json` adds optional
`diagnostics.screen_context`: `{ name, route, source }`. `route` is the focused
root-to-leaf hierarchy (one to eight static labels); every label and `name` is
nonblank, printable and at most 128 UTF-8 bytes in SDK and consumer validation.
`source` is `manual`, `react_navigation` or `expo_router`. There are no route
parameters, IDs, query strings, fragments, URLs, history or inferred screen names.
Native bridge input is additionally bounded to 2 KiB of JSON and reconstructs
only recognized fields. Redaction occurs before persistence and serialization.

The context is opted in by the integration and gated by `custom_context` evidence.
It is frozen before asynchronous report capture, or at the JavaScript failure
handoff, and persisted with that failure. Recovery revalidates the saved value
and reapplies current evidence policy. Missing context stays missing. The
existing `diagnostics.location` retains native capture provenance; it is not a
logical React Native route. Screen context does not change the nine diagnostic
coverage categories and is not a claim about the crash's cause.

Schemas 1.0 and 1.1 remain unchanged. Emit 1.2 only when screen context survives
privacy filtering. Consumers must accept 1.2 before applications enable tracking;
older consumers correctly reject this new version.
