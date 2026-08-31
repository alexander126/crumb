# ADR 0004: Railway-hosted control plane with Firebase identity

- Status: accepted
- Date: 2026-08-29

## Context

The native SDK and local ingestion lifecycle are complete, but a public release
needs durable hosted infrastructure and a real authenticated investigator
surface. Crumb must support organizations, memberships, projects, credential
rotation, and report access without making Firebase the authority for product
authorization or coupling the application to one cloud provider.

Early testing is expected to involve roughly ten users. Operational simplicity,
strict cost control, environment isolation, and a credible path to AWS matter
more than multi-region scale at this stage.

## Decision

Use the following hosted architecture for the first production-capable Crumb
control plane:

- Run the existing portable TypeScript monolith as a container on Railway Pro.
- Use Railway PostgreSQL for all Crumb domain and authorization data.
- Use a private Railway S3-compatible bucket for report artifacts.
- Use Firebase Authentication for user identity only.
- Verify Firebase ID tokens in the backend and map the trusted Firebase UID to
  a Crumb user record.
- Resolve organizations, memberships, roles, projects, invitations, report
  access, and SDK write-key lifecycle from PostgreSQL on every authorized
  operation. Do not trust organization or project claims supplied by clients.
- Keep SDK write keys write-only and separate from user identity.
- Create isolated staging and production Railway environments. Deploy staging
  first and keep production offline until the hosted flow is accepted.
- Keep the deployable unit portable: a standard Node container, PostgreSQL,
  S3-compatible storage, environment variables, and no Railway-specific
  application APIs.

The first authenticated API slice synchronizes a verified Firebase user,
bootstraps one organization and project, returns the initial SDK write key once,
and lists only organizations and projects granted by active membership.

## Consequences

- Firebase handles sign-in and account recovery while Crumb retains full
  control over multi-tenant authorization.
- A later move from Railway to AWS can preserve the application, database
  schema, and storage interface; it becomes an infrastructure migration rather
  than a product rewrite.
- A Firebase service-account credential is required in each hosted environment
  and must stay in Railway's sealed variables, never in source control.
- The primitive inbox access-key flow remains available during migration but is
  not the long-term user authentication model.
- Each new SDK key is stored only as a SHA-256 digest. The plaintext value is
  returned once during creation and cannot be recovered later.
