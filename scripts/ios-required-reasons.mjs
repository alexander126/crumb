import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const expectedReasons = {
  CrumbCore: [["NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"]]],
  CrumbUI: [
    ["NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"]],
    ["NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1"]],
  ],
};

export function verifyReasonDeclarations(manifest, module) {
  assert.ok(expectedReasons[module], `Unknown Crumb module: ${module}`);
  assert.deepEqual(Object.keys(manifest).sort(), ["NSPrivacyAccessedAPITypes"], "Required-reason coverage must not invent collection or tracking declarations");
  assert.ok(Array.isArray(manifest.NSPrivacyAccessedAPITypes));
  const actual = manifest.NSPrivacyAccessedAPITypes.map((entry) => {
    assert.deepEqual(Object.keys(entry).sort(), ["NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"]);
    return [entry.NSPrivacyAccessedAPIType, entry.NSPrivacyAccessedAPITypeReasons];
  }).sort(([left], [right]) => left.localeCompare(right));
  assert.deepEqual(actual, expectedReasons[module], `${module} must declare exactly its reviewed API categories and reasons`);
}

export function verifyRequiredReasonFile(path, module) {
  assert.ok(existsSync(path), `Missing ${module}'s own privacy manifest: ${path}`);
  const manifest = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", path], { encoding: "utf8" }));
  verifyReasonDeclarations(manifest, module);
  return path;
}

function verifyContainedResource(root, path, description) {
  const location = relative(realpathSync(root), realpathSync(path));
  assert.ok(location && location !== ".." && !location.startsWith(`..${sep}`) && !isAbsolute(location), `${description} must remain inside ${root}`);
}

export function verifyOwnedPrivacyBundles(product, modules, distribution) {
  assert.ok(["swiftpm", "cocoapods"].includes(distribution));
  const manifests = [];
  const failures = [];
  for (const module of modules) {
    try {
      const bundle = join(product, `${distribution === "swiftpm" ? "Crumb_" : ""}${module}.bundle`);
      assert.ok(existsSync(bundle), `Missing embedded ${module} resource bundle: ${bundle}`);
      verifyContainedResource(product, bundle, `${module} resource bundle`);
      const candidates = [join(bundle, "PrivacyInfo.xcprivacy"), join(bundle, "Contents/Resources/PrivacyInfo.xcprivacy")].filter(existsSync);
      assert.equal(candidates.length, 1, `${module}'s own bundle must contain exactly one privacy manifest`);
      verifyContainedResource(bundle, candidates[0], `${module} privacy manifest`);
      manifests.push(verifyRequiredReasonFile(candidates[0], module));
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length) throw new AggregateError(failures, failures.map((error) => error.message).join("; "));
  return manifests;
}

export function verifyBundledNativePrivacy(sourceRoot, nativeRoot) {
  for (const module of Object.keys(expectedReasons)) {
    const relative = `packages/ios/Sources/${module}/Resources/PrivacyInfo.xcprivacy`;
    assert.ok(existsSync(join(nativeRoot, relative)), `Missing bundled ${module} privacy manifest: ${relative}`);
    assert.deepEqual(readFileSync(join(nativeRoot, relative)), readFileSync(join(sourceRoot, relative)), `Bundled ${module} manifest differs from native source`);
  }
  for (const podspec of ["CrumbSDKCore.podspec", "CrumbSDKUI.podspec"]) {
    assert.deepEqual(readFileSync(join(nativeRoot, podspec)), readFileSync(join(sourceRoot, podspec)), `Bundled ${podspec} differs from native source`);
  }
}

function run(command, args, cwd) {
  execFileSync(command, args, { cwd, stdio: "inherit" });
}

export function verifySwiftPrivacyConsumers(root, temporary, remoteRevision = null) {
  const version = readFileSync(join(root, "VERSION"), "utf8").trim();
  const failures = [];
  for (const modules of [["CrumbCore"], ["CrumbCore", "CrumbUI"]]) {
    const consumer = join(temporary, `swift-${modules.length === 1 ? "core" : "ui"}`);
    const sources = join(consumer, "Sources/CrumbDistributionConsumer");
    mkdirSync(sources, { recursive: true });
    const dependency = remoteRevision
      ? `.package(url: "https://github.com/alexander126/crumb.git", revision: "${remoteRevision}")`
      : `.package(name: "crumb", path: ${JSON.stringify(root)})`;
    writeFileSync(join(consumer, "Package.swift"), `// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrumbDistributionConsumer", platforms: [.macOS(.v13)], dependencies: [${dependency}], targets: [
    .executableTarget(name: "CrumbDistributionConsumer", dependencies: [${modules.map((module) => `.product(name: "${module}", package: "crumb")`).join(", ")}])
])
`);
    writeFileSync(join(sources, "main.swift"), `${modules.map((module) => `import ${module}`).join("\n")}
try Crumb.start(CrumbConfiguration(projectKey: "distribution_rehearsal", environment: "test", release: CrumbRelease(appVersion: "1.0", nativeBuild: "1")))
precondition(CrumbSDKVersion.current == "${version}")
print(CrumbSDKVersion.current)
`);
    run("swift", ["build", "--package-path", consumer]);
    const product = execFileSync("swift", ["build", "--package-path", consumer, "--show-bin-path"], { encoding: "utf8" }).trim();
    console.log(`Built ${modules.join("+")} SwiftPM consumer bundles: ${readdirSync(product).filter((name) => name.endsWith(".bundle")).join(", ")}`);
    if (modules.length === 1) assert.ok(!existsSync(join(product, "Crumb_CrumbUI.bundle")), "The Core-only consumer must not build UI resources");
    try {
      console.log(`Verified SwiftPM consumer manifests: ${verifyOwnedPrivacyBundles(product, modules, "swiftpm").join(", ")}`);
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length) throw new AggregateError(failures, "Built SwiftPM consumers are missing SDK-owned required-reason coverage");
}

// Every Crumb podspec depends on PLCrashReporter. The upstream trunk pod declares
// an iOS minimum that Xcode 27 rejects, so lint against Crumb's wrapper —
// the same podspec the installation documentation tells consumers to select.
export const CRASH_REPORTER_PODSPEC = "distribution/cocoapods/PLCrashReporter.podspec";

// `pod lib lint --include-podspecs` treats an included podspec as a local pod: it
// resolves vendored_frameworks from the podspec's own directory and never fetches
// the podspec's `source`. A real consumer selecting the wrapper from a Podfile does
// download it. So the lint needs the pinned framework staged beside the wrapper,
// reusing the React Native package's already-extracted copy when it is present and
// otherwise fetching the same archive the wrapper pins.
// The wrapper podspec is the one place scripts read the PLCrashReporter pin from;
// verify-native-distribution checks that every other copy of the pin agrees with it.
export function readCrashReporterPin(root) {
  const podspec = readFileSync(join(root, CRASH_REPORTER_PODSPEC), "utf8");
  const url = podspec.match(/https:\/\/github\.com\/microsoft\/plcrashreporter\/releases\/download\/\S+?\.zip/)?.[0];
  const sha256 = podspec.match(/sha256['"]?\s*[:=]>?\s*['"]([0-9a-f]{64})['"]/)?.[1];
  assert.ok(url && sha256, `${CRASH_REPORTER_PODSPEC} must pin an archive URL and SHA-256`);
  return { url, sha256 };
}

// An archive fetched ahead of time (scripts/fetch-crash-reporter.mjs in CI) is named
// by CRUMB_PLCRASH_ARCHIVE, the same input prepare-ios.mjs already accepts. It is
// still checked against the pin before anything is extracted.
export function stageCrashReporterForLint(root) {
  const destination = join(root, dirname(CRASH_REPORTER_PODSPEC), "CrashReporter.xcframework");
  const { url, sha256 } = readCrashReporterPin(root);

  // Record which pin the staged copy came from, so bumping the pinned archive
  // restages instead of silently linting against the previous framework.
  const stamp = `${destination}.pin`;
  if (existsSync(destination)) {
    if (existsSync(stamp) && readFileSync(stamp, "utf8").trim() === sha256) return;
    rmSync(destination, { recursive: true, force: true });
  }

  const bundled = join(root, "packages/react-native/native/ios/PLCrashReporter/CrashReporter.xcframework");
  if (existsSync(bundled)) {
    run("cp", ["-R", bundled, destination], root);
    writeFileSync(stamp, `${sha256}\n`);
    console.log(`Staged CrashReporter.xcframework for lint from the React Native package copy`);
    return;
  }

  const staging = mkdtempSync(join(tmpdir(), "crumb-crashreporter-"));
  try {
    const provided = process.env.CRUMB_PLCRASH_ARCHIVE;
    const archive = provided || join(staging, "CrashReporter.xcframework.zip");
    if (!provided) {
      run("curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--retry-all-errors", "--connect-timeout", "30", "--output", archive, url], root);
    }
    const digest = execFileSync("shasum", ["-a", "256", archive], { encoding: "utf8" }).split(/\s+/)[0];
    assert.equal(digest, sha256, `PLCrashReporter archive ${provided ? "named by CRUMB_PLCRASH_ARCHIVE " : ""}does not match the pinned SHA-256`);
    run("unzip", ["-q", archive, "-d", staging], root);
    // The archive nests its payload under a single directory, which is why the
    // upstream podspec sets `:flatten`. Resolve the framework at either level
    // rather than assuming the nesting directory's name.
    const roots = [staging, ...readdirSync(staging, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => join(staging, entry.name))];
    const extracted = roots.map((directory) => join(directory, "CrashReporter.xcframework")).find((candidate) => existsSync(candidate));
    assert.ok(extracted, "Pinned PLCrashReporter archive did not contain CrashReporter.xcframework");
    run("cp", ["-R", extracted, destination], root);
    writeFileSync(stamp, `${sha256}\n`);
    console.log(`Staged CrashReporter.xcframework for lint from ${provided ? "CRUMB_PLCRASH_ARCHIVE" : url}`);
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

// SPM is the recommended native iOS installation path, but verifySwiftPrivacyConsumers
// builds its consumer for macOS. Build one for an iOS Simulator destination too, so the
// recommended path has iOS coverage and the PLCrashReporter SPM dependency is resolved
// and compiled for iOS. Privacy manifests are not re-verified here: the podspec lints
// already inspect iOS privacy bundles inside a built application.
export function verifySwiftIOSConsumer(root, temporary, remoteRevision = null) {
  const consumer = join(temporary, "swift-ios");
  const sources = join(consumer, "Sources/CrumbIOSConsumer");
  mkdirSync(sources, { recursive: true });
  const dependency = remoteRevision
    ? `.package(url: "https://github.com/alexander126/crumb.git", revision: "${remoteRevision}")`
    : `.package(name: "crumb", path: ${JSON.stringify(root)})`;
  writeFileSync(join(consumer, "Package.swift"), `// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CrumbIOSConsumer",
    platforms: [.iOS(.v15)],
    products: [.library(name: "CrumbIOSConsumer", targets: ["CrumbIOSConsumer"])],
    dependencies: [${dependency}],
    targets: [
        .target(name: "CrumbIOSConsumer", dependencies: [
            .product(name: "CrumbCore", package: "crumb"),
            .product(name: "CrumbUI", package: "crumb")
        ])
    ]
)
`);
  const version = readFileSync(join(root, "VERSION"), "utf8").trim();
  writeFileSync(join(sources, "CrumbIOSConsumer.swift"), `import CrumbCore
import CrumbUI

public enum CrumbIOSConsumer {
    public static func start() throws {
        try Crumb.start(CrumbConfiguration(projectKey: "distribution_rehearsal", environment: "test", release: CrumbRelease(appVersion: "1.0", nativeBuild: "1")))
        precondition(CrumbSDKVersion.current == "${version}")
    }
}
`);
  const log = execFileSync("xcodebuild", [
    "-scheme", "CrumbIOSConsumer",
    "-destination", "generic/platform=iOS Simulator",
    "-derivedDataPath", join(consumer, "DerivedData"),
    "build",
  ], { cwd: consumer, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  assert.match(log, /\*\* BUILD SUCCEEDED \*\*/, "SwiftPM iOS consumer did not report a successful build");
  const target = log.match(/-target\s+\S*?-apple-ios(\d+\.\d+)-simulator/);
  assert.ok(target, "SwiftPM iOS consumer was not compiled for an iOS Simulator target");
  console.log(`Built CrumbCore+CrumbUI SwiftPM consumer for iOS Simulator at deployment target ${target[1]}`);
}

export function lintPodspecWithPrivacy(root, temporary, path, ancillaryGlob = null) {
  const validation = join(temporary, path.replace(".podspec", ""));
  const args = ["lib", "lint", path, "--platforms=ios", "--swift-version=6.0", "--use-static-frameworks", "--fail-fast", "--no-clean", `--validation-dir=${validation}`];
  stageCrashReporterForLint(root);
  args.push(`--include-podspecs=${ancillaryGlob ? `{${ancillaryGlob},${CRASH_REPORTER_PODSPEC}}` : CRASH_REPORTER_PODSPEC}`);
  run("pod", args, root);
  const settings = JSON.parse(execFileSync("xcodebuild", ["-workspace", join(validation, "App.xcworkspace"), "-scheme", "App", "-configuration", "Release", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-showBuildSettings", "-json"], { cwd: validation, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }));
  const app = settings.find((target) => target.target === "App")?.buildSettings;
  assert.equal(app?.FULL_PRODUCT_NAME, "App.app", "Inspect the built CocoaPods application, not loose resource byproducts");
  const product = join(app.TARGET_BUILD_DIR, app.FULL_PRODUCT_NAME);
  assert.ok(existsSync(product), `CocoaPods consumer application was not built: ${product}`);
  const modules = path === "CrumbSDKCore.podspec" ? ["CrumbCore"] : ["CrumbCore", "CrumbUI"];
  if (modules.length === 1) assert.ok(!existsSync(join(product, "CrumbUI.bundle")), "The Core-only consumer must not embed UI resources");
  console.log(`Verified CocoaPods application manifests: ${verifyOwnedPrivacyBundles(product, modules, "cocoapods").join(", ")}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const temporary = mkdtempSync(join(tmpdir(), "crumb-ios-privacy-"));
  console.log(`iOS privacy distribution products: ${temporary}`);
  try {
    if (!process.argv.includes("--pods-only")) {
      verifySwiftPrivacyConsumers(root, temporary);
      verifySwiftIOSConsumer(root, temporary);
    }
    if (!process.argv.includes("--swift-only")) {
      lintPodspecWithPrivacy(root, temporary, "CrumbSDKCore.podspec");
      lintPodspecWithPrivacy(root, temporary, "CrumbSDKUI.podspec", "CrumbSDKCore.podspec");
      lintPodspecWithPrivacy(root, temporary, "CrumbSDK.podspec", "CrumbSDK{Core,UI}.podspec");
    }
  } finally {
    if (!process.argv.includes("--keep-products")) rmSync(temporary, { recursive: true, force: true });
  }
}
