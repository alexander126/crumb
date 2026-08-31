#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const budgetBytes = 750 * 1024;
const suppliedMap = process.argv[2];
const linkMap = suppliedMap ? resolve(suppliedMap) : buildLinkMap();
const contributionBytes = measureContribution(linkMap);

console.log(`PASS iOS Crumb link contribution: ${contributionBytes} / ${budgetBytes} bytes`);
console.log(`Link map: ${linkMap}`);

if (contributionBytes > budgetBytes) process.exitCode = 1;

function buildLinkMap() {
  const derivedData = mkdtempSync(join(tmpdir(), "crumb-t10-ios-link-"));
  const result = spawnSync(
    "xcodebuild",
    [
      "-project",
      "examples/ios/CrumbDemo.xcodeproj",
      "-scheme",
      "CrumbDemo",
      "-configuration",
      "Release",
      "-sdk",
      "iphoneos",
      "-destination",
      "generic/platform=iOS",
      "-derivedDataPath",
      derivedData,
      "CODE_SIGNING_ALLOWED=NO",
      "ARCHS=arm64",
      "ONLY_ACTIVE_ARCH=YES",
      "LD_GENERATE_MAP_FILE=YES",
      "build",
    ],
    { cwd: repositoryRoot, stdio: "inherit" },
  );
  if (result.status !== 0) process.exit(result.status ?? 1);

  const matches = findFiles(derivedData, "CrumbDemo-LinkMap-normal-arm64.txt");
  if (matches.length !== 1) {
    throw new Error(`Expected one CrumbDemo linker map, found ${matches.length}.`);
  }
  return matches[0];
}

function findFiles(directory, name) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return findFiles(path, name);
    return entry.name === name ? [path] : [];
  });
}

function measureContribution(path) {
  const lines = readFileSync(path, "utf8").split(/\r?\n/);
  const crumbObjectIndexes = new Set();
  let inObjectFiles = false;
  let inLiveSymbols = false;
  let total = 0;

  for (const line of lines) {
    if (line === "# Object files:") {
      inObjectFiles = true;
      continue;
    }
    if (line === "# Sections:") {
      inObjectFiles = false;
      continue;
    }
    if (line === "# Symbols:") {
      inLiveSymbols = true;
      continue;
    }
    if (line === "# Dead Stripped Symbols:") {
      inLiveSymbols = false;
      continue;
    }

    if (inObjectFiles) {
      const object = /^\[\s*(\d+)\]\s+(.+)$/.exec(line);
      if (object && /\/(?:CrumbCore|CrumbUI)\.o$/.test(object[2])) {
        crumbObjectIndexes.add(Number(object[1]));
      }
      continue;
    }

    if (inLiveSymbols) {
      const symbol = /^0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]/.exec(line);
      if (symbol && crumbObjectIndexes.has(Number(symbol[2]))) {
        total += Number.parseInt(symbol[1], 16);
      }
    }
  }

  if (crumbObjectIndexes.size !== 2) {
    throw new Error("The linker map did not contain both CrumbCore.o and CrumbUI.o.");
  }
  return total;
}
