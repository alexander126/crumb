import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const revisionFlag = process.argv.indexOf("--remote-revision");
const remoteRevision = revisionFlag === -1 ? null : process.argv[revisionFlag + 1];

if (revisionFlag !== -1 && !/^[0-9a-f]{40}$/.test(remoteRevision ?? "")) {
  throw new Error("--remote-revision requires a full 40-character Git commit SHA");
}

const rehearsalRoot = mkdtempSync(join(tmpdir(), "crumb-distribution-"));
const mavenRepository = join(rehearsalRoot, "maven");
const androidCache = join(rehearsalRoot, "android-project-cache");
const androidBuild = join(rehearsalRoot, "android-consumer-build");

function run(command, args, cwd = root) {
  execFileSync(command, args, { cwd, stdio: "inherit" });
}

function requireText(path, expected, label) {
  const contents = readFileSync(path, "utf8");
  if (!contents.includes(expected)) {
    throw new Error(`${label} is missing ${JSON.stringify(expected)}`);
  }
  return contents;
}

function verifyPackageMetadata() {
  const metadataFiles = [
    "CrumbSDK.podspec",
    "CrumbSDKCore.podspec",
    "CrumbSDKUI.podspec",
    "packages/android/crumb-core/build.gradle",
    "packages/android/crumb-ui/build.gradle",
  ];
  const placeholders = ["example.invalid", "SDK Team", "sdk@example.invalid"];
  const license = readFileSync(join(root, "LICENSE"), "utf8");
  if (!license.includes("Apache License") || !license.includes("Version 2.0, January 2004")) {
    throw new Error("LICENSE must contain the Apache License 2.0 terms");
  }

  for (const metadataFile of metadataFiles) {
    const contents = readFileSync(join(root, metadataFile), "utf8");
    for (const placeholder of placeholders) {
      if (contents.includes(placeholder)) {
        throw new Error(`${metadataFile} still contains placeholder metadata: ${placeholder}`);
      }
    }
    if (contents.includes("Proprietary") || !contents.includes("Apache")) {
      throw new Error(`${metadataFile} must declare Apache-2.0 metadata`);
    }
  }
}

function verifyAndroidArtifacts() {
  const versionPath = join("com", "crumbsdk");
  const coreBase = join(mavenRepository, versionPath, "crumb-core", version);
  const uiBase = join(mavenRepository, versionPath, "crumb-ui", version);
  const coreAar = join(coreBase, `crumb-core-${version}.aar`);
  const uiAar = join(uiBase, `crumb-ui-${version}.aar`);

  const corePom = requireText(
    join(coreBase, `crumb-core-${version}.pom`),
    "<groupId>com.crumbsdk</groupId>",
    "Core POM",
  );
  const uiPom = requireText(join(uiBase, `crumb-ui-${version}.pom`), "<artifactId>crumb-core</artifactId>", "UI POM");
  for (const [pom, label] of [[corePom, "Core POM"], [uiPom, "UI POM"]]) {
    if (
      !pom.includes("The Apache License, Version 2.0") ||
      !pom.includes("https://www.apache.org/licenses/LICENSE-2.0.txt")
    ) {
      throw new Error(`${label} must publish Apache-2.0 license metadata`);
    }
  }
  if (!uiPom.includes("<scope>compile</scope>")) {
    throw new Error("UI POM must expose Crumb Core as a compile dependency");
  }

  for (const [artifact, label] of [
    [join(coreBase, `crumb-core-${version}-sources.jar`), "Core sources JAR"],
    [join(coreBase, `crumb-core-${version}-javadoc.jar`), "Core Javadoc JAR"],
    [join(uiBase, `crumb-ui-${version}-sources.jar`), "UI sources JAR"],
    [join(uiBase, `crumb-ui-${version}-javadoc.jar`), "UI Javadoc JAR"],
  ]) {
    readFileSync(artifact);
    console.log(`Verified ${label}.`);
  }

  for (const [aar, label] of [[coreAar, "Core AAR"], [uiAar, "UI AAR"]]) {
    const rules = execFileSync("unzip", ["-p", aar, "proguard.txt"], { encoding: "utf8" });
    if (!rules.includes("LineNumberTable")) {
      throw new Error(`${label} does not contain the expected consumer rules`);
    }
    console.log(`Verified ${label} consumer rules.`);
  }
}

function verifySwiftConsumer() {
  const consumer = join(rehearsalRoot, "swift-consumer");
  const sources = join(consumer, "Sources", "CrumbDistributionConsumer");
  mkdirSync(sources, { recursive: true });

  const dependency = remoteRevision
    ? `.package(url: "https://github.com/alexander126/crumb.git", revision: "${remoteRevision}")`
    : `.package(name: "crumb", path: ${JSON.stringify(root)})`;

  writeFileSync(
    join(consumer, "Package.swift"),
    `// swift-tools-version: 6.0\n\nimport PackageDescription\n\nlet package = Package(\n    name: "CrumbDistributionConsumer",\n    platforms: [.macOS(.v13)],\n    dependencies: [${dependency}],\n    targets: [\n        .executableTarget(\n            name: "CrumbDistributionConsumer",\n            dependencies: [\n                .product(name: "CrumbCore", package: "crumb"),\n                .product(name: "CrumbUI", package: "crumb")\n            ]\n        )\n    ]\n)\n`,
  );

  writeFileSync(
    join(sources, "main.swift"),
    `import CrumbCore\nimport CrumbUI\n\ntry Crumb.start(\n    CrumbConfiguration(\n        projectKey: "distribution_rehearsal",\n        environment: "test",\n        release: CrumbRelease(appVersion: "1.0", nativeBuild: "1")\n    )\n)\nprecondition(CrumbSDKVersion.current == "${version}")\nprint(CrumbSDKVersion.current)\n`,
  );

  run("swift", ["build", "--package-path", consumer]);
}

function lintPodspec(path, ancillaryGlob = null) {
  const args = [
    "lib",
    "lint",
    path,
    "--platforms=ios",
    "--swift-version=6.0",
    "--use-static-frameworks",
    "--fail-fast",
  ];
  if (ancillaryGlob) args.push(`--include-podspecs=${ancillaryGlob}`);
  run("pod", args);
}

try {
  run(process.execPath, [join(root, "scripts/sync-sdk-version.mjs"), "--check"]);
  verifyPackageMetadata();

  run(join(root, "packages/android/gradlew"), [
    "-p",
    join(root, "packages/android"),
    "--rerun-tasks",
    `-PcrumbRepository=${mavenRepository}`,
    ":crumb-core:publishReleasePublicationToStagingRepository",
    ":crumb-ui:publishReleasePublicationToStagingRepository",
  ]);
  verifyAndroidArtifacts();

  run(join(root, "packages/android/gradlew"), [
    "-p",
    join(root, "distribution/consumers/android"),
    "--rerun-tasks",
    "--project-cache-dir",
    androidCache,
    `-PcrumbRepository=${mavenRepository}`,
    `-PcrumbVersion=${version}`,
    `-PcrumbConsumerBuildDir=${androidBuild}`,
    ":app:assembleDebug",
  ]);

  lintPodspec("CrumbSDKCore.podspec");
  lintPodspec("CrumbSDKUI.podspec", "CrumbSDKCore.podspec");
  lintPodspec("CrumbSDK.podspec", "CrumbSDK{Core,UI}.podspec");

  verifySwiftConsumer();
  console.log(`Native distribution rehearsal passed for Crumb ${version}${remoteRevision ? ` at ${remoteRevision}` : " using the local package"}.`);
} finally {
  rmSync(rehearsalRoot, { recursive: true, force: true });
}
