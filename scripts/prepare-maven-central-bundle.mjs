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
import { dirname, join, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const signingKey = process.env.ORG_GRADLE_PROJECT_signingInMemoryKey;

if (!signingKey) {
  throw new Error("ORG_GRADLE_PROJECT_signingInMemoryKey is required");
}

const outputRoot = join(root, "dist", "registry", "maven", version);
const stagingRepository = join(outputRoot, "staging");
const bundleRepository = join(outputRoot, "bundle");
const bundlePath = join(outputRoot, `crumb-maven-central-${version}.zip`);

rmSync(outputRoot, { recursive: true, force: true });
mkdirSync(stagingRepository, { recursive: true });

execFileSync(
  join(root, "packages", "android", "gradlew"),
  [
    "-p",
    join(root, "packages", "android"),
    "--no-daemon",
    ":crumb-core:publishReleasePublicationToStagingRepository",
    ":crumb-ui:publishReleasePublicationToStagingRepository",
    `-PcrumbRepository=${stagingRepository}`,
  ],
  { cwd: root, stdio: "inherit" },
);

function copyTree(source, destination) {
  mkdirSync(destination, { recursive: true });
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const sourcePath = join(source, entry.name);
    const destinationPath = join(destination, entry.name);
    if (entry.isDirectory()) {
      copyTree(sourcePath, destinationPath);
    } else {
      copyFileSync(sourcePath, destinationPath);
    }
  }
}

function checksum(path, algorithm) {
  return createHash(algorithm).update(readFileSync(path)).digest("hex");
}

const artifacts = ["crumb-core", "crumb-ui"];
const requiredSuffixes = [".aar", ".pom", ".module", "-sources.jar", "-javadoc.jar"];

for (const artifact of artifacts) {
  const relativeVersionPath = join("com", "crumbsdk", artifact, version);
  const source = join(stagingRepository, relativeVersionPath);
  const destination = join(bundleRepository, relativeVersionPath);
  if (!existsSync(source)) {
    throw new Error(`Staged Maven directory is missing: ${source}`);
  }
  copyTree(source, destination);

  for (const suffix of requiredSuffixes) {
    const artifactPath = join(destination, `${artifact}-${version}${suffix}`);
    if (!existsSync(artifactPath) || statSync(artifactPath).size === 0) {
      throw new Error(`Maven Central artifact is missing or empty: ${artifactPath}`);
    }
    const signaturePath = `${artifactPath}.asc`;
    if (!existsSync(signaturePath) || statSync(signaturePath).size === 0) {
      throw new Error(`Maven Central signature is missing or empty: ${signaturePath}`);
    }

    writeFileSync(`${artifactPath}.md5`, checksum(artifactPath, "md5"));
    writeFileSync(`${artifactPath}.sha1`, checksum(artifactPath, "sha1"));
  }
}

execFileSync("zip", ["-q", "-r", bundlePath, "com"], {
  cwd: bundleRepository,
  stdio: "inherit",
});

console.log(`Prepared signed Maven Central bundle: ${bundlePath}`);
