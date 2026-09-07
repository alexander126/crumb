import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function readJson(relativePath) {
  return JSON.parse(await readFile(path.join(root, relativePath), "utf8"));
}

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);

const fixtures = [
  {
    name: "source-map-upload",
    schema: "schemas/source-map-upload.schema.json",
    valid: "schemas/examples/source-map-upload.valid.json",
    invalid: "schemas/examples/source-map-upload.invalid.json",
  },
  {
    name: "report-envelope",
    schema: "schemas/report-envelope.schema.json",
    valid: "schemas/examples/report-envelope.valid.json",
    invalid: "schemas/examples/report-envelope.invalid.json",
  },
  {
    name: "sdk-configuration",
    schema: "schemas/sdk-configuration.schema.json",
    valid: "schemas/examples/sdk-configuration.valid.json",
    invalid: "schemas/examples/sdk-configuration.invalid.json",
  },
  {
    name: "workspace-policy",
    schema: "schemas/workspace-policy.schema.json",
    valid: "schemas/examples/workspace-policy.valid.json",
    invalid: "schemas/examples/workspace-policy.invalid.json",
  },
];

let failed = false;
for (const fixture of fixtures) {
  const validate = ajv.compile(await readJson(fixture.schema));
  const validExample = await readJson(fixture.valid);
  const invalidExample = await readJson(fixture.invalid);

  if (!validate(validExample)) {
    console.error(`The valid ${fixture.name} fixture failed validation:`);
    console.error(validate.errors);
    failed = true;
  }

  if (validate(invalidExample)) {
    console.error(`The invalid ${fixture.name} fixture unexpectedly passed validation.`);
    failed = true;
  }
}

const precedence = await readJson("schemas/examples/policy-precedence.valid.json");
const localEvidence = new Set(precedence.local.evidence);
const disabledEvidence = new Set(precedence.workspace.disabled_evidence);
const effectiveEvidence = new Set(precedence.effective.evidence);
if ([...effectiveEvidence].some((item) => !localEvidence.has(item)) ||
    [...disabledEvidence].some((item) => effectiveEvidence.has(item))) {
  console.error("The policy-precedence fixture broadens local evidence or ignores a disablement.");
  failed = true;
}

const localFields = new Set(precedence.local.visible_fields);
const effectiveFields = new Set(precedence.effective.visible_fields);
if ([...effectiveFields].some((item) => !localFields.has(item)) ||
    !effectiveFields.has("description")) {
  console.error("The policy-precedence fixture broadens or removes required reporter fields.");
  failed = true;
}

const localContext = new Set(precedence.local.allowed_context_keys);
const policyContext = new Set(precedence.workspace.allowed_context_keys);
const effectiveContext = new Set(precedence.effective.allowed_context_keys);
if ([...effectiveContext].some((item) => !localContext.has(item) || !policyContext.has(item))) {
  console.error("The policy-precedence fixture broadens the custom-context allowlist.");
  failed = true;
}

if (failed) process.exitCode = 1;
else console.log("Public contract fixtures passed.");

const validateNativeStacks = ajv.compile(await readJson("schemas/report-envelope.v1.1.schema.json"));
const nativeStacks = await readJson("schemas/examples/report-envelope.native-stacks.valid.json");
const validateLegacyStacks = ajv.getSchema("https://schemas.example.invalid/mobile-report-envelope/1.0/schema.json");
if (!validateNativeStacks(nativeStacks) || validateLegacyStacks(nativeStacks) ||
    validateLegacyStacks({ ...nativeStacks, schema_version: "1.0" }) ||
    validateNativeStacks({ ...nativeStacks, schema_version: "1.2" })) {
  console.error("Versioned native stack compatibility failed", validateNativeStacks.errors);
  process.exitCode = 1;
}

// Versioned screen context: old consumers must reject it, including retagged envelopes.
const screenSchema = ajv.compile(await readJson("schemas/report-envelope.v1.2.schema.json"));
const screenFixture = await readJson("schemas/examples/report-envelope.v1.2.valid.json");
if (!screenSchema(screenFixture)) throw new Error("Valid screen context rejected: " + JSON.stringify(screenSchema.errors));
for (const [version, filename] of [["1.0", "report-envelope.schema.json"], ["1.1", "report-envelope.v1.1.schema.json"]]) {
  const oldSchema = ajv.getSchema((await readJson("schemas/" + filename)).$id);
  if (!oldSchema || oldSchema({ ...screenFixture, schema_version: version })) throw new Error("Old schema accepted screen context");
}
for (const screen of [
  { ...screenFixture.diagnostics.screen_context, params: { id: "private" } },
  { ...screenFixture.diagnostics.screen_context, name: "/orders?id=private" },
  { ...screenFixture.diagnostics.screen_context, name: "https://example.invalid/orders" },
  { ...screenFixture.diagnostics.screen_context, route: Array(9).fill("Home") },
  { ...screenFixture.diagnostics.screen_context, source: "inferred" },
]) {
  const invalid = structuredClone(screenFixture); invalid.diagnostics.screen_context = screen;
  if (screenSchema(invalid)) throw new Error("Invalid screen context accepted");
}
console.log("Screen context 1.2 and legacy rejection contracts passed.");
