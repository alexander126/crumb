# Hosted control-plane contract

The hosted control plane is a separate authorization boundary from SDK
ingestion and the temporary access-key inbox.

## Identity

Clients send a Firebase ID token as `Authorization: Bearer <token>` to
`/control/v1/*`. The backend verifies the token with the Firebase Admin SDK and
accepts only identities with a verified email address. A verified token proves
who the user is; it does not grant access to any Crumb organization or project.

The backend maps the Firebase UID to `control_plane_users` and resolves every
organization and project permission from active PostgreSQL memberships. Client
supplied organization IDs are always checked against that membership.

All responses are private and carry `Cache-Control: private, no-store`.

## Session discovery

`GET /control/v1/session`

Returns the synchronized Crumb user and all organizations granted by active
membership:

```json
{
  "user": {
    "id": "10000000-0000-4000-8000-000000000001",
    "email": "owner@example.com",
    "display_name": "Owner"
  },
  "organizations": [
    {
      "id": "20000000-0000-4000-8000-000000000002",
      "name": "Example",
      "slug": "example-a1b2c3d4",
      "role": "admin"
    }
  ]
}
```

## First workspace bootstrap

`POST /control/v1/bootstrap`

```json
{
  "organization_name": "Example",
  "project_name": "Mobile app"
}
```

This endpoint is available only while the user has no active organization
membership. It atomically creates one organization, an admin membership, one
project, an audit event, and the initial SDK write key.

The response returns the plaintext SDK key exactly once under
`sdk_write_key.value`. Only its random prefix and SHA-256 digest are persisted.
A repeated bootstrap returns `409 workspace_already_exists`.

## Project discovery

`GET /control/v1/organizations/:organizationId/projects`

Returns active, non-archived projects only when the authenticated user has an
active membership in the organization. An ungranted organization yields no
project data.

## Boundary invariants

- Firebase credentials never authenticate `/sdk/v1/*` ingestion routes.
- SDK write keys never authenticate `/control/v1/*` or inbox reads.
- Revoked SDK keys fail authentication immediately.
- Firebase custom claims, request bodies, and URL parameters never replace the
  PostgreSQL membership check.
- Invitation acceptance, member management, key rotation UI, and authenticated
  report reads extend this contract in T12 without weakening these boundaries.
