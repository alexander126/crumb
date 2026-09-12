import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const workflow = readFileSync(join(root, ".github/workflows/react-native-npm-publish.yml"), "utf8");
const start = workflow.indexOf('          version="$(node -p');
const end = workflow.indexOf("      - run: yarn quality", start);
assert.ok(start >= 0 && end > start, "Publication validation step must exist");
const validation = workflow.slice(start, end).replace(/^ {10}/gm, "");

test("publication accepts matching immutable tags and rejects split commits or native pins", () => {
  const temporary = mkdtempSync(join(tmpdir(), "crumb-publication-test-"));
  const cwd = join(temporary, "packages/react-native");
  const version = "9.8.7-rc.6";
  const git = (...args) => execFileSync("git", args, { cwd: temporary, stdio: "pipe" });
  try {
    mkdirSync(cwd, { recursive: true });
    const metadata = { version, crumbNativeVersion: version };
    writeFileSync(join(cwd, "package.json"), JSON.stringify(metadata));
    writeFileSync(join(temporary, "VERSION"), `${version}\n`);
    git("init", "--quiet");
    git("add", ".");
    git("-c", "user.name=Release test", "-c", "user.email=release@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Synthetic release fixture");
    git("tag", version);
    git("tag", `react-native-v${version}`);
    const check = () => spawnSync("bash", ["-e", "-c", validation], {
      cwd, encoding: "utf8",
      env: { ...process.env, RELEASE_TAG: `react-native-v${version}`, DIST_TAG: "next", CONFIRMATION: `publish @crumbsdk/react-native@${version}` },
    });
    assert.equal(check().status, 0);
    metadata.crumbNativeVersion = "9.8.6";
    writeFileSync(join(cwd, "package.json"), JSON.stringify(metadata));
    assert.match(check().stderr, /versions must match/);
    metadata.crumbNativeVersion = version;
    writeFileSync(join(cwd, "package.json"), JSON.stringify(metadata));
    git("-c", "user.name=Release test", "-c", "user.email=release@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Different synthetic commit");
    git("tag", "-f", `react-native-v${version}`);
    const mismatched = check();
    assert.notEqual(mismatched.status, 0);
    assert.match(mismatched.stderr, /same commit/);
    git("tag", "-d", version);
    assert.notEqual(check().status, 0, "Missing native tag must fail");
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
