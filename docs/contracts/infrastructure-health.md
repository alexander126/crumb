# Crumb infrastructure health contract v1

Crumb records two independent network facts when a person opens the reporter:

1. whether the device currently has a usable network path; and
2. whether the configured Crumb API health endpoint answered a bounded probe.

Neither fact is inferred from the other. A device can have connectivity while
the Crumb API is unavailable, and an uncertain platform path observation does
not suppress the API probe.

## Public endpoint

The ingestion service exposes one unauthenticated liveness endpoint:

- `HEAD /health` returns `204` with no body;
- `GET /health` returns `200` and
  `{"status":"ok","service":"crumb-ingestion","contract_version":"1"}`;
- both responses send `Cache-Control: no-store` and
  `X-Content-Type-Options: nosniff`; and
- other methods are not accepted.

The route proves that the Crumb API process can answer a request. It does not
query PostgreSQL or object storage and is not a dependency-readiness promise.
This keeps the probe bounded and prevents a downstream outage from turning a
report-time diagnostic into a blocking dependency.

## Native probe

Health probing remains opt-in. Hosts configure the public `/health` URL and a
timeout between 250 and 5000 milliseconds. A configured URL must be an absolute
HTTP or HTTPS URL without credentials, a query, or a fragment.

After explicit report invocation, each native SDK performs one `HEAD` request
off the UI thread. It follows the existing diagnostic timeout and records only:

- destination host;
- whether the final response was a `2xx`;
- final HTTP status when one exists;
- elapsed milliseconds; and
- a bounded failure classification when no HTTP response exists.

Response headers and bodies never enter the report. A timeout, transport error,
or non-`2xx` status produces a normal unsuccessful health diagnostic; it does
not throw out the diagnostic snapshot, close the reporter, prevent the local
atomic commit, or participate in upload retry decisions.

## Envelope mapping

Device connectivity remains in `diagnostics.network.status`, transport, and
cost/constrained flags. Crumb API reachability remains in the optional
`diagnostics.network.health_check` object. Omitting the opt-in probe omits only
`health_check`; it does not remove the device connectivity observation.

## Release gate

Task 8 passes when the public `HEAD` route answers without credentials and both
native implementations prove that a configured unavailable API is serialized
as `succeeded: false` while the separate device connectivity fact and reporter
flow remain usable.
