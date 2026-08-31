#!/usr/bin/env node

import { spawn } from "node:child_process";
import {
  access,
  cp,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const browserStackRoot = join(repositoryRoot, ".browserstack");
const artifactRoot = join(browserStackRoot, "artifacts");
const resultRoot = join(browserStackRoot, "results");
const apiRoot = "https://api-cloud.browserstack.com";

const artifacts = {
  iosApp: join(artifactRoot, "CrumbDemo.ipa"),
  iosTests: join(artifactRoot, "CrumbDemoUITests.zip"),
  androidApp: join(artifactRoot, "crumb-demo-release.apk"),
  androidTests: join(artifactRoot, "crumb-demo-release-androidTest.apk"),
};

async function main() {
  await loadLocalEnvironment();
  const command = process.argv[2] ?? "help";

  try {
    switch (command) {
    case "prepare":
      await prepareIos();
      await prepareAndroid();
      break;
    case "prepare-ios":
      await prepareIos();
      break;
    case "prepare-android":
      await prepareAndroid();
      break;
    case "devices":
      printMatrix(await resolveDeviceMatrix());
      break;
    case "run":
      await runPlatforms(["ios", "android"]);
      break;
    case "run-ios":
      await runPlatforms(["ios"]);
      break;
    case "run-ios-current":
      await runPlatforms(["ios"], { includeIosLegacy: false });
      break;
    case "run-ios-legacy":
      await runLegacyIosOnly();
      break;
    case "run-android":
      await runPlatforms(["android"]);
      break;
    case "help":
    case "--help":
    case "-h":
      printHelp();
      break;
      default:
        throw new Error(`Unknown BrowserStack command: ${command}`);
    }
  } catch (error) {
    console.error(`BrowserStack task failed: ${error.message}`);
    process.exitCode = 1;
  }
}

async function loadLocalEnvironment() {
  const envPath = join(repositoryRoot, ".env");
  let contents;
  try {
    contents = await readFile(envPath, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (!match || process.env[match[1]] !== undefined) continue;

    let value = match[2].trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    process.env[match[1]] = value;
  }
}

async function prepareIos() {
  const team = requiredEnvironment("APPLE_DEVELOPMENT_TEAM");
  const derivedData = join(browserStackRoot, "ios-derived");
  const products = join(derivedData, "Build", "Products", "Release-iphoneos");
  const app = join(products, "CrumbDemo.app");
  const runner = join(products, "CrumbDemoUITests-Runner.app");

  await mkdir(artifactRoot, { recursive: true });
  await rm(derivedData, { recursive: true, force: true });
  console.log("Building the iOS app and XCUI runner for a generic physical device…");
  await runProcess(
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
      `DEVELOPMENT_TEAM=${team}`,
      "CODE_SIGN_STYLE=Automatic",
      "-allowProvisioningUpdates",
      "build-for-testing",
    ],
    repositoryRoot,
  );

  await requireFile(app, "The iOS app product was not generated.");
  await requireFile(runner, "The XCUI runner product was not generated.");

  const packageRoot = join(browserStackRoot, "ios-package");
  const payload = join(packageRoot, "Payload");
  await rm(packageRoot, { recursive: true, force: true });
  await mkdir(payload, { recursive: true });
  await cp(app, join(payload, basename(app)), { recursive: true });
  await rm(artifacts.iosApp, { force: true });
  await rm(artifacts.iosTests, { force: true });

  await runProcess(
    "/usr/bin/ditto",
    ["-c", "-k", "--sequesterRsrc", "--keepParent", payload, artifacts.iosApp],
    repositoryRoot,
  );
  await runProcess(
    "/usr/bin/ditto",
    ["-c", "-k", "--sequesterRsrc", "--keepParent", runner, artifacts.iosTests],
    repositoryRoot,
  );
  await rm(packageRoot, { recursive: true, force: true });

  console.log(`Prepared ${relativeArtifact(artifacts.iosApp)}`);
  console.log(`Prepared ${relativeArtifact(artifacts.iosTests)}`);
}

async function prepareAndroid() {
  console.log("Building the release Android demo and Espresso runner…");
  await runProcess(
    "./gradlew",
    [
      "-PcrumbQualityRelease",
      ":demo:assembleRelease",
      ":demo:assembleReleaseAndroidTest",
    ],
    join(repositoryRoot, "packages", "android"),
  );

  const app = join(
    repositoryRoot,
    "packages/android/demo/build/outputs/apk/release/demo-release.apk",
  );
  const tests = join(
    repositoryRoot,
    "packages/android/demo/build/outputs/apk/androidTest/release/demo-release-androidTest.apk",
  );
  await requireFile(app, "The Android demo APK was not generated.");
  await requireFile(tests, "The Espresso test APK was not generated.");

  await mkdir(artifactRoot, { recursive: true });
  await cp(app, artifacts.androidApp);
  await cp(tests, artifacts.androidTests);
  console.log(`Prepared ${relativeArtifact(artifacts.androidApp)}`);
  console.log(`Prepared ${relativeArtifact(artifacts.androidTests)}`);
}

async function runPlatforms(platforms, { includeIosLegacy = true } = {}) {
  requireBrowserStackCredentials();
  await mkdir(resultRoot, { recursive: true });
  const matrix = await resolveDeviceMatrix();
  printMatrix(matrix, platforms);

  const launches = [];
  for (const platform of platforms) {
    launches.push(await launchPlatform(platform, matrix));
  }

  const results = await Promise.all(
    launches.map(async ({ platform, buildId }) => {
      const result = await waitForBuild(platform, buildId);
      const destination = join(resultRoot, `${platform}-${buildId}.json`);
      await writeFile(destination, `${JSON.stringify(result, null, 2)}\n`);
      console.log(`Saved ${relativeArtifact(destination)}`);
      return { platform, buildId, result };
    }),
  );

  if (platforms.includes("ios") && includeIosLegacy) {
    const legacyResult = await runIosLegacyAppium(matrix.ios15);
    const destination = join(
      resultRoot,
      `ios-legacy-appium-${legacyResult.sessionId ?? "not-started"}.json`,
    );
    await writeFile(destination, `${JSON.stringify(legacyResult, null, 2)}\n`);
    console.log(`Saved ${relativeArtifact(destination)}`);
    results.push({
      platform: "ios legacy",
      buildId: legacyResult.sessionId ?? "not-started",
      result: legacyResult,
    });
  }

  const failures = results.filter(({ result }) => !isSuccessfulStatus(result.status));
  for (const { platform, buildId, result } of results) {
    console.log(`${platform}: ${result.status ?? "unknown"} (${buildId})`);
  }
  if (failures.length > 0) {
    throw new Error(
      `${failures.map(({ platform }) => platform).join(" and ")} BrowserStack build failed.`,
    );
  }
}

async function runLegacyIosOnly() {
  requireBrowserStackCredentials();
  await mkdir(resultRoot, { recursive: true });
  const matrix = await resolveDeviceMatrix();
  printMatrix(matrix, ["ios"]);
  const result = await runIosLegacyAppium(matrix.ios15);
  const destination = join(
    resultRoot,
    `ios-legacy-appium-${result.sessionId ?? "not-started"}.json`,
  );
  await writeFile(destination, `${JSON.stringify(result, null, 2)}\n`);
  console.log(`Saved ${relativeArtifact(destination)}`);
  if (!isSuccessfulStatus(result.status)) {
    throw new Error("iOS 15 BrowserStack Appium flow failed.");
  }
}

async function runIosLegacyAppium(qualifiedDeviceName) {
  await requireFile(
    artifacts.iosApp,
    "Run `npm run browserstack:prepare:ios` before uploading iOS.",
  );
  const { deviceName, osVersion } = splitQualifiedDevice(qualifiedDeviceName);
  console.log(`Uploading the iOS demo for Appium coverage on ${qualifiedDeviceName}…`);
  const upload = await uploadFile(
    "/app-automate/upload",
    artifacts.iosApp,
    "crumb-t10-ios-legacy-appium",
  );

  let session;
  const flows = [];
  try {
    session = await AppiumSession.create({
      appUrl: requiredResponseValue(upload, ["app_url"]),
      deviceName,
      osVersion,
    });
    console.log(`Started iOS legacy Appium session ${session.id}`);

    const cases = [
      ["dismissal and re-entry", appiumDismissalFlow],
      ["rotation and background recovery", appiumLifecycleFlow],
      ["masked local report draft", appiumLocalReportFlow],
      ["compact shake confirmation", appiumShakeFlow],
    ];
    for (const [name, test] of cases) {
      try {
        await resetIosApp(session);
        await test(session);
        flows.push({ name, status: "passed" });
        console.log(`iOS legacy: passed ${name}`);
      } catch (error) {
        flows.push({
          name,
          status: "failed",
          reason: safeErrorMessage(error),
        });
        console.log(`iOS legacy: failed ${name}`);
      }
    }

    const failed = flows.filter((flow) => flow.status !== "passed");
    const status = failed.length === 0 ? "passed" : "failed";
    const reason = failed.length === 0
      ? "All four Crumb iOS 15 lifecycle flows passed."
      : `${failed.length} of ${flows.length} Crumb iOS 15 lifecycle flows failed.`;
    await session.setBrowserStackStatus(status, reason);
    return { status, sessionId: session.id, device: qualifiedDeviceName, flows };
  } catch (error) {
    if (session) {
      await session.setBrowserStackStatus("failed", safeErrorMessage(error)).catch(() => {});
    }
    return {
      status: "failed",
      sessionId: session?.id,
      device: qualifiedDeviceName,
      flows,
      reason: safeErrorMessage(error),
    };
  } finally {
    await session?.quit().catch(() => {});
  }
}

async function resetIosApp(session) {
  const bundleId = "dev.crumb.nativepoc.ios";
  await session.execute("mobile: terminateApp", [{ bundleId }]).catch(() => {});
  await delay(500);
  await session.execute("mobile: activateApp", [{ bundleId }]);
  await delay(750);
  await session.waitForElement("demo.report-problem", 15_000);
}

async function appiumDismissalFlow(session) {
  await session.clickByAccessibilityId("demo.report-problem");
  await session.waitForElement("crumb.reporter-title");
  const grabber = await session.waitForElement("Sheet Grabber");
  await session.execute("mobile: swipe", [
    { direction: "down", element: grabber.id },
  ]);
  await session.waitForAbsent("crumb.reporter-title");
  await session.clickByAccessibilityId("demo.report-problem");
  await session.waitForElement("crumb.reporter-title");
}

async function appiumLifecycleFlow(session) {
  await session.clickByAccessibilityId("demo.report-problem");
  await session.waitForElement("crumb.reporter-title");
  await session.typeByAccessibilityId("crumb.description", "Keep this draft\n");

  await session.setOrientation("LANDSCAPE");
  let description = await session.waitForElement("crumb.description");
  assertIncludes(await session.elementText(description), "Keep this draft");

  await session.backgroundApp(2);
  await session.execute("mobile: activateApp", [{ bundleId: "dev.crumb.nativepoc.ios" }]);
  await session.waitForElement("crumb.reporter-title", 15_000);
  description = await session.waitForElement("crumb.description");
  assertIncludes(await session.elementText(description), "Keep this draft");
  await session.setOrientation("PORTRAIT");
}

async function appiumLocalReportFlow(session) {
  await session.clickByAccessibilityId("demo.simulate-activity");
  await session.clickByAccessibilityId("demo.report-problem");
  await session.waitForElement("crumb.reporter-title");
  await session.waitForElement("Masked screenshot preview");

  const diagnostics = await session.waitForElement("crumb.diagnostics-summary");
  await session.waitForElementText(diagnostics, (text) =>
    text.toLowerCase().startsWith("context ready"), 15_000);
  assertIncludes(await session.elementText(diagnostics), "CPU");

  await session.typeByAccessibilityId(
    "crumb.description",
    "The payment button stopped responding\n",
  );
  await session.clickByAccessibilityId("crumb.review-draft", { scrollIfNeeded: true });
  await session.waitForElement("crumb.review-title");
  await session.clickByAccessibilityId("crumb.show-technical-detail");
  const summary = await session.waitForElement("crumb.draft-summary");
  const summaryText = await session.elementText(summary);
  assertIncludes(summaryText, "LOCAL ONLY — NOT UPLOADED");
  assertIncludes(summaryText, "ON-DEMAND DIAGNOSTICS");
  assertIncludes(summaryText, "Network:");
  assertIncludes(summaryText, "The payment button stopped responding");
}

async function appiumShakeFlow(session) {
  const trigger = await session.waitForElement("demo.report-problem");
  await session.execute("mobile: touchAndHold", [
    { element: trigger.id, duration: 1.1 },
  ]);
  await session.waitForElement("crumb.shake-prompt-title");
  if (await session.findOptional("crumb.description")) {
    throw new Error("The full reporter appeared before shake confirmation.");
  }
  await session.clickByAccessibilityId("crumb.shake-report");
  await session.waitForElement("crumb.reporter-title");
  await session.waitForElement("crumb.description");
}

async function launchPlatform(platform, matrix) {
  if (platform === "ios") {
    await requireFile(
      artifacts.iosApp,
      "Run `npm run browserstack:prepare:ios` before uploading iOS.",
    );
    await requireFile(
      artifacts.iosTests,
      "Run `npm run browserstack:prepare:ios` before uploading iOS.",
    );

    console.log("Uploading the iOS demo and XCUI runner…");
    const app = await uploadFile(
      "/app-automate/xcuitest/v2/app",
      artifacts.iosApp,
      "crumb-t10-ios-app",
    );
    const tests = await uploadFile(
      "/app-automate/xcuitest/v2/test-suite",
      artifacts.iosTests,
      "crumb-t10-ios-tests",
    );
    const build = await browserStackRequest("/app-automate/xcuitest/v2/build", {
      method: "POST",
      body: {
        app: requiredResponseValue(app, ["app_url"]),
        testSuite: requiredResponseValue(tests, ["test_suite_url", "test_url"]),
        project: "Crumb T10",
        devices: [matrix.iosCurrent],
        resignApp: true,
        networkLogs: booleanEnvironment("BROWSERSTACK_NETWORK_LOGS", false),
        deviceLogs: true,
        debugscreenshots: true,
        video: true,
        appProfiling: booleanEnvironment("BROWSERSTACK_APP_PROFILING", false),
        enableResultBundle: true,
      },
    });
    const buildId = requiredResponseValue(build, ["build_id", "id"]);
    console.log(`Started iOS BrowserStack build ${buildId}`);
    return { platform, buildId };
  }

  await requireFile(
    artifacts.androidApp,
    "Run `npm run browserstack:prepare:android` before uploading Android.",
  );
  await requireFile(
    artifacts.androidTests,
    "Run `npm run browserstack:prepare:android` before uploading Android.",
  );

  console.log("Uploading the Android demo and Espresso runner…");
  const app = await uploadFile(
    "/app-automate/espresso/v2/app",
    artifacts.androidApp,
    "crumb-t10-android-app",
  );
  const tests = await uploadFile(
    "/app-automate/espresso/v2/test-suite",
    artifacts.androidTests,
    "crumb-t10-android-tests",
  );
  const build = await browserStackRequest("/app-automate/espresso/v2/build", {
    method: "POST",
    body: {
      app: requiredResponseValue(app, ["app_url"]),
      testSuite: requiredResponseValue(tests, ["test_url", "test_suite_url"]),
      project: "Crumb T10",
      devices: [matrix.androidLegacy, matrix.androidCurrent],
      instrumentationOptions: { disableAnalytics: "true" },
      networkLogs: booleanEnvironment("BROWSERSTACK_NETWORK_LOGS", false),
      deviceLogs: true,
      video: true,
      appProfiling: booleanEnvironment("BROWSERSTACK_APP_PROFILING", false),
    },
  });
  const buildId = requiredResponseValue(build, ["build_id", "id"]);
  console.log(`Started Android BrowserStack build ${buildId}`);
  return { platform, buildId };
}

async function resolveDeviceMatrix() {
  requireBrowserStackCredentials();
  const devices = await browserStackRequest("/app-automate/devices.json");
  if (!Array.isArray(devices)) {
    throw new Error("BrowserStack returned an invalid device list.");
  }

  const ios = devices.filter((device) => normalizedOs(device.os) === "ios");
  const android = devices.filter((device) => normalizedOs(device.os) === "android");
  if (ios.length === 0 || android.length === 0) {
    throw new Error("The BrowserStack account does not expose both iOS and Android devices.");
  }

  return {
    ios15: selectDevice(
      ios,
      process.env.BROWSERSTACK_IOS_15_DEVICE,
      (version) => versionParts(version)[0] === 15,
      "an iOS 15 device",
    ),
    iosCurrent: selectCurrentDevice(
      ios,
      process.env.BROWSERSTACK_IOS_CURRENT_DEVICE,
      "a current iOS device",
    ),
    androidLegacy: selectLegacyAndroidDevice(
      android,
      process.env.BROWSERSTACK_ANDROID_LEGACY_DEVICE ??
        process.env.BROWSERSTACK_ANDROID_API_26_DEVICE,
    ),
    androidCurrent: selectCurrentDevice(
      android,
      process.env.BROWSERSTACK_ANDROID_CURRENT_DEVICE,
      "a current Android device",
    ),
  };
}

function selectDevice(devices, override, predicate, description) {
  if (override) return validateOverride(devices, override, description);
  const candidates = devices.filter((device) => predicate(device.os_version));
  if (candidates.length === 0) {
    throw new Error(`BrowserStack did not return ${description}. Set an explicit device override in .env.`);
  }
  return qualifiedDevice(preferredDevice(candidates));
}

function selectLegacyAndroidDevice(devices, override) {
  if (override) return validateOverride(devices, override, "a legacy Android device");
  const android80 = devices.filter((device) => {
    const parts = versionParts(device.os_version);
    return parts[0] === 8 && (parts[1] ?? 0) === 0;
  });
  if (android80.length > 0) return qualifiedDevice(preferredDevice(android80));

  const android81 = devices.filter((device) => {
    const parts = versionParts(device.os_version);
    return parts[0] === 8 && parts[1] === 1;
  });
  if (android81.length > 0) {
    console.warn(
      "BrowserStack does not expose Android 8.0 / API 26; using Android 8.1 / API 27 as the nearest hosted real-device check.",
    );
    return qualifiedDevice(preferredDevice(android81));
  }

  throw new Error(
    "BrowserStack did not return Android 8.0 or 8.1. Set an explicit legacy Android device override in .env.",
  );
}

function selectCurrentDevice(devices, override, description) {
  if (override) return validateOverride(devices, override, description);
  const stableDevices = devices.filter(
    (device) => !/\bbeta\b/i.test(String(device.os_version)),
  );
  const current = [...stableDevices].sort(compareDeviceVersions).at(-1);
  if (!current) throw new Error(`BrowserStack did not return ${description}.`);
  const currentVersion = String(current.os_version);
  return qualifiedDevice(
    preferredDevice(devices.filter((device) => String(device.os_version) === currentVersion)),
  );
}

function validateOverride(devices, override, description) {
  const match = devices.find((device) => qualifiedDevice(device) === override);
  if (!match) {
    throw new Error(`The configured ${description} is not in this account's device list: ${override}`);
  }
  return qualifiedDevice(match);
}

function preferredDevice(devices) {
  return [...devices].sort((left, right) => {
    const tier = deviceTier(left) - deviceTier(right);
    if (tier !== 0) return tier;
    const formFactor = deviceFormPenalty(left) - deviceFormPenalty(right);
    if (formFactor !== 0) return formFactor;
    return String(left.device).localeCompare(String(right.device));
  })[0];
}

function deviceFormPenalty(device) {
  return /\b(?:ipad|tablet)\b/i.test(String(device.device)) ? 1 : 0;
}

function deviceTier(device) {
  const match = /\d+/.exec(String(device.device_tier ?? ""));
  return match ? Number(match[0]) : Number.MAX_SAFE_INTEGER;
}

function compareDeviceVersions(left, right) {
  const leftParts = versionParts(left.os_version);
  const rightParts = versionParts(right.os_version);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return String(left.device).localeCompare(String(right.device));
}

function versionParts(value) {
  return (String(value).match(/\d+/g) ?? []).map(Number);
}

function qualifiedDevice(device) {
  return `${device.device}-${device.os_version}`;
}

function normalizedOs(value) {
  return String(value).toLowerCase();
}

function printMatrix(matrix, requestedPlatforms = ["ios", "android"]) {
  const rows = [];
  if (requestedPlatforms.includes("ios")) {
    rows.push({ gate: "iOS 15", device: matrix.ios15 });
    rows.push({ gate: "Current iOS", device: matrix.iosCurrent });
  }
  if (requestedPlatforms.includes("android")) {
    rows.push({ gate: "Legacy Android", device: matrix.androidLegacy });
    rows.push({ gate: "Current Android", device: matrix.androidCurrent });
  }
  console.table(rows);
}

async function uploadFile(endpoint, file, customId) {
  const form = new FormData();
  form.set("file", new Blob([await readFile(file)]), basename(file));
  form.set("custom_id", customId);
  return browserStackRequest(endpoint, { method: "POST", body: form });
}

class AppiumSession {
  constructor(id) {
    this.id = id;
  }

  static async create({ appUrl, deviceName, osVersion }) {
    const value = await browserStackWebDriverRequest("POST", "/session", {
      capabilities: {
        alwaysMatch: {
          platformName: "iOS",
          "appium:automationName": "XCUITest",
          "appium:deviceName": deviceName,
          "appium:platformVersion": osVersion,
          "appium:app": appUrl,
          "appium:autoAcceptAlerts": true,
          "appium:newCommandTimeout": 300,
          "bstack:options": {
            userName: requiredEnvironment("BROWSERSTACK_USERNAME"),
            accessKey: requiredEnvironment("BROWSERSTACK_ACCESS_KEY"),
            projectName: "Crumb T10",
            buildName: `Crumb iOS 15 Appium ${new Date().toISOString()}`,
            sessionName: "iOS 15 lifecycle flow matrix",
            debug: true,
            video: true,
            deviceLogs: true,
            networkLogs: booleanEnvironment("BROWSERSTACK_NETWORK_LOGS", false),
          },
        },
      },
    });
    const sessionId = value.sessionId;
    if (!sessionId) throw new Error("BrowserStack did not return an Appium session ID.");
    return new AppiumSession(sessionId);
  }

  command(method, path, body) {
    return browserStackWebDriverRequest(
      method,
      `/session/${encodeURIComponent(this.id)}${path}`,
      body,
    );
  }

  async findOptional(accessibilityId) {
    try {
      const value = await this.command("POST", "/element", {
        using: "accessibility id",
        value: accessibilityId,
      });
      return { id: webdriverElementId(value) };
    } catch (error) {
      if (error.webdriverError === "no such element") return null;
      throw error;
    }
  }

  async waitForElement(accessibilityId, timeout = 10_000) {
    return waitUntil(async () => this.findOptional(accessibilityId), timeout,
      `Timed out waiting for ${accessibilityId}.`);
  }

  async waitForAbsent(accessibilityId, timeout = 10_000) {
    await waitUntil(async () =>
      (await this.findOptional(accessibilityId)) ? null : true,
    timeout, `Timed out waiting for ${accessibilityId} to disappear.`);
  }

  async click(element) {
    await this.command("POST", `/element/${encodeURIComponent(element.id)}/click`, {});
  }

  async clickByAccessibilityId(accessibilityId, options = {}) {
    let element = options.scrollIfNeeded
      ? await this.findOptional(accessibilityId)
      : await this.waitForElement(accessibilityId);
    if (!element && options.scrollIfNeeded) {
      for (let attempt = 0; attempt < 5 && !element; attempt += 1) {
        await this.execute("mobile: scroll", [{ direction: "down" }]);
        await delay(300);
        element = await this.findOptional(accessibilityId);
      }
    }
    if (!element) {
      throw new Error(`Timed out waiting for ${accessibilityId}.`);
    }
    try {
      await this.click(element);
    } catch (error) {
      if (!options.scrollIfNeeded) throw error;
      await this.execute("mobile: scroll", [{ direction: "down" }]);
      element = await this.waitForElement(accessibilityId);
      await this.click(element);
    }
  }

  async typeByAccessibilityId(accessibilityId, text) {
    const element = await this.waitForElement(accessibilityId);
    await this.click(element);
    await this.command("POST", `/element/${encodeURIComponent(element.id)}/clear`, {});
    await this.command("POST", `/element/${encodeURIComponent(element.id)}/value`, {
      text,
      value: [...text],
    });
  }

  async elementAttribute(element, name) {
    return this.command(
      "GET",
      `/element/${encodeURIComponent(element.id)}/attribute/${encodeURIComponent(name)}`,
    );
  }

  async elementText(element) {
    const values = await Promise.all([
      this.elementAttribute(element, "label").catch(() => ""),
      this.elementAttribute(element, "value").catch(() => ""),
    ]);
    return [...new Set(values.filter((value) => typeof value === "string" && value))]
      .join("\n");
  }

  async waitForElementText(element, predicate, timeout = 10_000) {
    await waitUntil(async () => {
      const text = await this.elementText(element);
      return predicate(text) ? text : null;
    }, timeout, "Timed out waiting for the expected element text.");
  }

  execute(script, args = []) {
    return this.command("POST", "/execute/sync", { script, args });
  }

  setOrientation(orientation) {
    return this.command("POST", "/orientation", { orientation });
  }

  backgroundApp(seconds) {
    return this.command("POST", "/appium/app/background", { seconds });
  }

  async hideKeyboard() {
    await this.command("POST", "/appium/device/hide_keyboard", {}).catch(async () => {
      const title = await this.waitForElement("crumb.reporter-title");
      await this.click(title);
    });
  }

  setBrowserStackStatus(status, reason) {
    const script = `browserstack_executor: ${JSON.stringify({
      action: "setSessionStatus",
      arguments: { status, reason },
    })}`;
    return this.execute(script);
  }

  quit() {
    return browserStackWebDriverRequest(
      "DELETE",
      `/session/${encodeURIComponent(this.id)}`,
    );
  }
}

async function browserStackWebDriverRequest(method, path, body) {
  const headers = new Headers();
  headers.set("Content-Type", "application/json");
  headers.set(
    "Authorization",
    `Basic ${Buffer.from(
      `${requiredEnvironment("BROWSERSTACK_USERNAME")}:${requiredEnvironment("BROWSERSTACK_ACCESS_KEY")}`,
    ).toString("base64")}`,
  );
  const response = await fetch(`https://hub-cloud.browserstack.com/wd/hub${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const parsed = await response.json().catch(() => ({}));
  const value = parsed.value ?? parsed;
  if (!response.ok || value?.error) {
    const error = new Error(
      `BrowserStack Appium ${value?.error ?? response.status}: ${String(
        value?.message ?? "request failed",
      ).slice(0, 700)}`,
    );
    error.webdriverError = value?.error;
    throw error;
  }
  return value;
}

function webdriverElementId(value) {
  const id = value?.["element-6066-11e4-a52e-4f735466cecf"] ?? value?.ELEMENT;
  if (!id) throw new Error("Appium did not return an element ID.");
  return id;
}

function splitQualifiedDevice(value) {
  const separator = value.lastIndexOf("-");
  if (separator <= 0 || separator === value.length - 1) {
    throw new Error(`Invalid BrowserStack device value: ${value}`);
  }
  return {
    deviceName: value.slice(0, separator),
    osVersion: value.slice(separator + 1),
  };
}

async function waitUntil(check, timeout, message) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const result = await check();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await delay(400);
  }
  throw new Error(lastError ? `${message} ${safeErrorMessage(lastError)}` : message);
}

function assertIncludes(value, expected) {
  if (!String(value).includes(expected)) {
    throw new Error(`Expected element text to include ${JSON.stringify(expected)}.`);
  }
}

function safeErrorMessage(error) {
  return String(error?.message ?? error).slice(0, 1000);
}

async function browserStackRequest(path, options = {}) {
  requireBrowserStackCredentials();
  const headers = new Headers(options.headers ?? {});
  headers.set(
    "Authorization",
    `Basic ${Buffer.from(
      `${process.env.BROWSERSTACK_USERNAME}:${process.env.BROWSERSTACK_ACCESS_KEY}`,
    ).toString("base64")}`,
  );

  let body = options.body;
  if (body && !(body instanceof FormData)) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(body);
  }

  const response = await fetch(`${apiRoot}${path}`, {
    method: options.method ?? "GET",
    headers,
    body,
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { message: text.slice(0, 500) };
  }
  if (!response.ok) {
    throw new Error(
      `BrowserStack API ${response.status}: ${parsed.message ?? parsed.error ?? "request failed"}`,
    );
  }
  return parsed;
}

async function waitForBuild(platform, buildId) {
  const framework = platform === "ios" ? "xcuitest" : "espresso";
  const timeoutMinutes = Number(process.env.BROWSERSTACK_WAIT_MINUTES ?? "30");
  if (!Number.isFinite(timeoutMinutes) || timeoutMinutes <= 0) {
    throw new Error("BROWSERSTACK_WAIT_MINUTES must be a positive number.");
  }

  const deadline = Date.now() + timeoutMinutes * 60_000;
  let result;
  while (Date.now() < deadline) {
    result = await browserStackRequest(
      `/app-automate/${framework}/v2/builds/${encodeURIComponent(buildId)}`,
    );
    const status = String(result.status ?? "unknown").toLowerCase();
    console.log(`${platform} ${buildId}: ${status}`);
    if (!new Set(["queued", "running", "in_progress", "unknown"]).has(status)) {
      return result;
    }
    await delay(15_000);
  }
  throw new Error(`${platform} BrowserStack build ${buildId} exceeded ${timeoutMinutes} minutes.`);
}

function isSuccessfulStatus(status) {
  return new Set(["passed", "done", "success", "completed"]).has(
    String(status ?? "").toLowerCase(),
  );
}

function requiredResponseValue(response, keys) {
  for (const key of keys) {
    if (response?.[key]) return response[key];
  }
  throw new Error(`BrowserStack response was missing ${keys.join(" or ")}.`);
}

function requireBrowserStackCredentials() {
  requiredEnvironment("BROWSERSTACK_USERNAME");
  requiredEnvironment("BROWSERSTACK_ACCESS_KEY");
}

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Set ${name} in .env or the terminal environment.`);
  }
  return value;
}

function booleanEnvironment(name, fallback) {
  const value = process.env[name]?.trim().toLowerCase();
  if (!value) return fallback;
  if (["1", "true", "yes", "on"].includes(value)) return true;
  if (["0", "false", "no", "off"].includes(value)) return false;
  throw new Error(`${name} must be true or false.`);
}

async function requireFile(path, message) {
  try {
    await access(path);
  } catch {
    throw new Error(message);
  }
}

async function runProcess(executable, arguments_, cwd) {
  await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, arguments_, {
      cwd,
      env: process.env,
      stdio: "inherit",
    });
    child.on("error", rejectPromise);
    child.on("exit", (code, signal) => {
      if (code === 0) {
        resolvePromise();
      } else {
        rejectPromise(
          new Error(
            `${executable} exited with ${signal ? `signal ${signal}` : `code ${code}`}.`,
          ),
        );
      }
    });
  });
}

function relativeArtifact(path) {
  return path.replace(`${repositoryRoot}/`, "");
}

function delay(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

function printHelp() {
  console.log(`Crumb BrowserStack real-device runner

Usage:
  npm run browserstack:prepare
  npm run browserstack:devices
  npm run browserstack:run

Platform-specific commands are also available for iOS and Android.
Credentials and APPLE_DEVELOPMENT_TEAM may be set in the ignored .env file.`);
}

await main();
