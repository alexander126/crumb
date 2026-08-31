# Cloud boundary

Crumb is split at its distribution and trust boundary.

This repository owns the iOS, Android, and future React Native packages, their
examples, public integration documentation, and the canonical versioned report
envelope. It does not own deployable cloud services, database migrations,
Firebase administration, or customer-facing web applications.

The private `alexander126/crumb-cloud` monorepo owns the hosted API, customer
dashboard, database migrations, private artifact access, Firebase identity
integration, and future internal operations tooling.

Native clients and the cloud communicate through the versioned report envelope
and documented ingestion contract. Cloud changes must remain compatible with
the protocol version accepted by published SDK releases.
