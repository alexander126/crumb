# ADR 0001: Native SDKs before cross-platform adapters

- Status: accepted
- Date: 2026-08-19

## Context

The highest-risk behaviour is native: invocation, view capture and masking,
reporter presentation, encrypted local persistence, lifecycle handling, and
uploads. Reimplementing or coordinating that behaviour in JavaScript would
increase privacy risk and make platform behaviour diverge.

## Decision

Build and validate the SDKs in this order:

1. shared contracts;
2. complete iOS vertical slice;
3. Android parity against the same behavioural matrix;
4. thin React Native adapter;
5. issue grouping, agent investigation, and integrations.

The native SDK interface remains conceptually equivalent across Swift and
Kotlin. The React Native adapter delegates reporter UI, screenshots, masking,
storage, invocation, and upload behaviour to the native implementations.

## Consequences

- Native applications are first-class customers rather than implementation
  details of the React Native package.
- React Native integration starts later but sits on two proven implementations.
- Shared schemas and behavioural tests must be established before Android work
  to prevent platform drift.
- CocoaPods and Maven packaging are release gates for their respective native
  milestones.

