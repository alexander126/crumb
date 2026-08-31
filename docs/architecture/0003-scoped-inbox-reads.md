# ADR 0003: Project-scoped inbox reads

- Status: accepted
- Date: 2026-08-24

## Context

The first investigator surface must select projects and inspect accepted report
evidence without weakening the ingestion rule that an embedded SDK key grants
write access only. A full identity provider, organization administration, role
editor, and separate read service are beyond the primitive inbox milestone.

## Decision

Keep the first read surface inside the TypeScript modular monolith while giving
it an independent credential, session, repository, and route boundary.

- Hash inbox access keys and map each viewer to explicit projects.
- Sign short browser sessions with a production-required server secret.
- Recheck active viewer and project grants on every read.
- Expose accepted occurrences only; initialized and cancelled uploads remain
  ingestion state, not inbox content.
- Stream only verified sealed objects selected through the authorized report
  join. Never disclose storage object keys or issue fresh public object URLs.
- Serve the primitive same-origin UI with no third-party scripts, fonts, or
  analytics.

## Consequences

- SDK write keys remain unable to list or read any project data.
- A viewer can use one project selector without gaining access to unassigned
  projects, even when a report ID exists in both projects.
- The monolith is the deployment unit for `0.0.1`, but dashboard modules do not
  depend on SDK authentication and can move behind a separate service later.
- Access-key provisioning is administrative and local-script driven for now.
  Account recovery, SSO, invitations, and role management are future work.
