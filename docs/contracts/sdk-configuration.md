# SDK configuration and privacy precedence

Crumb configuration contract `1.0` is owned by the SDK. Swift, Kotlin, and
React Native expose the same concepts with platform naming conventions; the
normalized examples live in [`schemas/sdk-configuration.schema.json`](../../schemas/sdk-configuration.schema.json).
The schema's `schema_version` is contract metadata owned by the SDK; it is not
an extra required argument to native initializers or the React Native API.

## Configuration surface

| Contract concept | Swift | Kotlin | React Native |
| --- | --- | --- | --- |
| Invocation | `invocation` | `invocation` | `invocation` |
| Reporter theme | `reporter.theme` (`.system`, `.light`, `.dark`) | `reporter.theme` (`SYSTEM`, `LIGHT`, `DARK`) | `reporter.theme` (`system`, `light`, `dark`) |
| Reporter fields | `reporter.visibleFields` | `reporter.visibleFields` | `reporter.visibleFields` |
| Optional evidence | `evidence` | `evidence` | `evidence` |
| App/release identity | `application`, `release` | `application`, `release` | `application`, `release` |
| Custom context | `customContext` | `customContext` | `customContext` |
| Workspace policy | `workspacePolicy` | `workspacePolicy` | `workspacePolicy` |

The required report text is the description. The optional category field can
be hidden, but no configuration can remove the description or replace the
built-in reporter's layout, copy, or Crumb branding. App and release metadata
are bounded identity fields; they do not introduce user identity tracking.

The default configuration preserves existing integrations: system appearance,
category and description fields, locally enabled screenshot/performance/network/
logs/thread-stack evidence, and no custom context. The health-check evidence is
only locally eligible when a health-check URL is configured.

## Effective policy

Without `workspacePolicy.url`, the local SDK configuration is authoritative.
When a URL is configured, every optional source is fail-closed until a valid
policy is available. A valid policy can only narrow the local configuration:

```text
effective evidence       = local evidence - policy.disabled_evidence
effective fields         = local visible fields - policy.hidden_reporter_fields
effective context keys   = host allowlist ∩ policy.allowed_context_keys
```

The policy document is the versioned shape in
[`schemas/workspace-policy.schema.json`](../../schemas/workspace-policy.schema.json):

```json
{
  "schema_version": "1.0",
  "version": 7,
  "expires_at": "2030-01-01T00:00:00Z",
  "disabled_evidence": ["network"],
  "hidden_reporter_fields": ["category"],
  "allowed_context_keys": ["account_tier"]
}
```

The policy request is a bounded, non-blocking `GET` to the configured URL with
the project write key in the `Authorization: Bearer` header. The SDK validates
the exact document shape, schema version, positive monotonic version, future
expiry, enum values, duplicate-free arrays, and response size before applying
it. A lower version never replaces a newer valid policy.

| Policy state | Optional evidence | Report text | Custom context |
| --- | --- | --- | --- |
| Not configured | Local configuration | Local visible fields | Local allowlist |
| Not fetched, fetching, unavailable, malformed | None | Description only | None |
| Fresh or valid cached | Local evidence minus policy disables | Local fields minus policy hides | Host/policy intersection |
| Expired | None | Description only | None |

An unavailable or malformed fetch never broadens collection. A cached policy is
used only until its expiry and is refreshed without delaying reporter
presentation or durable local saving. The cache is app-private and capped at
64 KiB.

## Custom context boundary

Custom context is an explicit string-only map, not an attribute or analytics
system. A host must provide an allowlist; values outside it are dropped. Before
the report is persisted, Crumb enforces at most 16 keys, ASCII key names of at
most 64 bytes, values of at most 512 UTF-8 bytes, and a total of 8 KiB. Control
characters are removed and sensitive key names such as `password`, `token`,
`authorization`, `cookie`, `card`, `email`, and `phone` are redacted or dropped.
The workspace policy can only reduce the host allowlist.

Crumb does not add arbitrary layouts, custom branding or copy, analytics,
session replay, request/response bodies, automatic store capture, arbitrary
memory capture, navigation history, or user identity collection through this
contract.

## Compatibility and migration

Existing native integrations continue to compile because all new configuration
options are appended with safe defaults. Existing React Native objects remain
valid because the new properties are optional. No migration is required unless
an application opts into a workspace policy or custom context.

For a gradual migration:

1. Keep the existing local configuration and add `reporter`, `evidence`, or
   `customContext` only where the host has an explicit product decision.
2. Deploy the policy endpoint and validate its response against the policy
   schema before adding `workspacePolicy.url`.
3. Expect the first configured launch to retain only the description until a
   fresh or unexpired cached policy is accepted.
4. Treat policy version and expiry as server-owned operational data; do not
   use the policy to turn on a source disabled by the host.

Contract fixtures and precedence checks run with `npm run contracts:check`.
Native coverage for malformed, offline, fail-closed, and non-broadening
behaviour is included in the iOS and Android core tests.
