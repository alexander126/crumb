# Local report queue v1

The iOS and Android SDKs persist an explicitly submitted report before showing
success. This queue is the handoff between the native reporter and the reliable
uploader. No network request begins before this local transaction commits.

## Storage boundary

- iOS stores queue entries under the application's Application Support
  directory, applies complete-until-first-user-authentication data protection,
  and excludes the queue from device backup.
- Android stores queue entries under the application's no-backup files
  directory. The directory is private to the application and covered by the
  device's file-based encryption where the operating system provides it.
- Only the sanitized envelope and the exact encoded artifact bytes referenced
  by that envelope are written. Preview-only or pre-mask image data is never
  queued.

The React Native adapter keeps a separate, smaller crash handoff under the same
application-private boundary. It stores only a sanitized JavaScript failure,
its release identity, bounded Crumb breadcrumbs, and explicitly allowlisted
context. The handoff has independent count, record, and byte limits and is
never used to capture native memory, Redux state, request bodies, or response
bodies.

### Single-process boundary

The queue is single-process. Its mutual exclusion is in-process only — a Kotlin
`@Synchronized` object on Android, actor isolation on iOS — and neither is a
cross-process lock. Two processes using one queue would interleave record state
writes and each admit reports against the same count and byte quotas. Commit and
removal would stay atomic and payload reads would still be verified, so no report
would be corrupted, but accounting and upload state would drift invisibly.

Rather than allow that, Android refuses to use the queue outside the
application's main process: `CrumbReportQueue.from` throws
`CrumbReportQueueException.UnsupportedProcess`, and `CrumbReporter.install`
returns `false`. Both compare the current process name with the package name, so
a private secondary process (`android:process=":suffix"`) and a global one
(`android:process=".suffix"`) are both refused. A process that cannot be named
is treated as the main one, so an unidentifiable runtime never breaks a working
single-process host.

iOS needs no equivalent check: the queue lives in the application's own
container, which an app extension does not share, so each process already has a
separate queue.

## Ownership and delivery scope

Each committed report records an opaque SHA-256 ownership fingerprint in queue
metadata. Core derives it from the configured project write key and effective
ingestion destination when committing the report. Neither the raw key nor the
raw destination is stored in ownership metadata, and the fingerprint is not
added to the report wire envelope or report-time UI settings.

An uploader processes only reports whose persisted fingerprint matches its
current transport settings. Reports owned by another configuration remain
local and are excluded from that uploader's remaining-work and retry counts.
They are never relabeled, deleted, or automatically migrated. Identical bytes
under the same report ID are idempotent only when ownership also matches;
another owner cannot overwrite or adopt the item.

Changing a write key or effective destination creates a different scope. The
SDK cannot infer that replacement credentials authorize the same project.
Local-only reports retain their original no-destination scope; enabling upload
later does not retrospectively authorize delivery of those earlier reports.
Restoring an original upload-enabled configuration makes its owned reports
eligible for delivery again.

Legacy records without ownership remain readable and durable, but are not
uploaded automatically because their original project cannot be established.
Metadata version 2 carries ownership. A version 1 record is always treated as
unowned, even if it contains an extra ownership-looking field. SDK versions
that understand only metadata version 1 reject version 2 records instead of
silently forgetting their owner. Downgrading to such a version can therefore
block its queue operations until a version 2-capable SDK is restored; no
downgrade migration is performed.

The existing global queue limits continue to include all retained reports,
including foreign and legacy items. Any migration or removal policy requires
a separately defined explicit operation.

This boundary applies to committed queue items. Ownership of a separate crash
handoff before it is converted into a committed report is a distinct storage
boundary.

## Atomic commit

Each submission is first written to a uniquely named temporary directory on the
same volume. The SDK fully writes the envelope, every artifact, and a versioned
metadata record before renaming that directory to the report ID.

Only the final report directory is a committed queue item. A process exit before
the rename leaves no visible report; orphaned temporary directories are removed
at the next queue operation. A process exit after the rename leaves the complete
report available after restart.

Submitting the same report ID and identical bytes is idempotent. Reusing a
report ID with different envelope or artifact bytes fails as a conflict.

## Integrity and state

The metadata record contains envelope and artifact byte sizes and SHA-256
digests. Loading a report verifies those values before returning any payload.
Missing, renamed, truncated, or changed data is treated as queue corruption.

### Valid listing, retained occupancy, and unsupported versions

Three different situations used to be one "corrupt queue" outcome. They are now
distinguished, because they call for different behavior:

- **Confirmed invalid metadata is isolated.** Bytes that were read successfully
  and then rejected by supported-format decoding or shape validation, and a
  committed directory with positively no metadata, affect only that entry. It is
  skipped by listing and recovery, and it is never repaired, renamed, or
  deleted. Its healthy siblings continue to list, recover, upload, and accept
  new submissions. Naming it directly is still strict: a direct load, and
  committing a new report under the same report ID, both refuse it.
- **An I/O failure is a storage failure.** Metadata the SDK cannot read — a
  protected file, a transient device error — is retried rather than quarantined.
  Restoring access makes the original record usable again, unchanged.
- **An unsupported metadata version fails the whole operation.** The version is
  read before any version-specific field is decoded, so a newer format written
  by a future SDK is never mistaken for corruption, never skipped, and never
  adopted — including a future shape that omits fields this version expects.

Admission accounting is deliberately independent of metadata. A new report is
measured against what the queue actually retains: every retained committed
directory consumes a report slot, including an entry whose metadata cannot be
read, and payload bytes are the real envelope and artifact file sizes, including
artifact blobs no manifest references. Metadata itself remains outside the
payload budget. A directory whose payload is confirmed absent contributes zero
bytes while still consuming its slot and reserving its report ID. Anything the
queue cannot positively account for — an unexpected layout, a symbolic link, a
failed listing or stat, an entry that disappears mid-scan — fails admission
closed, leaving every existing byte and path intact.

Queue items have three durable states:

| State | Meaning |
| --- | --- |
| `pending` | Safely committed and waiting for upload. |
| `uploading` | A future uploader has begun an attempt. |
| `failed` | The last upload attempt failed and may be retried. |

Starting the reporter recovers the current owner's `uploading` items to
`pending`, because a process restart makes the outcome of an interrupted
attempt unknown. Foreign and legacy/unowned items are left untouched. Attempt
counts remain durable. Failure reasons are newline-stripped and bounded before
storage.

An item is removed only after the ingestion service returns success from the
idempotent complete operation. If the process ends after server acceptance but
before local removal, the next pass observes the already accepted report,
repeats completion safely, and then removes the queue item.
Removal first renames the accepted directory to a hidden tombstone on the same
volume, so process exit during byte cleanup cannot expose a partial queue item.

On the next opted-in React Native launch, each valid crash handoff is converted
to a normal queue item. The handoff is removed only after that queue commit; a
queue-full, corruption, or storage failure leaves it for a later launch. The
normal queue then owns offline retry and upload acknowledgement.

## Default limits

Limits account for the persisted envelope and artifact payload bytes. Queue
metadata is intentionally not included in the payload budget.

| Limit | Default |
| --- | ---: |
| Reports | 50 |
| Total payload | 128 MiB |
| One report | 26 MiB |
| One envelope | 1 MiB |
| One artifact | 25 MiB |
| Artifacts per report | 10 |

If a new report would exceed a count or byte limit, the local commit fails and
the reporter remains available to retry. The SDK does not silently delete or
replace an already queued report.

The JavaScript crash handoff defaults to 50 occurrences, 2 MiB total, 32 KiB
per occurrence, 32 breadcrumbs, and 16 KiB of breadcrumb data. It also never
evicts an existing occurrence to accept a new one.

### Optional JavaScript failure context

The private local crash record may carry `failure_context`, captured natively
before the existing JavaScript error handler is called. JavaScript-supplied
values for that field are ignored. It preserves the original process/time and
opted-in CPU, memory, thread count, thermal and connectivity observations.
Recovery maps valid context into diagnostics with location
`react_native_javascript_failure`; legacy/fallback diagnostics retain
`react_native_recovery`. Native stacks and rendering use the explicit 1.1 extension.

Optional context is validated on read and dropped before the core crash if it
would exceed the per-record or remaining total-store budget. Deduplication keeps the context belonging
to the preferred JavaScript cause, never a later termination wrapper. Current
collection settings are applied again at recovery, including removal of saved
breadcrumbs when logs are disabled. Enabled platform stacks and optional rendering
are removed before older metrics when storage is tight. Rendering freezes the
existing foreground buffer before stack collection; it never starts a new sample
window during failure handling. Provider log callbacks and HTTP health checks
are not attempted during failure handling.
