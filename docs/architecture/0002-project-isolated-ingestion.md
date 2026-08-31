# ADR 0002: Project-isolated ingestion monolith

- Status: accepted
- Date: 2026-08-24

## Context

The first server slice must accept offline-generated native reports exactly
once without granting an embedded mobile credential any read capability.
Envelope metadata and comparatively large artifact bytes have different
transaction and storage needs.

## Decision

Implement ingestion as a modular TypeScript monolith backed by PostgreSQL and
S3-compatible object storage.

- Resolve project identity only from a hashed bearer write key.
- Scope reports, artifact upload IDs, and idempotency keys by that resolved
  project.
- Store the sanitized envelope and lifecycle metadata in PostgreSQL.
- Upload artifacts directly to short-lived, object-specific PUT URLs.
- Stream each object through server-side size and SHA-256 verification before
  copying it to a sealed object key and marking a report accepted.
- Keep processing workers, dashboard reads, grouping, and notification systems
  outside the SDK ingestion interface.

## Consequences

- A compromised SDK key can submit bounded reports only to its own project.
- PostgreSQL transactions make lifecycle and idempotency state durable, while
  object storage handles payload size independently.
- Completion costs one bounded read of each artifact. This is deliberate for
  trustworthy digest verification and can later move to a durable worker
  without changing the public lifecycle contract.
- Cancellation and completion serialize on the report row, so cancellation
  cannot delete artifacts after a report has been accepted.
