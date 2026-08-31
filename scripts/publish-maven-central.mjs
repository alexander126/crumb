import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const bundlePath = join(
  root,
  "dist",
  "registry",
  "maven",
  version,
  `crumb-maven-central-${version}.zip`,
);
const username = process.env.CENTRAL_TOKEN_USERNAME;
const password = process.env.CENTRAL_TOKEN_PASSWORD;
const automatic = process.argv.includes("--automatic");

if (!username || !password) {
  throw new Error("CENTRAL_TOKEN_USERNAME and CENTRAL_TOKEN_PASSWORD are required");
}

const authorization = `Bearer ${Buffer.from(`${username}:${password}`).toString("base64")}`;
const form = new FormData();
form.append(
  "bundle",
  new Blob([readFileSync(bundlePath)], { type: "application/octet-stream" }),
  basename(bundlePath),
);

const uploadUrl = new URL("https://central.sonatype.com/api/v1/publisher/upload");
uploadUrl.searchParams.set("name", `Crumb ${version}`);
uploadUrl.searchParams.set("publishingType", automatic ? "AUTOMATIC" : "USER_MANAGED");

const upload = await fetch(uploadUrl, {
  method: "POST",
  headers: { Authorization: authorization },
  body: form,
});
if (!upload.ok) {
  throw new Error(`Maven Central upload failed (${upload.status}): ${await upload.text()}`);
}

const deploymentId = (await upload.text()).trim();
if (!/^[0-9a-f-]{36}$/i.test(deploymentId)) {
  throw new Error(`Maven Central returned an invalid deployment ID: ${deploymentId}`);
}
console.log(`Maven Central deployment created: ${deploymentId}`);

const terminalStates = new Set(automatic ? ["PUBLISHED", "FAILED"] : ["VALIDATED", "FAILED"]);
const deadline = Date.now() + 30 * 60 * 1000;
let previousState;

while (Date.now() < deadline) {
  const statusUrl = new URL("https://central.sonatype.com/api/v1/publisher/status");
  statusUrl.searchParams.set("id", deploymentId);
  const response = await fetch(statusUrl, {
    method: "POST",
    headers: { Authorization: authorization },
  });
  if (!response.ok) {
    throw new Error(`Maven Central status failed (${response.status}): ${await response.text()}`);
  }

  const deployment = await response.json();
  if (deployment.deploymentState !== previousState) {
    console.log(`Maven Central deployment state: ${deployment.deploymentState}`);
    previousState = deployment.deploymentState;
  }
  if (terminalStates.has(deployment.deploymentState)) {
    if (deployment.deploymentState === "FAILED") {
      throw new Error(`Maven Central validation failed: ${JSON.stringify(deployment.errors ?? {})}`);
    }
    console.log(
      automatic
        ? `Maven Central published Crumb ${version}.`
        : `Maven Central validated Crumb ${version}; deployment ${deploymentId} awaits publication.`,
    );
    process.exit(0);
  }

  await new Promise((resolvePromise) => setTimeout(resolvePromise, 10_000));
}

throw new Error(`Timed out waiting for Maven Central deployment ${deploymentId}`);
