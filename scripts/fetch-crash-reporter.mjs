// Downloads the pinned PLCrashReporter archive for CI with an authenticated request.
//
// Unauthenticated downloads from GitHub Releases are the first to be throttled or
// timed out when GitHub is degraded, and every iOS packaging and lint job needs this
// archive. `gh release download` signs the request with the workflow's read-only
// token instead. The pin is read from the wrapper podspec, which the release gate
// already checks against every other copy, so this script adds no new copy of it.
//
// The archive is verified against the pinned SHA-256 here, and again by each
// consumer (prepare-ios.mjs and the podspec lint staging) through the existing
// CRUMB_PLCRASH_ARCHIVE input. Under GitHub Actions that variable is exported to the
// later steps of the job. Local development does not need this script.
//
// Usage: node scripts/fetch-crash-reporter.mjs [destination-directory]
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { readCrashReporterPin } from "./ios-required-reasons.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { url, sha256 } = readCrashReporterPin(root);
const release = url.match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/releases\/download\/([^/]+)\/([^/]+\.zip)$/);
if (!release) throw new Error(`Pinned PLCrashReporter URL is not a GitHub release asset: ${url}`);
const [, repository, tag, asset] = release;

const directory = resolve(process.argv[2] ?? process.env.RUNNER_TEMP ?? tmpdir());
mkdirSync(directory, { recursive: true });
const archive = join(directory, asset);

const digest = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

const delays = [0, 10_000, 30_000, 60_000];
let downloaded = false;
for (const [attempt, delay] of delays.entries()) {
  if (delay) {
    console.log(`Retrying PLCrashReporter download in ${delay / 1000}s`);
    await sleep(delay);
  }
  rmSync(archive, { force: true });
  try {
    execFileSync("gh", ["release", "download", tag, "--repo", repository, "--pattern", asset, "--dir", directory], {
      stdio: "inherit",
    });
    downloaded = existsSync(archive);
    if (downloaded) break;
  } catch (error) {
    console.error(`PLCrashReporter download attempt ${attempt + 1} of ${delays.length} failed: ${error.message}`);
  }
}
if (!downloaded) throw new Error(`Could not download ${asset} from ${repository} ${tag}`);
if (digest(archive) !== sha256) {
  rmSync(archive, { force: true });
  throw new Error("Downloaded PLCrashReporter archive does not match the pinned SHA-256; refusing to use it.");
}

if (process.env.GITHUB_ENV) appendFileSync(process.env.GITHUB_ENV, `CRUMB_PLCRASH_ARCHIVE=${archive}\n`);
console.log(`Verified ${asset} (${sha256}) at ${archive}`);
