import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const temporary = mkdtempSync(join(tmpdir(), "crumb-source-maps-pack-"));
try {
  const metadata = JSON.parse(readFileSync("package.json", "utf8"));
  assert.equal(
    metadata.version,
    readFileSync("../../VERSION", "utf8").trim(),
    "CLI version must follow VERSION",
  );
  assert.equal(metadata.name, "@crumbsdk/source-maps");
  assert.equal(metadata.dependencies, undefined, "CLI must remain standalone");
  const packed = JSON.parse(
    execFileSync(
      "npm",
      [
        "pack",
        "--cache",
        join(temporary, "cache"),
        "--json",
        "--pack-destination",
        temporary,
      ],
      { encoding: "utf8" },
    ),
  );
  const archive = join(temporary, packed[0].filename);
  const expected = [
    "LICENSE",
    "README.md",
    "dist/cli.js",
    "dist/upload.js",
    "dist/validation.js",
    "package.json",
  ];
  assert.deepEqual(
    packed[0].files.map((file) => file.path).sort(),
    expected.sort(),
  );
  assert.ok(
    packed[0].files.find((file) => file.path === "dist/cli.js").mode & 0o111,
    "bin must be executable",
  );
  execFileSync(
    "npm",
    [
      "install",
      "--cache",
      join(temporary, "cache"),
      "--prefix",
      temporary,
      "--ignore-scripts",
      "--offline",
      "--no-audit",
      "--no-fund",
      archive,
    ],
    { stdio: "pipe" },
  );
  const bin = join(temporary, "node_modules/.bin/crumb-source-maps");
  assert.match(
    execFileSync(bin, ["--help"], { encoding: "utf8" }),
    /CRUMB_SOURCE_MAP_TOKEN/,
  );
  const bundle = join(temporary, "synthetic.bundle");
  const map = join(temporary, "synthetic.map");
  writeFileSync(bundle, 'throw Error("synthetic")');
  writeFileSync(
    map,
    JSON.stringify({
      version: 3,
      sources: ["App.ts"],
      names: [],
      mappings: "AAAA",
    }),
  );
  const result = JSON.parse(
    execFileSync(
      bin,
      [
        "upload",
        "--platform",
        "ios",
        "--app-version",
        "1.0",
        "--native-build",
        "1",
        "--bundle-version",
        "build-1",
        "--bundle",
        bundle,
        "--source-map",
        map,
        "--dry-run",
      ],
      { encoding: "utf8" },
    ),
  );
  assert.equal(result.status, "dry_run");
  console.log(
    "Tarball allowlist, version, executable bin, offline installation and installed CLI dry-run passed.",
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
