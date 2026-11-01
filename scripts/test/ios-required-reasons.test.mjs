import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { verifyOwnedPrivacyBundles, verifyReasonDeclarations } from "../ios-required-reasons.mjs";

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
