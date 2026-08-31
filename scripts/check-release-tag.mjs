import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const tag = process.argv[2] ?? process.env.GITHUB_REF_NAME;

if (!tag) throw new Error("Provide a release tag or set GITHUB_REF_NAME");
if (tag !== version) throw new Error(`Release tag ${tag} does not match VERSION ${version}`);
console.log(`Verified release tag ${tag}.`);
