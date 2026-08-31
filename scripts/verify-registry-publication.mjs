import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const verifyCocoaPods = process.argv.includes("--cocoapods") || process.argv.length === 2;
const verifyMaven = process.argv.includes("--maven") || process.argv.length === 2;
const pollDeadline = Date.now() + 30 * 60 * 1000;

async function waitFor(label, check) {
  while (Date.now() < pollDeadline) {
    if (await check()) {
      console.log(`${label} is publicly available.`);
      return;
    }
    console.log(`Waiting for ${label} registry propagation...`);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 15_000));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function cocoaPodsHasVersion(name) {
  try {
    const output = execFileSync("pod", ["trunk", "info", name], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`^\\s+- ${escapedVersion} \\(`, "m").test(output);
  } catch {
    return false;
  }
}

async function mavenArtifactExists(artifact, suffix) {
  const url = `https://repo.maven.apache.org/maven2/com/crumbsdk/${artifact}/${version}/${artifact}-${version}${suffix}`;
  const response = await fetch(url, { method: "HEAD", cache: "no-store" });
  return response.ok;
}

if (verifyCocoaPods) {
  for (const pod of ["CrumbSDKCore", "CrumbSDKUI", "CrumbSDK"]) {
    await waitFor(`CocoaPods ${pod} ${version}`, () => cocoaPodsHasVersion(pod));
  }
  execFileSync("pod", ["spec", "cat", "CrumbSDK", `--version=${version}`], {
    cwd: root,
    stdio: "inherit",
  });
}

if (verifyMaven) {
  for (const artifact of ["crumb-core", "crumb-ui"]) {
    for (const suffix of [".pom", ".aar", "-sources.jar", "-javadoc.jar"]) {
      await waitFor(`Maven Central ${artifact}-${version}${suffix}`, () =>
        mavenArtifactExists(artifact, suffix),
      );
    }
  }

  const rehearsalRoot = mkdtempSync(join(tmpdir(), "crumb-central-consumer-"));
  try {
    execFileSync(
      join(root, "packages", "android", "gradlew"),
      [
        "-p",
        join(root, "distribution", "consumers", "android"),
        "--project-cache-dir",
        join(rehearsalRoot, "cache"),
        "-PcrumbRepository=https://repo.maven.apache.org/maven2",
        `-PcrumbVersion=${version}`,
        `-PcrumbConsumerBuildDir=${join(rehearsalRoot, "build")}`,
        ":app:assembleDebug",
      ],
      { cwd: root, stdio: "inherit" },
    );
  } finally {
    rmSync(rehearsalRoot, { recursive: true, force: true });
  }
}

console.log(`Verified Crumb ${version} registry publication.`);
