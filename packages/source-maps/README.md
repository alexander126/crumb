# @crumbsdk/source-maps

An explicit CI command for uploading a React Native release bundle and its
matching source map. Requires Node.js 22 or newer. It never runs inside your app
and has no runtime dependencies.

**Implementation preview:** this package is not yet published. Uploads require
a service implementing the [v1 upload contract](https://github.com/alexander126/crumb/blob/main/docs/contracts/source-map-upload.md)
and a dedicated project-scoped upload credential. A local dry-run does not
require either. Hosted compatibility and package publication are release gates.

## Run from this checkout

```sh
cd packages/source-maps
npm ci
npm run build
node dist/cli.js --help
```

After an approved package release, install its exact version as a development
dependency and use `crumb-source-maps` from a package script. Do not resolve an
unversioned package on each release build.

## Upload the exact release

Choose a unique immutable JavaScript bundle version for each exported build,
and supply the same value to the app's Crumb `release.bundleVersion`. Use the
actual native app version and build number embedded in the distributed binary.
Never use a branch name, mutable channel name, or an EAS runtime version as the
only bundle identity.

The example assumes the following variables are set by your build job:
`CRUMB_UPLOAD_ORIGIN`, `CRUMB_PLATFORM`, `APP_VERSION`, `NATIVE_BUILD`,
`JS_BUNDLE_VERSION`, `BUNDLE_FILE`, and `SOURCE_MAP_FILE`.
`CRUMB_SOURCE_MAP_TOKEN` must come from your CI secret store. It is a dedicated
upload credential; the SDK write key embedded in the app cannot upload maps.

```sh
node dist/cli.js upload \
  --url "$CRUMB_UPLOAD_ORIGIN" \
  --platform "$CRUMB_PLATFORM" \
  --app-version "$APP_VERSION" \
  --native-build "$NATIVE_BUILD" \
  --bundle-version "$JS_BUNDLE_VERSION" \
  --bundle "$BUNDLE_FILE" \
  --source-map "$SOURCE_MAP_FILE"
```

Use `ios` or `android`, including for React Native. All release fields are
required. Identity values start with a letter or digit and contain only letters,
digits, dot, underscore, plus or hyphen. App version and native build are at most
64 characters; bundle version is at most 128.

Add `--dry-run` to validate and hash files without network access or reading a
credential. Add `--expected-bundle-sha256` and `--expected-source-map-sha256` to
verify checksums saved by an earlier build step. Supply lowercase hexadecimal
SHA-256 values. The command rejects a mismatch before making any request.

Alternatively, supply `--token-file /path/to/ci-secret`. A single trailing newline
is accepted. Do not also set `CRUMB_SOURCE_MAP_TOKEN`. No command-line token flag
is supported, no credentials are discovered automatically, and the tool never
prints the token, input paths, bundle, map, signed URLs or server response body.
Keep shell tracing disabled for secret-handling steps. Never put upload secrets
in app configuration or an `EXPO_PUBLIC_*` variable.

Only HTTPS is accepted. The API origin must not contain a path, query, fragment
or credentials. Redirects are rejected, and authorization is never forwarded to
artifact upload locations. `--allow-localhost` permits HTTP only on localhost,
127.0.0.1 or ::1 for local fixture tests.

## Results and retries

Except for `--help`, stdout/stderr contain one JSON result. Success exits 0;
failure exits 1. Success is written to stdout; failure to stderr.

```json
{"ok":true,"status":"verified","upload_id":"00000000-0000-4000-8000-000000000001","manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
```

`verified` means the service verified and stored both artifacts. It does not
mean any crash has been symbolicated. Dry-run returns `status: "dry_run"`, the
manifest digest and both byte counts; it makes no storage claim.

```json
{"ok":false,"error":{"code":"release_conflict","message":"This release identity already has different artifacts. Use the matching build or a new bundle version."}}
```

Rerun the **same command with unchanged artifacts** after a timeout or interrupted
upload. The service can refresh expired upload locations, and exact duplicates
return the same upload ID. The CLI does not automatically retry. Each request
has a 60-second deadline. A different artifact pair under the same release is a
conflict; use the correct build or assign a new bundle version and rebuild.

Common failure codes: `invalid_arguments`, `invalid_release`, `invalid_platform`,
`file_unavailable`, `invalid_size`, `invalid_source_map`, `checksum_mismatch`,
`missing_token`, `ambiguous_token`, `invalid_token`, `unauthorized`,
`release_conflict`, `artifact_rejected`, `artifact_too_large`, `rate_limited`,
`artifact_upload_failed`, `network_error`, and `invalid_response`.

## Build artifacts and limits

Supply the final bundle shipped to users and the final corresponding v3 map.
For Hermes, this means the bytecode bundle and the map composed through Hermes,
not only the intermediate Metro packager map. Never rebuild just to obtain a
missing map: archive both outputs of the original build together.

Both files must be nonempty regular files, at most 25 MiB each. Standard and
inline indexed maps are supported; external section URLs are rejected. Map
validation checks JSON structure, not whether every mapping correctly describes
the compiled bundle. Hashes establish byte identity, not semantic correctness.
Confirm a synthetic crash resolves to its known source location before release.
The tool never executes a bundle or downloads source URLs.

Source maps may contain original source code in `sourcesContent`. The matching
bundle and map are deliberately uploaded as private release artifacts. Review
your build outputs, use a narrowly scoped CI credential, and keep these files
out of public build artifacts and the app's published assets when unnecessary.

See the [Metro, bare React Native and Expo/EAS guide](https://github.com/alexander126/crumb/blob/main/docs/source-maps.md)
for release-pipeline examples.

## Package checks and publication

```sh
npm ci
npm run typecheck
npm test
npm run pack:check
```

The packaging check installs the produced tarball offline, invokes its executable,
and performs a dry-run. The allowlist contains only compiled CLI files, this
README, the license and package metadata.

The package version must match the root `VERSION`; when bumping it, update this
package and its lockfile together. The manual `source-maps-npm-publish.yml`
workflow requires the immutable native release tag `<version>` and the explicit
confirmation `publish @crumbsdk/source-maps@<version>`. Prereleases use `next`;
stable releases use `latest`. The workflow runs checks before publishing using
npm trusted publishing. Registry ownership/trusted-publisher setup and the first
publication require an authorized release owner; they are not performed by CI
checks or this CLI.
