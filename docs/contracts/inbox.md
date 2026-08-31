# Primitive report inbox v1

The first investigator inbox is an authenticated read surface over accepted
individual reports. It does not reuse the SDK write credential and does not add
issue grouping, assignment, model output, integrations, or report mutation.

## Access boundary

Inbox access keys identify a viewer and are stored only as SHA-256 hashes. Each
viewer has explicit project grants in `inbox_project_access`; no project ID from
the browser is trusted without that join. Disabled viewers and projects stop
resolving immediately.

The browser exchanges an access key for a 12-hour HMAC-signed session cookie.
The cookie is HTTP-only, `SameSite=Strict`, and `Secure` in production. Every
authenticated request resolves the active viewer again, so disabling a viewer
invalidates an otherwise correctly signed session. Bearer inbox keys are also
accepted for bounded API checks; SDK write keys never authenticate these routes.

## Read API

| Route | Result |
| --- | --- |
| `POST /dashboard/v1/session` | Validate `{ "access_key": "..." }` and create the browser session. |
| `GET /dashboard/v1/session` | Return the active viewer for the current session. |
| `DELETE /dashboard/v1/session` | Clear the browser session. |
| `GET /dashboard/v1/projects` | List only granted active projects with accepted-report counts. |
| `GET /dashboard/v1/projects/:projectId/reports` | List up to 100 newest accepted occurrences. |
| `GET /dashboard/v1/projects/:projectId/reports/:reportId` | Return the twice-sanitized stored envelope and verified artifact metadata. |
| `GET .../reports/:reportId/artifacts/:artifactId` | Stream one verified sealed object through the authenticated origin. |

All dashboard responses are private and non-cacheable. Object keys, ingestion
credentials, pending objects, cancelled uploads, and unaccepted reports are not
returned. Artifact responses use the schema-validated MIME type, a fixed byte
length, `nosniff`, and attachment disposition for types the inbox does not
render inline.

## Web surface

`GET /inbox` serves a same-origin, dependency-free investigator interface with
a strict content security policy. The interface provides:

- access-key sign-in and explicit sign-out;
- accessible native project selection;
- an ordered list of individual accepted reports;
- the reporter's sanitized category and description;
- verified screenshot evidence and truthful attachment states;
- release, runtime, process, device-connectivity, Crumb API reachability, and
  log evidence; and
- the complete sanitized envelope behind progressive disclosure.

On narrow screens, list and detail become two explicit views with a visible back
action. Empty, loading, expired-session, unavailable-artifact, and retry states
are named in human language. Report content is inserted with DOM `textContent`,
not HTML interpretation.

## End-to-end gate

The integration suite uploads the shared native fixture through the SDK init,
signed PUT, and complete lifecycle. It then signs in as a project-scoped inbox
viewer, asserts the server-sanitized description, and reads the sealed artifact
through the authenticated route. Rewriting the old staging PUT URL after
completion does not change the bytes returned by the inbox.
