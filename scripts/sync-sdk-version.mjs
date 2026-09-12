import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const checkOnly = process.argv.includes("--check");

if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`VERSION must contain a semantic version; received ${JSON.stringify(version)}`);
}

const generatedFiles = [
  {
    path: join(root, "packages/ios/Sources/CrumbCore/CrumbSDKVersion.swift"),
    content: `// Generated from the repository VERSION file. Do not edit by hand.\n\npublic enum CrumbSDKVersion {\n    public static let current = "${version}"\n}\n`,
  },
  {
    path: join(root, "packages/android/crumb-core/src/main/kotlin/dev/crumb/core/CrumbSDKVersion.kt"),
    content: `// Generated from the repository VERSION file. Do not edit by hand.\npackage dev.crumb.core\n\nobject CrumbSDKVersion {\n    const val CURRENT = "${version}"\n}\n`,
  },
];

// These distributables are released from the same source commit as the natives.
for (const packagePath of ["packages/react-native", "packages/source-maps"]) {
  const path = join(root, packagePath, "package.json");
  const metadata = JSON.parse(readFileSync(path, "utf8"));
  metadata.version = version;
  if (packagePath === "packages/react-native") metadata.crumbNativeVersion = version;
  generatedFiles.push({ path, content: `${JSON.stringify(metadata, null, 2)}\n` });
}
const lockPath = join(root, "packages/source-maps/package-lock.json");
const lock = JSON.parse(readFileSync(lockPath, "utf8"));
lock.version = version;
lock.packages[""].version = version;
generatedFiles.push({ path: lockPath, content: `${JSON.stringify(lock, null, 2)}\n` });

let stale = false;
for (const generatedFile of generatedFiles) {
  let current = null;
  try {
    current = readFileSync(generatedFile.path, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  if (current === generatedFile.content) continue;
  stale = true;
  if (!checkOnly) writeFileSync(generatedFile.path, generatedFile.content);
}

if (checkOnly && stale) {
  throw new Error("SDK package metadata or generated version sources are stale. Run npm run version:sync.");
}

console.log(`${checkOnly ? "Verified" : "Synchronized"} SDK distribution versions ${version}.`);
