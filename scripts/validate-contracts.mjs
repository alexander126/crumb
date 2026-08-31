import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function readJson(relativePath) {
  return JSON.parse(await readFile(path.join(root, relativePath), "utf8"));
}

const schema = await readJson("schemas/report-envelope.schema.json");
const validExample = await readJson("schemas/examples/report-envelope.valid.json");
const invalidExample = await readJson("schemas/examples/report-envelope.invalid.json");

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);

if (!validate(validExample)) {
  console.error("The valid report-envelope fixture failed validation:");
  console.error(validate.errors);
  process.exitCode = 1;
}

if (validate(invalidExample)) {
  console.error("The invalid report-envelope fixture unexpectedly passed validation.");
  process.exitCode = 1;
}

if (process.exitCode !== 1) {
  console.log("Report-envelope contract fixtures passed.");
}

