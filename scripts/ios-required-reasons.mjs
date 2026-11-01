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

export function lintPodspecWithPrivacy(root, temporary, path, ancillaryGlob = null) {
  const validation = join(temporary, path.replace(".podspec", ""));
  const args = ["lib", "lint", path, "--platforms=ios", "--swift-version=6.0", "--use-static-frameworks", "--fail-fast", "--no-clean", `--validation-dir=${validation}`];
  if (ancillaryGlob) args.push(`--include-podspecs=${ancillaryGlob}`);
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
    if (!process.argv.includes("--pods-only")) verifySwiftPrivacyConsumers(root, temporary);
    if (!process.argv.includes("--swift-only")) {
      lintPodspecWithPrivacy(root, temporary, "CrumbSDKCore.podspec");
      lintPodspecWithPrivacy(root, temporary, "CrumbSDKUI.podspec", "CrumbSDKCore.podspec");
      lintPodspecWithPrivacy(root, temporary, "CrumbSDK.podspec", "CrumbSDK{Core,UI}.podspec");
    }
  } finally {
    if (!process.argv.includes("--keep-products")) rmSync(temporary, { recursive: true, force: true });
  }
}
