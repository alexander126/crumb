# Native uploader v1

The reliable uploader consumes only atomically committed queue entries. It is
enabled by an explicit ingestion base URL in `CrumbUploadOptions`; an absent URL
keeps reports durable and local. Infrastructure reachability, the optional
diagnostic health probe, and server availability never participate in the local
submission transaction or its success UI.

## Delivery lifecycle

For each oldest queued report, both native SDKs:

1. recover interrupted `uploading` work and mark the report `uploading`;
2. send `POST /sdk/v1/reports/init` with the complete envelope and
   `Idempotency-Key: <report_id>:init`;
3. validate that every returned `PUT` target matches one local artifact ID and
   upload ID, then upload the exact integrity-checked queued bytes;
4. send `POST /sdk/v1/reports/<report_id>/complete` with
   `Idempotency-Key: <report_id>:complete`;
5. remove the local queue directory only after completion succeeds.

All lifecycle calls authenticate with the configured bearer project write key.
Signed artifact requests do not carry that key. HTTPS upload targets are
required unless the configured ingestion base itself uses HTTP for local
development. Response-size, timeout, header-name, target-ID, and URL validation
remain inside the transport boundary.

The server's project-scoped idempotency makes an unknown result safe. A process
may end after init, artifact PUT, completion, or server acceptance; repeating
the same report ID and operation cannot create a second report. Init refreshes
expired signed targets and returns no targets when that report is already
accepted.

## Failure, retry, and cancellation

- Network errors, HTTP 408/425/429, 5xx responses, and an expired artifact
  target (`403`) are retryable.
- Other 4xx responses and structurally invalid or mismatched responses remain
  durably `failed` without a battery-consuming retry loop. A later foreground
  lifecycle transition may try them again after host configuration changes.
- Foreground retries use 1, 2, 4, 8, 16, 32, then at most 60-second delays.
  A connectivity-restored signal wakes the uploader immediately and resets the
  delay. Connectivity monitoring stops when the queue drains or only a terminal
  failure remains.
- Backgrounding cancels in-flight work. Cancellation returns the current item
  to `pending`; it never deletes an explicitly submitted report. Process death
  is recovered by the same `uploading`-to-`pending` rule.
- Stored failure reasons are bounded operation/status codes. They do not include
  bearer keys, signed URLs, response bodies, or artifact contents.

The SDK does not automatically invoke the ingestion cancel endpoint for an
explicitly submitted report because no native product action abandons that
report in v1. Transport cancellation means pause-and-preserve, not data loss.

## Airplane-mode gate

Native parity tests commit a report while the transport is offline, verify the
queue remains `failed`, restore connectivity, and run the same worker again.
They assert one artifact PUT, one successful completion, an empty queue, and no
additional calls from a subsequent pass. Separate tests cancel an in-flight
pass and verify that the item returns to `pending` with its attempt count intact.
