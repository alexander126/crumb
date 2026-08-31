# Crumb product brief

## Purpose

Crumb is a native-first mobile issue-reporting SDK. It helps a person report a
problem from inside an app and gives the app's engineering team a privacy-safe,
report-time diagnostic packet without asking the reporter to reproduce basic
technical context.

The product promise is:

> When something goes wrong, a person can report it immediately and understand
> what will be shared. The engineering team receives enough bounded, trustworthy
> context to begin investigating, without Crumb continuously monitoring the app.

Crumb is embedded by mobile product teams in their own applications. The person
reporting a problem interacts with Crumb's native reporting flow; an engineer or
support team later inspects the resulting report in a web inbox.

## Problem

Mobile bug reports often lack the context needed to investigate them. Reporters
may not know their device state, app build, network condition, resource usage, or
what the app was doing at the time. Engineering teams then spend time asking for
details or trying to reproduce an issue that may have been transient.

Existing observability products often solve a different problem through crash
capture, analytics, continuous performance monitoring, or session replay. Crumb
is intentionally narrower: a human explicitly asks to report one occurrence,
and Crumb gathers one bounded snapshot at that moment.

## Product principles

1. **Human initiated.** Every report begins with an explicit action by the
   reporter. Crumb does not silently create reports.
2. **Idle until invoked.** Crumb does not continuously sample performance,
   record sessions, track navigation, or collect product analytics.
3. **Immediate reporting UI.** The form opens immediately. Diagnostics finish
   independently and must not make the reporter wait to start describing the
   problem.
4. **Privacy before transport.** Sensitive content is removed on the device
   before anything can be queued or uploaded. Server-side sanitization is a
   second line of defence, not the first.
5. **Transparent evidence.** The reporter can understand what is attached,
   review it, and remove optional artifacts such as the screenshot.
6. **Truthful diagnostics.** Missing or unsupported data is labelled
   unavailable. Crumb never invents a value to make a report appear complete.
7. **No lost submitted reports.** Submission commits the sanitized report to a
   durable, app-private queue before upload begins. Offline and failed uploads
   survive app restart and retry idempotently.
8. **Native consistency.** iOS and Android should express the same states and
   guarantees using familiar platform-native interactions.

## Primary users

### Reporter

A person using a customer app who has just experienced something confusing,
broken, slow, or incorrect. They want to explain the problem quickly, retain
control over what is shared, and return to the app.

### Investigator

An engineer, support specialist, or product team member who needs a concise,
trustworthy record of one reported occurrence. They want the reporter's words,
release context, diagnostics, and optional artifacts in one place.

### SDK integrator

A mobile engineer who installs and configures Crumb. They choose invocation
methods, screenshot behavior, masking rules, bounded log sources, and an
optional Crumb API health endpoint.

## Core mobile experience

### 1. Invocation

The host app can expose Crumb through:

- a configured programmatic action, such as **Report a problem**; and
- an optional foreground-only physical shake gesture.

Crumb accepts only invocation methods enabled by the host app. A second trigger
while the reporter is already visible must not open a duplicate flow. Shake
sensing is active only while the host application is in the foreground and no
Crumb reporter is already presented.

### 2. Capture the reported moment

At invocation, Crumb:

1. records the trigger and timestamp;
2. captures the host screen before Crumb UI appears, if screenshots are enabled;
3. masks configured sensitive regions on-device; and
4. begins a short, one-time diagnostic probe.

The reporter form appears immediately. Diagnostic collection continues in the
background and reports progress in the form.

### 3. Describe the problem

The reporter can:

- choose a category such as **Bug**, **Feedback**, or **Other**;
- describe what happened in their own words;
- see whether diagnostics are still being gathered, ready, partially
  unavailable, or failed;
- preview the masked screenshot when one exists; and
- remove the screenshot before submission.

The primary review/continue action remains unavailable until the required
description exists and the diagnostic probe has reached a terminal state. A
failed optional diagnostic source must not block the report.

### 4. Review

Before submission, Crumb shows a human-readable review of:

- category and description;
- whether a screenshot is attached and masked;
- report-time app, release, device, and diagnostic context;
- recent sanitized application logs when configured; and
- which evidence is unavailable or omitted.

The review must clearly distinguish a local, not-yet-uploaded report from a
submitted or uploaded report. The reporter can go back without losing form
state, or cancel the flow.

### 5. Submit and queue

In the intended `0.0.1` experience, submission:

1. performs final on-device sanitization;
2. writes the report envelope and artifacts atomically to app-private storage;
3. confirms that the report is safely saved; and
4. uploads immediately when possible or remains queued for retry.

The person should never have to keep the reporting UI open while an upload
finishes. Network failure, airplane mode, an unavailable optional Crumb API probe,
or app termination after the local commit must not lose the report.

The current implementation includes the durable local queue, reliable native
uploader, project-isolated ingestion service, Crumb infrastructure health, and
primitive investigator inbox. Explicitly submitted native reports survive
restart, retry idempotently, and appear only to inbox viewers granted access to
their project.

### 6. Completion

After a successful local commit, Crumb dismisses with clear confirmation and
returns the reporter to the host app. A new invocation starts a new occurrence
with a clean form and a new report-time snapshot.

## Lifecycle behavior

The design must specify these states rather than only the happy-path screens:

| Event | Required behavior |
| --- | --- |
| Repeated invocation while open | Keep the existing reporter; do not stack or reset it. |
| Interactive sheet dismissal | End the unfinished session safely and allow a later invocation. Confirm first if dismissal would unexpectedly discard meaningful input. |
| Rotation or size-class change | Preserve category, description, capture, diagnostic state, and current step. |
| App background and foreground | Preserve the active reporting session and restore it in place. |
| Host screen/activity recreation | Restore the active session when the platform recreates the host. |
| Host destruction without recreation | End the unfinished in-memory session. |
| Process termination before submission | The current unfinished form is not promised to persist. |
| Process termination after local commit | Preserve the queued report and retry later. |
| Diagnostic source fails | Mark that source unavailable; keep the form usable. |
| Upload fails or device is offline | Confirm local safety, show queued/failed state where appropriate, and retry without duplication. |

## Diagnostic evidence

Crumb gathers a bounded, one-time snapshot after invocation. Depending on
platform support and host configuration, a report can include:

- report ID, invocation method, and timestamps;
- app version, native build, environment, and optional JavaScript/OTA release;
- operating system, device family, locale, and timezone;
- current host screen or controller/activity location;
- process name and identifier;
- CPU usage, resident memory, physical footprint, thread count, and thermal state;
- network reachability and transport;
- a bounded `HEAD` request to an optional configured Crumb API health endpoint,
  storing host, outcome, status, latency, and failure class but never response
  content; this is recorded independently from device connectivity;
- bounded and sanitized recent application logs; and
- supported app-thread summaries or stack evidence.

Platform differences must be presented honestly. For example, unsupported GPU
metrics or unsafe iOS all-thread stack capture appear as unavailable, not zero
or empty measurements.

The reporter does not need to understand every raw metric. The mobile flow
should summarize evidence clearly and allow deeper technical detail to remain
available for review or the investigator inbox.

## Privacy and trust requirements

- All text inputs are masked in screenshots by default.
- Hosts can add custom masking rules and disable screenshot capture entirely.
- The reporter can preview and remove the screenshot.
- Network bodies, authorization headers, cookies, tokens, and arbitrary query
  values are excluded by default.
- Recent logs are bounded and sanitized before submission.
- Android does not request broad system-log access; it accepts only an
  application-owned log provider.
- Crumb collects no diagnostics before explicit invocation.
- The reporting sheet must behave as a true modal for assistive technologies:
  underlying host controls and sensitive values must not remain reachable by
  VoiceOver, TalkBack, keyboard focus, or automation while the reporter is open.
- The interface must say whether evidence is local, queued, uploading, uploaded,
  removed, disabled, or unavailable.
- Customer report data is not used for model training by default.

## Investigator experience

The first web inbox is deliberately small. It needs:

- authenticated project selection;
- a list of individual reports;
- a report detail view containing the reporter's description and sanitized
  evidence; and
- clear artifact, upload, and availability states.

One report represents one occurrence. Grouping related occurrences into an
issue is a later server-owned decision. Assignment, integrations, automatic
model investigation, and model-driven actions are not part of the first
release.

## Out of scope for the report SDK

- crash reporting;
- session replay;
- analytics and navigation tracking;
- continuous performance or freeze monitoring;
- user identity management;
- arbitrary breadcrumbs or application-state capture;
- automatic report creation;
- automatic issue grouping in the SDK; and
- model actions that merge, close, assign, notify, edit source, or deploy.

Crumb must coexist with products that already provide those capabilities.

## Design scope and expected deliverables

The initial design package should include:

1. Invocation entry points and duplicate-trigger behavior.
2. Reporter form states: initial, diagnostics loading, ready, partial/unavailable,
   validation, keyboard open, and screenshot removed/disabled.
3. Review states with clear local-versus-uploaded language.
4. Submission states: saving locally, queued offline, uploading, completed, and
   retryable failure.
5. Cancel and interactive-dismiss behavior, including when confirmation is
   necessary.
6. Rotation, compact-height, large-text, background/foreground, and host
   recreation behavior.
7. VoiceOver/TalkBack reading order, modal focus containment, initial focus,
   focus restoration, labels, values, and announcements for changing diagnostic
   status.
8. A lightweight investigator inbox showing how the mobile report appears to
   the receiving team.

The handoff should contain an interactive prototype, a state/transition map,
privacy and accessibility annotations, and component behavior at supported
screen sizes. Static happy-path screens alone are not sufficient for
implementation.

## Release success criteria

The first usable native release succeeds when:

- iOS and Android pass the same reporter lifecycle flows;
- configured sensitive content never reaches an encoded screenshot artifact;
- the form opens immediately and no optional diagnostic failure blocks it;
- submitted reports survive offline use and forced restart without duplication;
- sanitized native reports reach an isolated project inbox; and
- Crumb remains effectively idle before explicit invocation.

## Current implementation status

The repository is currently at **M1: local native proof of concept**:

- iOS and Android implement native invocation, screenshot masking, a report
  form, one-time diagnostics, and a durable local report queue.
- Reporter state survives rotation and normal background/foreground transitions.
- Explicitly submitted reports are atomically persisted in app-private storage,
  survive restart, and retain pending/uploading/failed state without evicting
  existing reports when the queue is full.
- Project-authenticated ingestion, PostgreSQL metadata, and S3-compatible
  artifact verification are implemented locally.
- The reliable native uploader and web inbox remain planned for `0.0.1`.
