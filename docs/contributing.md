# Contributing to Crumb

This repository is the public SDK boundary. Contributions cover the Swift and
Kotlin SDKs, the React Native adapter, public contracts, examples, and public
documentation. Hosted services, private operations, customer data, provider
configuration, credentials, and production evidence stay outside this
repository and out of public GitHub discussion.

## Start with the issue

GitHub issues are the source of truth for implementation work. Before editing:

1. Read the complete issue, including non-goals, acceptance criteria,
   validation, dependencies, resource locks, privacy requirements, and stop
   conditions.
2. Inspect the issue's blocked-by and blocking relationships. Do not start a
   blocked issue, and do not pull a blocking issue's implementation into the
   current change.
3. Check the worktree for existing changes and preserve anything unrelated to
   the issue.
4. Confirm that the requested files and evidence can remain public. Use
   placeholders and synthetic data; never paste a secret or customer report
   into an issue, pull request, log, screenshot, or fixture.

Use the [implementation issue form](../.github/ISSUE_TEMPLATE/implementation.yml)
for new work. A good issue has one outcome, a finite scope, explicit
non-goals, testable acceptance criteria, exact validation, and a clear stop
condition.

## Roles and handoff

The normal flow is one issue, one implementation worker, one focused pull
request, and an independent review.

- The coordinator confirms that the issue is ready, checks dependencies and
  shared-resource locks, and selects the appropriate validation and reviewer.
- The implementation worker creates a branch from current `main`, changes
  only the issue's scope, runs the relevant checks, and records exact evidence
  in the pull request. The worker stops when a dependency, privacy boundary,
  credential, live service, branch policy, or product decision blocks safe
  progress.
- The independent reviewer is read-only with respect to the implementation
  and challenges scope expansion, privacy and security assumptions, unsupported
  claims, dependency mistakes, and missing validation.
- The coordinator merges an ordinary green PR after independent review. The
  implementation worker never merges its own PR.

Create branches with the repository convention:

```text
codex/<issue-number>-<short-slug>
```

Do not commit directly to `main`, rewrite shared history, or open multiple PRs
for one issue. Branch protection and repository settings are maintained outside
an implementation PR; stop if GitHub requires a policy or account decision.

## Independent branches and gh-stack

An independent branch from `main` is the default. Use it when the issue can be
reviewed and merged without another in-flight change, including documentation,
templates, contracts, and unrelated product work.

Use `gh-stack` only when two or more reviewable changes have a real dependency
inside this repository—for example, a lower-level public contract must land
before a package implementation can compile. Keep each stack entry tied to one
issue and one focused PR, state the order and dependency links in each PR, and
land the lower entry before the dependent entry.

Do not use a stack to bundle unrelated changes, to bypass review, or to connect
repositories. Cross-repository dependencies are tracked as issue links and
handled by each repository's own PR; they are never represented as one shared
stack.

## Validation

Use the commands already exercised by the package scripts and workflows:

- Native contracts and unit tests: `npm ci`, `npm run contracts:check`,
  `npm run test:ios`, and/or `npm run test:android` as applicable. The root
  `npm test` combines the contract check with both native test suites.
- Native release or distribution changes: `npm run release:check`, followed by
  `npm run release:prepare && npm run release:verify` when release artifacts
  are in scope.
- React Native package changes: from `packages/react-native`, run
  `corepack enable`, `yarn install --immutable`, `yarn quality`, and
  `yarn pack:check`; run the platform-specific example build when its native
  example is affected.
- Standalone consumer-example changes: from `examples/react-native`, run
  `npm ci`, `npm run typecheck`, and the affected Android or iOS build.
- Documentation or template changes: parse YAML, inspect rendered Markdown and
  relative links, and run any directly affected contract check. There is no
  repository documentation build configured, so report that fact rather than
  claiming a docs build.

The native CI workflow runs the release gate on every pull request. React
Native package and consumer-example workflows run when their path filters
match. Read the changed workflow before adding a new command to a PR report.

Physical-device and hosted-device checks are acceptance-driven. Coordinate the
exclusive device/session lock, use disposable builds and synthetic data, and
keep logs, recordings, screenshots, and result bundles in private evidence
storage. Package publication, release tags, and live registry checks are manual
release actions requiring Alex's explicit approval; they are not ordinary
validation steps.

## Pull request checklist

Use the [pull-request template](../.github/pull_request_template.md). Before
requesting review, confirm that the PR:

- links exactly one issue and explains the focused change;
- lists platform impact and exact validation evidence;
- records dependency or stack position and any skipped checks;
- passes the public-boundary and privacy review;
- includes sanitized previews only when they materially help review; and
- does not merge, publish packages, deploy services, change credentials, or
  perform other live production actions.

If the issue becomes ambiguous, expands materially, needs private information,
or encounters a missing dependency or resource lock, pause and report the
evidence and the smallest decision needed to continue.
