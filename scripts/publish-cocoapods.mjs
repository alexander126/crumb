import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();

if (!process.env.COCOAPODS_TRUNK_TOKEN) {
  throw new Error("COCOAPODS_TRUNK_TOKEN is required");
}

const pods = [
  ["CrumbSDKCore", "CrumbSDKCore.podspec"],
  ["CrumbSDKUI", "CrumbSDKUI.podspec"],
  ["CrumbSDK", "CrumbSDK.podspec"],
];

function alreadyPublished(name) {
  try {
    const output = execFileSync("pod", ["trunk", "info", name], {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`^\\s+- ${escapedVersion} \\(`, "m").test(output);
  } catch {
    return false;
  }
}

for (const [name, podspec] of pods) {
  if (alreadyPublished(name)) {
    console.log(`${name} ${version} is already published; skipping.`);
    continue;
  }

  try {
    execFileSync("pod", ["trunk", "push", podspec, "--synchronous"], {
      cwd: root,
      stdio: "inherit",
    });
  } catch (error) {
    if (alreadyPublished(name)) {
      console.warn(
        `${name} ${version} was accepted before CocoaPods reported a post-publication error; continuing.`,
      );
      continue;
    }
    throw error;
  }
}

console.log(`CocoaPods published Crumb ${version}.`);
