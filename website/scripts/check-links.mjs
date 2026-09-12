import { readdir, readFile, stat } from "node:fs/promises";
import { join, resolve, relative } from "node:path";
import { load } from "cheerio";

const root = resolve("out");
async function files(dir) {
  const result = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    result.push(...(entry.isDirectory() ? await files(path) : [path]));
  }
  return result;
}
async function targetFile(pathname) {
  const path = resolve(root, "." + decodeURIComponent(pathname));
  if (path !== root && !path.startsWith(root + "/")) return;
  for (const candidate of [path, join(path, "index.html"), path + ".html"]) {
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {}
  }
}
const failures = new Set();
let links = 0;
const html = (await files(root)).filter((p) => p.endsWith(".html"));
for (const file of html) {
  const url = new URL(
    "/" + relative(root, file).replace(/index\.html$/, ""),
    "https://docs.example.com",
  );
  const $ = load(await readFile(file, "utf8"));
  for (const el of $("a[href]").toArray()) {
    const href = $(el).attr("href");
    if (!href || /^(mailto:|tel:|https?:\/\/)/.test(href)) continue;
    const target = new URL(href, url);
    const found = await targetFile(target.pathname);
    links++;
    if (!found) {
      failures.add(`${relative(root, file)} → ${href}: missing file`);
      continue;
    }
    if (target.hash && found.endsWith(".html")) {
      const document = load(await readFile(found, "utf8"));
      const id = decodeURIComponent(target.hash.slice(1));
      if (
        !document("[id]")
          .toArray()
          .some((el) => document(el).attr("id") === id)
      ) {
        failures.add(`${relative(root, file)} → ${href}: missing anchor`);
      }
    }
  }
}
// Markdown exports are generated from the explicit public content collection only.
const markdown = await readFile(join(root, "llms-full.txt"), "utf8");
for (const path of [
  "quickstarts/react-native",
  "quickstarts/ios",
  "quickstarts/android",
]) {
  if (!markdown.includes(`/docs/${path}`))
    failures.add(`Missing Markdown quickstart: ${path}`);
}
if (failures.size) {
  console.error([...failures].join("\n"));
  process.exitCode = 1;
} else
  console.log(
    `Validated ${links} internal links/anchors across ${html.length} HTML files and all quickstart Markdown exports.`,
  );
