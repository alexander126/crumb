import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const failures = [];

function read(relativePath) {
  return readFileSync(join(root, relativePath), "utf8");
}

function requireMatch(relativePath, pattern, message) {
  if (!pattern.test(read(relativePath))) failures.push(message);
}

function walk(relativePath) {
  const absolute = join(root, relativePath);
  return readdirSync(absolute, { withFileTypes: true }).flatMap((entry) => {
    const child = join(relativePath, entry.name);
    return entry.isDirectory() ? walk(child) : [child];
  });
}

requireMatch("Package.swift", /\.iOS\(\.v15\)/, "iOS minimum must remain iOS 15.");
requireMatch(
  "packages/android/crumb-ui/build.gradle",
  /minSdk\s+26/,
  "Android UI minimum must remain API 26.",
);
requireMatch(
  "packages/android/crumb-core/build.gradle",
  /minSdk\s+26/,
  "Android core minimum must remain API 26.",
);

const catalogs = [
  "packages/ios/Sources/CrumbUI/Resources/en.lproj/Localizable.strings",
  "packages/android/crumb-ui/src/main/res/values/strings.xml",
];
for (const catalog of catalogs) {
  if (!existsSync(join(root, catalog))) failures.push(`Missing localization catalog: ${catalog}`);
}

const nativeSources = ["packages/ios/Sources", "packages/android"].flatMap((directory) =>
  walk(directory).filter((path) => [".swift", ".kt", ".java"].includes(extname(path))),
);
const forbiddenCrashHooks = [
  "NSSetUncaughtExceptionHandler",
  "setDefaultUncaughtExceptionHandler",
  "SentrySDK.start",
  "FirebaseCrashlytics.getInstance",
];
for (const source of nativeSources) {
  const contents = read(source);
  for (const hook of forbiddenCrashHooks) {
    if (contents.includes(hook)) failures.push(`${source} must not install or initialize ${hook}.`);
  }
}

const aarBudgets = new Map([
  ["packages/android/crumb-core/build/outputs/aar/crumb-core-release.aar", 256 * 1024],
  ["packages/android/crumb-ui/build/outputs/aar/crumb-ui-release.aar", 256 * 1024],
]);
for (const [artifact, budget] of aarBudgets) {
  const absolute = join(root, artifact);
  if (!existsSync(absolute)) {
    failures.push(`Missing release artifact: ${artifact}`);
    continue;
  }
  const size = statSync(absolute).size;
  if (size > budget) failures.push(`${artifact} is ${size} bytes; budget is ${budget} bytes.`);
  else console.log(`PASS ${artifact}: ${size} / ${budget} bytes`);
}

if (failures.length > 0) {
  failures.forEach((failure) => console.error(`FAIL ${failure}`));
  process.exit(1);
}

console.log("PASS supported OS, localization, crash-SDK coexistence, and Android binary budgets");
