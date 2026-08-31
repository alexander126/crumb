import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`VERSION must contain a semantic version; received ${JSON.stringify(version)}`);
}

const releaseRoot = join(root, "dist", "release", version);
const stagingRoot = join(releaseRoot, ".staging");
const mavenRoot = join(stagingRoot, "maven");
const appleRoot = join(stagingRoot, "apple");

rmSync(releaseRoot, { recursive: true, force: true });
mkdirSync(mavenRoot, { recursive: true });
mkdirSync(appleRoot, { recursive: true });

function run(command, args, cwd = root) {
  execFileSync(command, args, { cwd, stdio: "inherit" });
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function copy(relativePath) {
  const destination = join(appleRoot, relativePath);
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(join(root, relativePath), destination);
}

run(join(root, "packages/android/gradlew"), [
  "-p",
  join(root, "packages/android"),
  "--rerun-tasks",
  `-PcrumbRepository=${mavenRoot}`,
  ":crumb-core:publishReleasePublicationToStagingRepository",
  ":crumb-ui:publishReleasePublicationToStagingRepository",
]);

for (const path of [
  "Package.swift",
  "CrumbSDK.podspec",
  "CrumbSDKCore.podspec",
  "CrumbSDKUI.podspec",
  "README.md",
  "CHANGELOG.md",
  "PRIVACY.md",
]) copy(path);
if (existsSync(join(root, "LICENSE"))) copy("LICENSE");

const androidArchive = `crumb-android-maven-${version}.zip`;
const appleArchive = `crumb-apple-metadata-${version}.zip`;
run("zip", ["-q", "-r", join(releaseRoot, androidArchive), "."], mavenRoot);
run("zip", ["-q", "-r", join(releaseRoot, appleArchive), "."], appleRoot);

const revision = execFileSync("git", ["rev-parse", "HEAD"], {
  cwd: root,
  encoding: "utf8",
}).trim();
const archives = [androidArchive, appleArchive].map((name) => {
  const path = join(releaseRoot, name);
  return { name, bytes: statSync(path).size, sha256: sha256(path) };
});
const manifest = {
  schema_version: 1,
  product: "Crumb native SDK",
  version,
  git_revision: revision,
  generated_at: new Date().toISOString(),
  artifacts: archives,
};
const manifestName = `crumb-release-${version}.json`;
writeFileSync(join(releaseRoot, manifestName), `${JSON.stringify(manifest, null, 2)}\n`);

const checksumFiles = [...archives.map(({ name }) => name), manifestName];
const checksums = checksumFiles
  .map((name) => `${sha256(join(releaseRoot, name))}  ${name}`)
  .join("\n");
writeFileSync(join(releaseRoot, "SHA256SUMS"), `${checksums}\n`);
rmSync(stagingRoot, { recursive: true, force: true });

const emitted = readdirSync(releaseRoot).sort();
console.log(`Prepared Crumb ${version} release artifacts:`);
for (const path of emitted) console.log(`- ${relative(root, join(releaseRoot, path))}`);
