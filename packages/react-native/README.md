# React Native adapter

This package will remain a thin adapter over the native iOS and Android SDKs.
It starts after native parity and will not implement reporter UI, screenshots,
masking, persistence, invocation, or uploads in JavaScript.

## Planned report-time JavaScript context

The native `CrumbLogProvider` seam is the handoff point for React Native. The
adapter can provide a bounded JavaScript snapshot while the native SDK remains
responsible for merging, sanitizing, displaying, persisting, and uploading it.

The first adapter should support:

- `Crumb.log(level, message, metadata?)` for explicit structured application
  logs;
- optional interception of `console.warn` and `console.error`, preserving the
  original console methods;
- a 60-second, 200-entry, 64 KB in-memory ring buffer with bounded object depth
  and per-entry size;
- an `Error` stack captured when a warning or error is written, which is more
  useful than creating a new JavaScript stack only when the reporter opens;
- a short native-to-JavaScript snapshot deadline. If the JavaScript thread is
  blocked, the native report continues and marks JavaScript logs unavailable;
- a second sanitization pass in the native SDK before the entries join the
  report.

Console capture must be explicitly configurable. It must not collect network
bodies, Redux state, navigation history, arbitrary object graphs, or analytics
events. The buffer remains on-device and is only attached after explicit user
invocation.
