# Product invariants

These rules are part of Crumb's product interface. Implementations may change;
the rules may not change accidentally.

1. A human explicitly initiates every on-demand report. An opted-in React Native
   JavaScript failure may be recovered as a separate crash occurrence after a
   process relaunch.
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
13. Crumb must coexist with existing crash and observability SDKs. The native
    SDKs never install native uncaught-exception hooks or initialize Sentry or
    Crashlytics. The React Native adapter may install an explicitly enabled
    JavaScript exception/rejection handler, chains the pre-existing handler,
    and never replaces the host SDK.
14. Offline reports survive application restart and uploads are idempotent.
15. Customer report data is not used for model training by default.
16. The working product name is not embedded unnecessarily in persistent wire
   formats.
17. Native crash capture, session replay, analytics, and automatic freeze
    monitoring remain outside the report SDK boundary. The React Native
    adapter's opt-in JavaScript-only failure record is the sole exception and
    never claims arbitrary native crash coverage.
