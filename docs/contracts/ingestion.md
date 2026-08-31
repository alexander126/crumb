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
