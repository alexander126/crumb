import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { CRASH_REPORTER_PODSPEC, lintPodspecWithPrivacy, verifySwiftIOSConsumer, verifySwiftPrivacyConsumers } from "./ios-required-reasons.mjs";
import { verifyKotlinClassMetadata, verifyPublishedKotlinDependencies, verifyResolvedKotlinConsumer, verifyUploadTransportCompatibility } from "./android-kotlin-compatibility.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const revisionFlag = process.argv.indexOf("--remote-revision");
const remoteRevision = revisionFlag === -1 ? null : process.argv[revisionFlag + 1];

if (revisionFlag !== -1 && !/^[0-9a-f]{40}$/.test(remoteRevision ?? "")) {
  throw new Error("--remote-revision requires a full 40-character Git commit SHA");
}

const rehearsalRoot = mkdtempSync(join(tmpdir(), "crumb-distribution-"));
const mavenRepository = join(rehearsalRoot, "maven");

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
    "packages/android/crumb-react-native/build.gradle",
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
  const reactNativeBase = join(mavenRepository, versionPath, "crumb-react-native", version);
  const coreAar = join(coreBase, `crumb-core-${version}.aar`);
  const uiAar = join(uiBase, `crumb-ui-${version}.aar`);
  const reactNativeAar = join(reactNativeBase, `crumb-react-native-${version}.aar`);

  const corePom = requireText(
    join(coreBase, `crumb-core-${version}.pom`),
    "<groupId>com.crumbsdk</groupId>",
    "Core POM",
  );
  const uiPom = requireText(join(uiBase, `crumb-ui-${version}.pom`), "<artifactId>crumb-core</artifactId>", "UI POM");
  const reactNativePom = requireText(
    join(reactNativeBase, `crumb-react-native-${version}.pom`),
    "<artifactId>crumb-core</artifactId>",
    "React Native POM",
  );
  for (const [pom, label] of [
    [corePom, "Core POM"],
    [uiPom, "UI POM"],
    [reactNativePom, "React Native POM"],
  ]) {
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
  if (!reactNativePom.includes("<scope>compile</scope>")) {
    throw new Error("React Native POM must expose Crumb Core as a compile dependency");
  }

  for (const [artifact, label] of [
    [join(coreBase, `crumb-core-${version}-sources.jar`), "Core sources JAR"],
    [join(coreBase, `crumb-core-${version}-javadoc.jar`), "Core Javadoc JAR"],
    [join(uiBase, `crumb-ui-${version}-sources.jar`), "UI sources JAR"],
    [join(uiBase, `crumb-ui-${version}-javadoc.jar`), "UI Javadoc JAR"],
    [
      join(reactNativeBase, `crumb-react-native-${version}-sources.jar`),
      "React Native sources JAR",
    ],
    [
      join(reactNativeBase, `crumb-react-native-${version}-javadoc.jar`),
      "React Native Javadoc JAR",
    ],
  ]) {
    readFileSync(artifact);
    console.log(`Verified ${label}.`);
  }

  for (const [aar, label, base, artifact] of [
    [coreAar, "Core AAR", coreBase, "crumb-core"],
    [uiAar, "UI AAR", uiBase, "crumb-ui"],
    [reactNativeAar, "React Native AAR", reactNativeBase, "crumb-react-native"],
  ]) {
    const rules = execFileSync("unzip", ["-p", aar, "proguard.txt"], { encoding: "utf8" });
    if (!rules.includes("LineNumberTable")) {
      throw new Error(`${label} does not contain the expected consumer rules`);
    }
    console.log(`Verified ${label} consumer rules.`);
    verifyPublishedKotlinDependencies(
      readFileSync(join(base, `${artifact}-${version}.pom`), "utf8"),
      JSON.parse(readFileSync(join(base, `${artifact}-${version}.module`), "utf8")),
    );
    const classesJar = join(rehearsalRoot, `${artifact}-classes.jar`);
    writeFileSync(classesJar, execFileSync("unzip", ["-p", aar, "classes.jar"]));
    const classes = execFileSync("unzip", ["-Z1", classesJar], { encoding: "utf8" })
      .split("\n")
      .filter((name) => name.endsWith(".class"))
      .map((name) => name.slice(0, -6).replaceAll("/", "."));
    const javap = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, "bin/javap") : "javap";
    const metadata = execFileSync(javap, ["-v", "-classpath", classesJar, ...classes], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    if (artifact === "crumb-core") {
      verifyUploadTransportCompatibility(execFileSync(javap, ["-public", "-classpath", classesJar, "dev.crumb.core.CrumbUploadTransport", "dev.crumb.core.CrumbUploadTransport$DefaultImpls"], { encoding: "utf8" }));
    }
    console.log(`Verified ${label}: ${verifyKotlinClassMetadata(metadata)} Kotlin metadata annotations target 2.0; POM/module expose stdlib 2.0.21.`);
  }
}

function verifyAndroidConsumers() {
  for (const compilerVersion of ["2.0.21", "2.2.0"]) {
    const consumer = join(rehearsalRoot, `android-${compilerVersion}`);
    mkdirSync(consumer, { recursive: true });
    const evidence = join(consumer, "resolution.json");
    const args = [
      "-p",
      join(root, "distribution/consumers/android"),
      "--rerun-tasks",
      "--no-daemon",
      "--project-cache-dir",
      join(consumer, "project-cache"),
      `-Pkotlin.project.persistent.dir=${join(consumer, "kotlin")}`,
      `-PcrumbRepository=${mavenRepository}`,
      `-PcrumbVersion=${version}`,
      `-PcrumbConsumerBuildDir=${join(consumer, "build")}`,
      `-PcrumbConsumerEvidence=${evidence}`,
    ];
    // The modern invocation also verifies the unchanged default compiler version.
    if (compilerVersion === "2.0.21") args.push(`-PcrumbConsumerKotlinVersion=${compilerVersion}`);
    args.push(":app:writeCrumbResolutionEvidence", ":app:assembleDebug");
    run(join(root, "packages/android/gradlew"), args);
    const resolution = verifyResolvedKotlinConsumer(JSON.parse(readFileSync(evidence, "utf8")), mavenRepository, version, compilerVersion);
    console.log(`Verified Maven artifact consumer: ${JSON.stringify(resolution)}`);
  }
}

function verifySwiftConsumer() {
  verifySwiftPrivacyConsumers(root, rehearsalRoot, remoteRevision);
  verifySwiftIOSConsumer(root, rehearsalRoot, remoteRevision);
}

// The crash reporter binary is pinned in three places: Crumb's CocoaPods wrapper,
// the React Native wrapper that reads the npm-bundled copy, and the packaging
// script that downloads and checksums it. A drift between them would ship one
// consumer a different binary than the one its checksum promises.
function verifyCrashReporterPin() {
  const sources = {
    [CRASH_REPORTER_PODSPEC]: readFileSync(join(root, CRASH_REPORTER_PODSPEC), "utf8"),
    "packages/react-native/scripts/PLCrashReporter.podspec": readFileSync(
      join(root, "packages/react-native/scripts/PLCrashReporter.podspec"),
      "utf8",
    ),
    "packages/react-native/scripts/prepare-ios.mjs": readFileSync(
      join(root, "packages/react-native/scripts/prepare-ios.mjs"),
      "utf8",
    ),
  };
  const pins = Object.entries(sources).map(([label, text]) => {
    const url = text.match(/https:\/\/github\.com\/microsoft\/plcrashreporter\/releases\/download\/[^'"\s]+\.zip/);
    const sha256 = text.match(/sha256['"]?\s*[:=]>?\s*['"]([0-9a-f]{64})['"]/);
    assert.ok(url, `${label} does not pin a PLCrashReporter release archive URL`);
    assert.ok(sha256, `${label} does not pin a PLCrashReporter SHA-256`);
    return { label, url: url[0], sha256: sha256[1] };
  });
  for (const pin of pins.slice(1)) {
    assert.equal(pin.url, pins[0].url, `${pin.label} pins a different PLCrashReporter archive than ${pins[0].label}`);
    assert.equal(pin.sha256, pins[0].sha256, `${pin.label} pins a different PLCrashReporter SHA-256 than ${pins[0].label}`);
  }
  console.log(`Verified PLCrashReporter pin across ${pins.length} sources: ${pins[0].sha256}`);
}

function lintPodspec(path, ancillaryGlob = null, linkages = ["dynamic"]) {
  lintPodspecWithPrivacy(root, rehearsalRoot, path, ancillaryGlob, linkages);
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
    ":crumb-react-native:publishReleasePublicationToStagingRepository",
  ]);
  verifyAndroidArtifacts();

  verifyAndroidConsumers();

  verifyCrashReporterPin();
  lintPodspec("CrumbSDKCore.podspec");
  lintPodspec("CrumbSDKUI.podspec", "CrumbSDKCore.podspec");
  lintPodspec("CrumbSDK.podspec", "CrumbSDK{Core,UI}.podspec", ["dynamic", "static"]);

  verifySwiftConsumer();
  console.log(`Native distribution rehearsal passed for Crumb ${version}${remoteRevision ? ` at ${remoteRevision}` : " using the local package"}.`);
} finally {
  rmSync(rehearsalRoot, { recursive: true, force: true });
}
