# Source-map upload contract v1

This versioned public contract is owned by the SDK repository. The CLI implements
it; service availability and hosted interoperability are separate release gates.
It does not change the report-envelope or SDK ingestion contract.

## Authority and identity

A dedicated project-scoped secret authorizes only source-map initialization and
completion. The server resolves project ownership from this credential. It must
reject app-embedded SDK keys and must not accept project/tenant identifiers from
the manifest. The credential grants no report, source-content, dashboard or
administrative read access. Credential creation and revocation are server
responsibilities; the CLI accepts only an environment variable or secret file.

Every request belongs to the tuple:

```text
(authenticated project, platform, app_version, native_build, js_bundle_version)
```

Platform is the actual `ios` or `android` platform. The remaining values exactly
match the app's Crumb release configuration; `release.bundleVersion` becomes
`js_bundle_version` in the report envelope and `bundle_version` in JavaScript
crash release metadata. Missing or contradictory crash metadata cannot be
resolved by guessing the latest uploaded release.

The manifest is validated by [source-map-upload.schema.json](../../schemas/source-map-upload.schema.json).
It binds both the bundle and source map to their byte lengths and SHA-256 hashes.
The [valid fixture](../../schemas/examples/source-map-upload.valid.json) uses
synthetic hashes for schema validation, not actual artifact contents.

## Initialize

`POST /source-maps/v1/uploads/init`

Headers:

```text
Authorization: Bearer <dedicated project upload secret>
Content-Type: application/json
Idempotency-Key: source-maps:<manifest-sha256>:init
```

Body: `{ "manifest": <manifest conforming to the schema> }`.

`manifest-sha256` is lowercase SHA-256 over UTF-8 JSON with recursively sorted
object keys, preserved array order, no whitespace, and ordinary JSON string
escaping. All identity strings are restricted to ASCII by the schema. Numeric
values are positive integers within the schema's bounds. The server must
recompute this digest and reject a mismatched idempotency key.

The server atomically reserves the release tuple and artifact pair. Repeating
the same tuple and hashes returns the same upload ID. Different bytes or lengths
under that tuple return HTTP 409; concurrent requests cannot create ambiguous
releases. The project scopes idempotency records as well as release identity.

A successful response is HTTP 200 or 201 with this shape:

```json
{
  "upload_id": "00000000-0000-4000-8000-000000000001",
  "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "status": "initialized",
  "artifacts": [
    {
      "kind": "bundle",
      "method": "PUT",
      "url": "https://upload.example.invalid/one-private-bundle",
      "headers": { "content-type": "application/octet-stream" }
    },
    {
      "kind": "source_map",
      "method": "PUT",
      "url": "https://upload.example.invalid/one-private-map",
      "headers": { "content-type": "application/octet-stream" }
    }
  ]
}
```

Upload IDs are UUIDs (versions 1–5). The digest must equal the submitted manifest.
There are exactly two unique artifact kinds. The only required upload header in
v1 is `content-type: application/octet-stream`. Locations are short lived,
write-only and scoped to exactly one artifact in this authenticated project and
upload. Their expiration is enforced by the service; retrying init refreshes
expired locations. No artifact read URL is returned.

The CLI validates all destinations before uploading either artifact. It sends
raw bytes with PUT, without the API bearer credential, and requires a 2xx result.
Every URL must use HTTPS without embedded credentials or fragments. Redirects
are rejected. The explicit local testing option allows HTTP loopback only.

If already verified, init instead returns `status: "verified"`, `upload_id` and
`manifest_sha256`; the client skips both PUTs and completion.

## Complete

`POST /source-maps/v1/uploads/{upload_id}/complete`

Uses the same authorization, JSON content type and
`Idempotency-Key: source-maps:<manifest-sha256>:complete`. Body is `{}`.

The server checks ownership, session identity and both stored artifacts. It must
recompute byte lengths and checksums, validate the source map within bounded
resource limits, and seal verified artifacts against later writes through an
old upload URL **before** marking the pair verified. Missing, truncated,
oversized, corrupt or mismatched artifacts never become eligible for processing.
Bundles must never be executed and external source/map URLs must never be loaded.

Successful completion returns HTTP 200 with:

```json
{
  "upload_id": "00000000-0000-4000-8000-000000000001",
  "manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "status": "verified"
}
```

Completion is idempotent. A lost response can be recovered by rerunning init;
it returns the durable verified result without uploading again. Verification is
a storage state; worker processing and crash symbolication have separate states.
The server retains source artifacts privately and controls deletion, retention,
quotas and access; none of those are exposed through this upload-only credential.

## Limits and errors

The client permits at most 25 MiB per artifact (50 MiB combined), 64 KiB per API
response, and 60 seconds per request. Source-map JSON is version 3; indexed maps
must contain inline ordered sections, at most 1,024 total maps and eight nesting
levels. These are structural checks; a build pipeline must establish that the
final map actually corresponds to the final distributed bundle. Service-side
parsing/processing must also enforce resource budgets and may set smaller quotas.

Status mapping:

| HTTP | Meaning |
| --- | --- |
| 401 / 403 | Invalid, expired or unauthorized upload credential |
| 404 | Upload outside the authorized project or absent |
| 409 | Conflicting artifacts or lifecycle identity |
| 413 | Artifact/usage size limit exceeded |
| 422 | Invalid manifest, source map, byte count or checksum |
| 429 | Rate limited |
| 5xx | Service unavailable |

Service errors may use `{ "error": { "code": "...", "message": "..." } }`.
The CLI ignores their bodies and emits its own fixed safe error. It never logs
server content, signed URLs, tokens, paths, source or stack traces. Unsupported
success shapes, mismatched IDs/digests and oversized responses are failures;
the client never assumes a successful upload from a PUT alone.
