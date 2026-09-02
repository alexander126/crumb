# Contributing to the public SDK repository

This file applies to the whole repository. Read it together with the linked
GitHub issue, the pull-request template, and the contributor guide before
changing files.

## Repository boundary

This is Crumb's public SDK repository. It contains the distributable native
SDKs, the thin React Native adapter, public wire contracts, examples, and
public integration and release documentation.

The following do not belong here or in public issues, pull requests, comments,
logs, screenshots, or test artifacts:

- hosted service, dashboard, or internal operations implementation;
- provider configuration, deployment details, internal URLs, or access
  instructions;
- credentials, tokens, signing material, private keys, or generated secrets;
- customer names, customer data, real report contents, or production evidence.

Use synthetic values and placeholders in examples. Keep local credentials in
the ignored configuration files already documented by the repository. If a
task would require private information or production access, stop and report
the boundary instead of moving that information into this repository.

## Supported products and floors

- Native iOS: Swift Package Manager and CocoaPods, iOS 15 or newer.
- Native Android: Maven artifacts, Android API 26 or newer, Java 17 bytecode.
- React Native: the `@crumbsdk/react-native` Nitro adapter with React Native
  0.79 or newer, iOS 15.1 or newer, and Android API 26 or newer.
- Expo: development builds only. Expo Go is not supported because the adapter
  contains native code.

Do not lower a support floor, add a platform claim, or change a public package
identity without an issue whose acceptance criteria explicitly cover it.

## Sources of truth

Resolve disagreements in this order, and stop for clarification when the
sources cannot be reconciled:

1. The linked GitHub issue is the source of truth for the current task,
   including scope, non-goals, acceptance criteria, dependencies, and stop
   conditions.
2. `docs/product-invariants.md` and accepted decisions in `docs/architecture/`
   define product and privacy boundaries.
3. `schemas/` and `docs/contracts/` define public report and integration
   contracts.
4. `Package.swift`, the Android Gradle modules, and
   `packages/react-native/package.json` define the implemented package
   surfaces and their build requirements.
5. `README.md`, `docs/getting-started.md`, and package READMEs define public
   installation and usage guidance.
6. `package.json`, the scripts under `scripts/`, and `.github/workflows/`
   define the validation and release automation that actually runs.
7. `VERSION`, `CHANGELOG.md`, and `docs/distribution/` define versioning,
   release artifacts, and registry rehearsal boundaries.

Do not infer a private service contract from a public SDK task. Public
documentation must remain usable without private access.

## Work organization

- Work one GitHub issue at a time and deliver one focused pull request for
  that issue.
- Start by checking the worktree for existing changes. Preserve unrelated
  changes and never overwrite a user-owned file without stopping for review.
- Use a branch based on the current `main` branch, named
  `codex/<issue-number>-<short-slug>`. Do not commit directly to `main`, force
  rewrite shared history, or create a second PR for the same issue.
- Read the issue's blocked-by and blocking relationships before starting. A
  blocking issue is not a reason to pull its product work into this branch.
- Independent branches are the default. Use `gh-stack` only when a real
  dependency between reviewable changes exists in this same repository. Do
  not stack across repositories or create a stack merely to group unrelated
  documentation or policy changes.
- The implementation worker never merges its own pull request. An independent
  reviewer must examine scope, privacy, security, acceptance criteria,
  dependency order, and validation evidence before the coordinator merges.
- Do not change branch protection or other repository settings as part of an
  implementation PR. If GitHub requires an account or branch-policy decision,
  stop and report it.

## Validation expectations

Run the narrowest relevant checks locally, record the exact commands and
results in the pull request, and explain every skipped check. The current
workflows map to these commands:

| Change area | Required local checks |
| --- | --- |
| Contracts, native code, or root build scripts | `npm ci`, then `npm run contracts:check` and the affected native test (`npm run test:ios` or `npm run test:android`) |
| Native release or distribution behavior | `npm run release:check`, then `npm run release:prepare && npm run release:verify` when release artifacts are in scope |
| React Native package | From `packages/react-native`: `corepack enable`, `yarn install --immutable`, `yarn quality`, and `yarn pack:check` |
| React Native package native examples | From `packages/react-native`, run `yarn nitrogen` and the platform-specific Expo prebuild and example build used by `.github/workflows/react-native-ci.yml` |
| Standalone React Native consumer example | From `examples/react-native`: `npm ci`, `npm run typecheck`, and the affected `npm run build:android` or `npm run build:ios` |
| Documentation, templates, or policy only | Parse YAML, inspect rendered Markdown and relative links, and run any contract check affected by the edit; no documentation build is configured, so do not claim one was run |

The root `npm test` command runs the contract check and both native unit-test
suites. The native CI workflow also runs the release gate and release artifact
verification on every pull request. React Native package and consumer-example
workflows are path-filtered; run them when their paths or workflow inputs are
changed. Physical-device and hosted compatibility checks are acceptance-driven
and must use the documented quality matrix, synthetic data, and private local
evidence handling.

## Shared resources and release locks

- Coordinate before controlling a shared iOS device, Android device or
  emulator, hosted device session, or other exclusive test resource. Only one
  active task should control a given shared resource at a time.
- Device tests must use a disposable build, synthetic data, and ignored local
  configuration. Keep recordings, logs, screenshots, and result bundles out of
  this public repository unless the issue explicitly calls for a sanitized
  public fixture.
- Package publication, release-tag creation, and live registry verification
  are manual release actions, not implementation validation. They require
  Alex's explicit approval and must not be performed by a worker.
- Never run production, billing, domain, provider, migration, or other live
  service actions from this repository task. A local rehearsal is valid only
  when it uses temporary or mocked destinations and no live credentials.

## Stop conditions

Pause and report instead of guessing when any of the following occurs:

- the issue is ambiguous, contradictory, materially broader than its stated
  scope, or missing a required product decision;
- a required dependency is not ready or a stack would need to cross repository
  boundaries;
- the change would expose private content, weaken a privacy invariant, or
  require customer data;
- credentials, production access, a live provider, a package publication,
  registry ownership, a shared device lock, or a live charge is required;
- existing user changes overlap the requested files;
- GitHub branch protection, permissions, or account policy requires a decision
  that this implementation cannot safely make.

The stop report should identify the exact boundary, the evidence observed, and
the smallest decision or external action needed to continue. Do not work around
a stop condition by weakening validation or hiding information in generated
artifacts.
