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

Queue items have three durable states:

| State | Meaning |
| --- | --- |
| `pending` | Safely committed and waiting for upload. |
| `uploading` | A future uploader has begun an attempt. |
| `failed` | The last upload attempt failed and may be retried. |

Starting the reporter recovers any `uploading` item to `pending`, because a
process restart makes the outcome of an interrupted attempt unknown. Attempt
counts remain durable. Failure reasons are newline-stripped and bounded before
storage.

An item is removed only after the ingestion service returns success from the
idempotent complete operation. If the process ends after server acceptance but
before local removal, the next pass observes the already accepted report,
repeats completion safely, and then removes the queue item.
Removal first renames the accepted directory to a hidden tombstone on the same
volume, so process exit during byte cleanup cannot expose a partial queue item.

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
