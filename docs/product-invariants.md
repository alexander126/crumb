# Product invariants

These rules are part of Crumb's product interface. Implementations may change;
the rules may not change accidentally.

1. A human explicitly initiates every report.
2. Crumb does not continuously sample performance or track product activity.
   Diagnostics are collected only after report invocation.
3. Sanitization happens on-device before upload and again on the server.
4. Text inputs are masked by default.
5. Network bodies, authorization headers, cookies, tokens, and arbitrary query
   values are excluded by default.
6. Recent application logs are bounded and sanitized on-device. Native Crumb
   does not hook logging calls or maintain its own background log buffer.
7. Screenshot capture can be disabled. A Crumb API health endpoint probe is
   optional and disabled unless explicitly configured; it never gates local
   submission.
8. An embedded project key grants write-only access to SDK ingestion routes.
9. A report is an occurrence. Grouping occurrences into an issue is a separate,
   server-owned decision.
10. Native and over-the-air JavaScript releases remain distinguishable.
11. Diagnostic values distinguish unavailable data from measured data; the SDK
   never fabricates unsupported GPU, native stack, or per-thread metrics.
12. Model output cannot directly merge, close, assign, notify, edit source, or
   deploy anything.
13. Crumb must coexist with existing crash and observability SDKs.
    It does not install an uncaught-exception handler, initialize Sentry or
    Crashlytics, replace application delegates, or intercept the host's logging
    pipeline.
14. Offline reports survive application restart and uploads are idempotent.
15. Customer report data is not used for model training by default.
16. The working product name is not embedded unnecessarily in persistent wire
   formats.
17. Crash capture, session replay, analytics, and automatic freeze monitoring
   remain outside the report SDK boundary.
