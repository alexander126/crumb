import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const releaseRoot = join(root, "dist", "release", version);

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

const lines = readFileSync(join(releaseRoot, "SHA256SUMS"), "utf8")
  .trim()
  .split("\n");
for (const line of lines) {
  const match = /^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
  if (!match) throw new Error(`Invalid checksum line: ${JSON.stringify(line)}`);
  const [, expected, name] = match;
  const actual = sha256(join(releaseRoot, name));
  if (actual !== expected) throw new Error(`Checksum mismatch for ${name}`);
}

const manifestName = `crumb-release-${version}.json`;
const manifest = JSON.parse(readFileSync(join(releaseRoot, manifestName), "utf8"));
if (manifest.version !== version) throw new Error("Release manifest version does not match VERSION");
if (!/^[0-9a-f]{40}$/.test(manifest.git_revision)) {
  throw new Error("Release manifest must contain a full Git revision");
}
const expectedArchives = new Set([
  `crumb-android-maven-${version}.zip`,
  `crumb-apple-metadata-${version}.zip`,
]);
for (const artifact of manifest.artifacts ?? []) {
  if (!expectedArchives.delete(artifact.name)) {
    throw new Error(`Unexpected release artifact ${JSON.stringify(artifact.name)}`);
  }
  const path = join(releaseRoot, artifact.name);
  if (statSync(path).size !== artifact.bytes) throw new Error(`Size mismatch for ${artifact.name}`);
  if (sha256(path) !== artifact.sha256) throw new Error(`Manifest checksum mismatch for ${artifact.name}`);
}
if (expectedArchives.size > 0) {
  throw new Error(`Release manifest is missing: ${[...expectedArchives].join(", ")}`);
}

const appleArchive = join(releaseRoot, `crumb-apple-metadata-${version}.zip`);
const appleEntries = execFileSync("unzip", ["-Z1", appleArchive], { encoding: "utf8" })
  .trim()
  .split("\n");
for (const requiredEntry of [
  "LICENSE",
  "PRIVACY.md",
  "CHANGELOG.md",
  "README.md",
  "CrumbSDK.podspec",
  "CrumbSDKCore.podspec",
  "CrumbSDKUI.podspec",
]) {
  if (!appleEntries.includes(requiredEntry)) {
    throw new Error(`Apple metadata archive is missing ${requiredEntry}`);
  }
}

const androidArchive = join(releaseRoot, `crumb-android-maven-${version}.zip`);
const androidEntries = new Set(execFileSync("unzip", ["-Z1", androidArchive], { encoding: "utf8" })
  .trim()
  .split("\n"));
for (const artifact of ["crumb-core", "crumb-ui"]) {
  for (const extension of ["aar", "pom"]) {
    const requiredEntry = `com/crumbsdk/${artifact}/${version}/${artifact}-${version}.${extension}`;
    if (!androidEntries.has(requiredEntry)) {
      throw new Error(`Android Maven archive is missing ${requiredEntry}`);
    }
  }
}

console.log(`Verified Crumb ${version} release manifest and ${lines.length} checksums.`);
