#!/usr/bin/env node
import { parseArgs } from "node:util";
import { prepareUpload, upload } from "./upload.js";
import { readBoundedFile, UploadError } from "./validation.js";

const HELP = `crumb-source-maps upload --platform ios|android --app-version VERSION
  --native-build BUILD --bundle-version ID --bundle FILE --source-map FILE
  --url HTTPS_API_ORIGIN [--token-file FILE]
  [--expected-bundle-sha256 HASH] [--expected-source-map-sha256 HASH]
  [--dry-run] [--allow-localhost]

Credentials: CRUMB_SOURCE_MAP_TOKEN or --token-file, never a command-line token.
--dry-run validates and hashes inputs without reading credentials or using network.
Inputs: final matching build artifacts, at most 25 MiB each. Node.js 22 or newer.
Successful upload means verified storage, not successful crash symbolication.
Outputs are JSON except --help. Exit code 0 is success; 1 is a safe failure.
`;

async function main(): Promise<void> {
  let parsed;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      strict: true,
      tokens: true,
      options: {
        help: { type: "boolean", short: "h" },
        "dry-run": { type: "boolean" },
        "allow-localhost": { type: "boolean" },
        url: { type: "string" },
        platform: { type: "string" },
        "app-version": { type: "string" },
        "native-build": { type: "string" },
        "bundle-version": { type: "string" },
        bundle: { type: "string" },
        "source-map": { type: "string" },
        "token-file": { type: "string" },
        "expected-bundle-sha256": { type: "string" },
        "expected-source-map-sha256": { type: "string" },
      },
    });
    const seen = new Set<string>();
    for (const token of parsed.tokens) {
      if (token.kind !== "option") continue;
      if (seen.has(token.name)) throw new Error("duplicate option");
      seen.add(token.name);
    }
  } catch {
    throw new UploadError(
      "invalid_arguments",
      "Invalid command options. Use --help; credentials are accepted only through environment or a secret file.",
    );
  }
  const { values, positionals } = parsed;
  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (
    positionals.length !== 1 ||
    positionals[0] !== "upload" ||
    !values.bundle ||
    !values["source-map"]
  )
    throw new UploadError(
      "invalid_arguments",
      "Use upload with release identity, --bundle and --source-map. See --help.",
    );
  const prepared = await prepareUpload({
    platform: values.platform,
    appVersion: values["app-version"],
    nativeBuild: values["native-build"],
    bundleVersion: values["bundle-version"],
    bundle: values.bundle,
    sourceMap: values["source-map"],
    expectedBundleSha256: values["expected-bundle-sha256"],
    expectedSourceMapSha256: values["expected-source-map-sha256"],
  });
  if (values["dry-run"]) {
    process.stdout.write(
      `${JSON.stringify({ ok: true, status: "dry_run", manifest_sha256: prepared.manifestSha256, bundle_bytes: prepared.bundle.length, source_map_bytes: prepared.sourceMap.length })}\n`,
    );
    return;
  }
  if (!values.url)
    throw new UploadError(
      "invalid_arguments",
      "Supply the HTTPS upload API origin with --url.",
    );
  if (values["token-file"] && process.env.CRUMB_SOURCE_MAP_TOKEN)
    throw new UploadError(
      "ambiguous_token",
      "Choose one credential source: CRUMB_SOURCE_MAP_TOKEN or --token-file.",
    );
  const token = values["token-file"]
    ? (await readBoundedFile(values["token-file"], 4098))
        .toString("utf8")
        .replace(/\r?\n$/, "")
    : process.env.CRUMB_SOURCE_MAP_TOKEN;
  if (!token)
    throw new UploadError(
      "missing_token",
      "Set CRUMB_SOURCE_MAP_TOKEN or supply --token-file with a dedicated upload credential.",
    );
  const result = await upload(prepared, {
    url: values.url,
    token,
    allowLocalhost: values["allow-localhost"] === true,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

main().catch((error: unknown) => {
  const safe =
    error instanceof UploadError
      ? error
      : new UploadError(
          "upload_failed",
          "The upload could not complete. Check the build inputs and retry.",
        );
  process.stderr.write(
    `${JSON.stringify({ ok: false, error: { code: safe.code, message: safe.message } })}\n`,
  );
  process.exitCode = 1;
});
