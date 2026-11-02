import assert from "node:assert/strict";
import { test } from "node:test";
import { verifyKotlinClassMetadata, verifyPublishedKotlinDependencies, verifyUploadTransportCompatibility } from "../android-kotlin-compatibility.mjs";

const pom = (version = "2.0.21", scope = "compile") => `<dependencies><dependency><groupId>org.jetbrains.kotlin</groupId><artifactId>kotlin-stdlib</artifactId><version>${version}</version><scope>${scope}</scope></dependency></dependencies>`;
const module = (version = { requires: "2.0.21" }) => ({
  variants: ["java-api", "java-runtime"].map((usage) => ({
    name: usage,
    attributes: { "org.gradle.category": "library", "org.gradle.usage": usage },
    dependencies: [{ group: "org.jetbrains.kotlin", module: "kotlin-stdlib", version }],
  })),
});

test("requires compatible POM and both module variants without a strict constraint", () => {
  verifyPublishedKotlinDependencies(pom(), module());
  assert.throws(() => verifyPublishedKotlinDependencies(pom("2.2.0"), module()));
  assert.throws(() => verifyPublishedKotlinDependencies(pom("2.0.21", "runtime"), module()));
  assert.throws(() => verifyPublishedKotlinDependencies(pom(), module({ requires: "2.2.0" })));
  assert.throws(() => verifyPublishedKotlinDependencies(pom(), module({ requires: "2.0.21", strictly: "2.0.21" })));
  const missingRuntime = module();
  missingRuntime.variants.pop();
  assert.throws(() => verifyPublishedKotlinDependencies(pom(), missingRuntime));
  const withSources = module();
  withSources.variants.push({ name: "sources", attributes: { "org.gradle.category": "documentation", "org.gradle.usage": "java-runtime" } });
  verifyPublishedKotlinDependencies(pom(), withSources);
});

test("checks every emitted metadata annotation rather than constant-pool references", () => {
  const declaration = (version) => `    kotlin.Metadata(\n      mv=[${version}]\n      k=1\n    )\n`;
  assert.equal(verifyKotlinClassMetadata(declaration("2,0,0") + declaration("2,0,0")), 2);
  assert.throws(() => verifyKotlinClassMetadata(declaration("2,0,0") + declaration("2,2,0")));
  assert.throws(() => verifyKotlinClassMetadata("#51 = Utf8 kotlin.Metadata\n#52 = Utf8 mv"));
  assert.throws(() => verifyKotlinClassMetadata("    kotlin.Metadata(\n      k=1\n    )"));
});

test("retains Java default cancellation and older Kotlin compatibility entry points", () => {
  const signatures = `public interface dev.crumb.core.CrumbUploadTransport {
  public default void cancel();
  public static void access$cancel$jd(dev.crumb.core.CrumbUploadTransport);
}
public final class dev.crumb.core.CrumbUploadTransport$DefaultImpls {
  public static void cancel(dev.crumb.core.CrumbUploadTransport);
}`;
  verifyUploadTransportCompatibility(signatures);
  assert.throws(() => verifyUploadTransportCompatibility(signatures.replace("public default", "public abstract")));
  assert.throws(() => verifyUploadTransportCompatibility(signatures.replace("  public static void cancel(dev.crumb.core.CrumbUploadTransport);", "")));
  assert.throws(() => verifyUploadTransportCompatibility(signatures.replace("  public static void access$cancel$jd(dev.crumb.core.CrumbUploadTransport);", "")));
});
