import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const standardLibrary = "2.0.21";

export function verifyPublishedKotlinDependencies(pom, module) {
  const dependencies = [...pom.matchAll(/<dependency>([\s\S]*?)<\/dependency>/g)].map((match) => {
    const value = (tag) => match[1].match(new RegExp(`<${tag}>([^<]+)</${tag}>`))?.[1];
    return { group: value("groupId"), name: value("artifactId"), version: value("version"), scope: value("scope") };
  });
  assert.deepEqual(
    dependencies.filter(({ group, name }) => group === "org.jetbrains.kotlin" && name === "kotlin-stdlib"),
    [{ group: "org.jetbrains.kotlin", name: "kotlin-stdlib", version: standardLibrary, scope: "compile" }],
    "The POM must expose the ordinary floor-compatible standard library dependency",
  );
  const variants = module.variants.filter((variant) => variant.attributes?.["org.gradle.category"] === "library" && ["java-api", "java-runtime"].includes(variant.attributes["org.gradle.usage"]));
  assert.deepEqual(variants.map((variant) => variant.attributes["org.gradle.usage"]).sort(), ["java-api", "java-runtime"], "Check both published API and runtime library variants");
  for (const variant of variants) {
    const kotlin = variant.dependencies.filter(({ group, module: name }) => group === "org.jetbrains.kotlin" && name === "kotlin-stdlib");
    assert.equal(kotlin.length, 1, `${variant.name} must declare one standard library dependency`);
    assert.deepEqual(kotlin[0].version, { requires: standardLibrary }, "Do not force newer hosts onto the floor standard library");
  }
}

export function verifyKotlinClassMetadata(dump) {
  const annotations = [...dump.matchAll(/^\s+kotlin\.Metadata\(/gm)];
  const versions = [...dump.matchAll(/^\s+kotlin\.Metadata\(\r?\n\s+mv=\[([0-9, ]+)\]/gm)];
  assert.ok(annotations.length > 0, "The published classes must contain Kotlin metadata");
  assert.equal(versions.length, annotations.length, "Every Kotlin metadata annotation must expose its version");
  for (const version of versions) {
    assert.deepEqual(version[1].split(",").map(Number), [2, 0, 0], "SDK class metadata must target language version 2.0");
  }
  return versions.length;
}

export function verifyUploadTransportCompatibility(signatures) {
  const transport = signatures.match(/public interface dev\.crumb\.core\.CrumbUploadTransport \{([^}]+)\}/)?.[1];
  const legacy = signatures.match(/public final class dev\.crumb\.core\.CrumbUploadTransport\$DefaultImpls \{([^}]+)\}/)?.[1];
  assert.ok(transport && legacy, "Preserve both published transport interface and compatibility class");
  assert.match(transport, /^\s+public default void cancel\(\);$/m, "Java implementations must inherit the default cancellation method");
  assert.match(transport, /^\s+public static void access\$cancel\$jd\(dev\.crumb\.core\.CrumbUploadTransport\);$/m);
  assert.match(legacy, /^\s+public static void cancel\(dev\.crumb\.core\.CrumbUploadTransport\);$/m, "Preserve the older Kotlin DefaultImpls bridge");
}

export function verifyResolvedKotlinConsumer(evidence, repository, sdkVersion, compilerVersion) {
  const hash = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
  const compiler = evidence.compiler.filter(({ group, name }) => group === "org.jetbrains.kotlin" && name === "kotlin-compiler-embeddable");
  assert.equal(compiler.length, 1);
  assert.equal(compiler[0].version, compilerVersion, "Use the actual requested Kotlin compiler");
  assert.equal(hash(compiler[0].file), compiler[0].sha256);
  for (const classpath of [evidence.compile, evidence.runtime]) {
    const stdlib = classpath.filter(({ group, name }) => group === "org.jetbrains.kotlin" && name === "kotlin-stdlib");
    assert.equal(stdlib.length, 1);
    assert.equal(stdlib[0].version, compilerVersion, "Preserve normal consumer standard library resolution");
    assert.equal(hash(stdlib[0].file), stdlib[0].sha256);
    const sdk = classpath.filter(({ group }) => group === "com.crumbsdk");
    assert.deepEqual(
      sdk.map(({ name }) => name).sort(),
      ["crumb-core", "crumb-react-native", "crumb-ui"],
      "UI and React Native support must expose Core transitively",
    );
    for (const artifact of sdk) {
      assert.equal(artifact.moduleComponent, true, "Use Maven modules, never project source substitution");
      assert.equal(artifact.version, sdkVersion);
      const staged = join(repository, "com/crumbsdk", artifact.name, sdkVersion, `${artifact.name}-${sdkVersion}.aar`);
      assert.equal(hash(artifact.file), artifact.sha256, "Resolved artifact evidence must describe the current file");
      assert.equal(artifact.sha256, hash(staged), "Consume the freshly staged SDK artifact bytes");
    }
  }
  const identify = ({ version, sha256 }) => ({ version, sha256 });
  return {
    compiler: identify(compiler[0]),
    compileStandardLibrary: identify(evidence.compile.find(({ group, name }) => group === "org.jetbrains.kotlin" && name === "kotlin-stdlib")),
    runtimeStandardLibrary: identify(evidence.runtime.find(({ group, name }) => group === "org.jetbrains.kotlin" && name === "kotlin-stdlib")),
    sdk: evidence.compile.filter(({ group }) => group === "com.crumbsdk").map(({ name, sha256 }) => ({ name, sha256 })),
  };
}
