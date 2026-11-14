import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PODSPEC_LINT_LINKAGES, lintPodspecWithPrivacy, verifyOwnedPrivacyBundles, verifyReasonDeclarations } from "../ios-required-reasons.mjs";

const category = (type, reason) => ({ NSPrivacyAccessedAPIType: type, NSPrivacyAccessedAPITypeReasons: [reason] });
const boot = category("NSPrivacyAccessedAPICategorySystemBootTime", "35F9.1");
const defaults = category("NSPrivacyAccessedAPICategoryUserDefaults", "CA92.1");
const manifest = (...entries) => ({ NSPrivacyAccessedAPITypes: entries });

test("validates the exact module-specific required reasons without collection claims", () => {
  verifyReasonDeclarations(manifest(boot), "CrumbCore");
  verifyReasonDeclarations(manifest(defaults, boot), "CrumbUI");
  for (const invalid of [manifest(), manifest(boot), manifest(boot, boot, defaults), manifest(boot, category("NSPrivacyAccessedAPICategoryUserDefaults", "C56D.1")), { ...manifest(boot, defaults), NSPrivacyCollectedDataTypes: [] }]) {
    assert.throws(() => verifyReasonDeclarations(invalid, "CrumbUI"));
  }
  assert.throws(() => verifyReasonDeclarations(manifest(boot, defaults), "CrumbCore"));
});

test("a dependency manifest or loose byproduct cannot substitute for embedded owned bundles", () => {
  const temporary = mkdtempSync(join(tmpdir(), "crumb-privacy-inspection-"));
  try {
    const app = join(temporary, "Consumer.app");
    const dependency = join(app, "PLCrashReporter.bundle");
    const unembedded = join(temporary, "CrumbCore.bundle");
    for (const bundle of [dependency, unembedded]) {
      mkdirSync(bundle, { recursive: true });
      writeFileSync(join(bundle, "PrivacyInfo.xcprivacy"), "synthetic unrelated manifest");
    }
    assert.throws(() => verifyOwnedPrivacyBundles(app, ["CrumbCore"], "cocoapods"), /Missing embedded CrumbCore/);
    mkdirSync(join(app, "CrumbCore.bundle"));
    assert.throws(() => verifyOwnedPrivacyBundles(app, ["CrumbCore"], "cocoapods"), /own bundle must contain exactly one/);
    rmSync(join(app, "CrumbCore.bundle"), { recursive: true });
    symlinkSync(unembedded, join(app, "CrumbCore.bundle"), "dir");
    assert.throws(() => verifyOwnedPrivacyBundles(app, ["CrumbCore"], "cocoapods"), /resource bundle must remain inside/);
    rmSync(join(app, "CrumbCore.bundle"));
    mkdirSync(join(app, "CrumbCore.bundle"));
    symlinkSync(join(unembedded, "PrivacyInfo.xcprivacy"), join(app, "CrumbCore.bundle/PrivacyInfo.xcprivacy"));
    assert.throws(() => verifyOwnedPrivacyBundles(app, ["CrumbCore"], "cocoapods"), /privacy manifest must remain inside/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("the source pods are static frameworks and the lint cannot skip the linkage trunk validates", () => {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  // CrumbSDKCore depends on PLCrashReporter's statically linked binary. Without
  // static_framework, a dynamic-framework build fails, which is how pod trunk
  // push and a `use_frameworks!` application build the pods.
  for (const podspec of ["CrumbSDKCore.podspec", "CrumbSDKUI.podspec"]) {
    assert.match(readFileSync(join(root, podspec), "utf8"), /^\s*spec\.static_framework = true$/m, `${podspec} must declare static_framework`);
  }
  assert.deepEqual(PODSPEC_LINT_LINKAGES.dynamic, [], "The dynamic lint must use CocoaPods' default linkage, as pod trunk push does");
  assert.throws(() => lintPodspecWithPrivacy(root, tmpdir(), "CrumbSDKCore.podspec", null, ["static"]), /dynamic-framework linkage/);
});
