import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const { name, version } = JSON.parse(readFileSync("package.json", "utf8"));
const tag = process.env.RELEASE_TAG;
const channel = process.env.DIST_TAG;
if (
  name !== "@crumbsdk/source-maps" ||
  version !== readFileSync("../../VERSION", "utf8").trim() ||
  tag !== version
) {
  throw new Error(
    "Package identity, VERSION and immutable release tag must match.",
  );
}
if (process.env.CONFIRMATION !== `publish @crumbsdk/source-maps@${version}`) {
  throw new Error("Explicit package publication confirmation is required.");
}
if (channel !== (version.includes("-") ? "next" : "latest")) {
  throw new Error(
    "Prereleases must use next; stable releases must use latest.",
  );
}
const tagged = execFileSync(
  "git",
  ["rev-parse", "--verify", `refs/tags/${tag}^{commit}`],
  { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
).trim();
const head = execFileSync("git", ["rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
if (tagged !== head)
  throw new Error("The release tag must point to the checked-out commit.");
console.log(
  "Package identity, version, release tag, channel and explicit confirmation verified.",
);
