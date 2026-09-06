import assert from "node:assert/strict";
import { test } from "node:test";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// All commits/tags below exist only in a disposable synthetic fixture repository.
// The guard is tested; no publication, repository release tag or registry is used.
test("publication requires matching immutable tag, version, channel and explicit confirmation", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "crumb-publish-fixture-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const cwd = join(dir, "packages/source-maps");
  await mkdir(cwd, { recursive: true });
  await writeFile(join(dir, "VERSION"), "0.0.1-rc.3\n");
  await writeFile(
    join(cwd, "package.json"),
    JSON.stringify({ name: "@crumbsdk/source-maps", version: "0.0.1-rc.3" }),
  );
  const git = (...args) =>
    execFileSync(
      "git",
      [
        "-c",
        "user.name=Synthetic Test",
        "-c",
        "user.email=fixture@example.invalid",
        ...args,
      ],
      { cwd: dir, stdio: "pipe" },
    );
  git("init");
  git("add", ".");
  git("-c", "commit.gpgsign=false", "commit", "-m", "Synthetic fixture");
  git("tag", "0.0.1-rc.3");
  const script = resolve("scripts/check-publication.mjs");
  const run = (env) =>
    spawnSync(process.execPath, [script], {
      cwd,
      encoding: "utf8",
      env: {
        ...process.env,
        RELEASE_TAG: "0.0.1-rc.3",
        DIST_TAG: "next",
        CONFIRMATION: "publish @crumbsdk/source-maps@0.0.1-rc.3",
        ...env,
      },
    });
  assert.equal(run({}).status, 0);
  for (const env of [
    { RELEASE_TAG: "main" },
    { DIST_TAG: "latest" },
    { CONFIRMATION: "" },
  ])
    assert.notEqual(run(env).status, 0);
  await writeFile(join(dir, "new-file"), "synthetic new commit");
  git("add", ".");
  git(
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "Synthetic untagged change",
  );
  assert.notEqual(run({}).status, 0, "older tag cannot publish current HEAD");
  await writeFile(
    join(cwd, "package.json"),
    JSON.stringify({ name: "@crumbsdk/source-maps", version: "0.0.1-rc.4" }),
  );
  assert.notEqual(run({}).status, 0);
});
