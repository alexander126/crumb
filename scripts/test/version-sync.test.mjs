import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const source = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
test("one version synchronizes all distributions and check rejects drift without rewriting", () => {
  const root = mkdtempSync(join(tmpdir(), "crumb-version-test-"));
  const copy = (file) => {
    mkdirSync(dirname(join(root, file)), { recursive: true });
    cpSync(join(source, file), join(root, file));
  };
  try {
    for (const file of [
      "scripts/sync-sdk-version.mjs", "packages/react-native/package.json",
      "packages/source-maps/package.json", "packages/source-maps/package-lock.json",
      "packages/ios/Sources/CrumbCore/CrumbSDKVersion.swift",
      "packages/android/crumb-core/src/main/kotlin/dev/crumb/core/CrumbSDKVersion.kt",
    ]) copy(file);
    writeFileSync(join(root, "VERSION"), "9.8.7-rc.6\n");
    const script = join(root, "scripts/sync-sdk-version.mjs");
    execFileSync(process.execPath, [script]);
    const read = (file) => JSON.parse(readFileSync(join(root, file), "utf8"));
    assert.equal(read("packages/react-native/package.json").version, "9.8.7-rc.6");
    assert.equal(read("packages/react-native/package.json").crumbNativeVersion, "9.8.7-rc.6");
    assert.equal(read("packages/source-maps/package.json").version, "9.8.7-rc.6");
    assert.equal(read("packages/source-maps/package-lock.json").packages[""].version, "9.8.7-rc.6");
    execFileSync(process.execPath, [script, "--check"]);
    for (const [file, mutate] of [
      ["packages/react-native/package.json", (j) => { j.version = "9.8.6"; }],
      ["packages/react-native/package.json", (j) => { j.crumbNativeVersion = "9.8.6"; }],
      ["packages/source-maps/package.json", (j) => { j.version = "9.8.6"; }],
      ["packages/source-maps/package-lock.json", (j) => { j.packages[""].version = "9.8.6"; }],
    ]) {
      const path = join(root, file);
      const metadata = read(file);
      mutate(metadata);
      const changed = `${JSON.stringify(metadata, null, 2)}\n`;
      writeFileSync(path, changed);
      const check = spawnSync(process.execPath, [script, "--check"], { encoding: "utf8" });
      assert.notEqual(check.status, 0, `Drift must fail: ${file}`);
      assert.match(check.stderr, /stale/);
      assert.equal(readFileSync(path, "utf8"), changed, "Check must be read-only");
      execFileSync(process.execPath, [script]);
    }
    writeFileSync(join(root, "VERSION"), "not-a-version\n");
    assert.notEqual(spawnSync(process.execPath, [script]).status, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
