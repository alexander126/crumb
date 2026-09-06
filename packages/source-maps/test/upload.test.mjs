import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, writeFile, rm, truncate } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { prepareUpload, upload } from "../dist/upload.js";
import {
  canonicalJson,
  sha256,
  validateSourceMap,
  MAX_ARTIFACT_BYTES,
} from "../dist/validation.js";

const id = "00000000-0000-4000-8000-000000000001";
const token = "synthetic-upload-credential";
const sourceMap = {
  version: 3,
  sources: ["App.ts"],
  names: ["fail"],
  mappings: "AAAAA",
  sourcesContent: ['throw new Error("synthetic source content")'],
};

async function inputs(t) {
  const dir = await mkdtemp(join(tmpdir(), "crumb-source-maps-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const options = {
    platform: "ios",
    appVersion: "1.2.3",
    nativeBuild: "42",
    bundleVersion: "build-abc",
    bundle: join(dir, "main.bundle"),
    sourceMap: join(dir, "main.map"),
  };
  await writeFile(options.bundle, 'throw Error("synthetic bundle")');
  await writeFile(options.sourceMap, JSON.stringify(sourceMap));
  return options;
}
function cli(args, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["dist/cli.js", ...args], {
      env: { ...process.env, CRUMB_SOURCE_MAP_TOKEN: "", ...env },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => {
      stdout += data;
    });
    child.stderr.on("data", (data) => {
      stderr += data;
    });
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}
function args(options) {
  return [
    "upload",
    "--platform",
    options.platform,
    "--app-version",
    options.appVersion,
    "--native-build",
    options.nativeBuild,
    "--bundle-version",
    options.bundleVersion,
    "--bundle",
    options.bundle,
    "--source-map",
    options.sourceMap,
  ];
}
function response(prepared, extra = {}) {
  return Response.json({
    upload_id: id,
    manifest_sha256: prepared.manifestSha256,
    status: "verified",
    ...extra,
  });
}
function targets(prepared, artifacts) {
  return response(prepared, {
    status: "initialized",
    artifacts:
      artifacts ??
      ["bundle", "source_map"].map((kind) => ({
        kind,
        method: "PUT",
        url: `https://artifacts.example/${kind}`,
        headers: { "content-type": "application/octet-stream" },
      })),
  });
}

test("prepares byte-exact platform-specific identity and deterministic manifest", async (t) => {
  const options = await inputs(t);
  const first = await prepareUpload(options);
  const second = await prepareUpload(options);
  assert.equal(first.manifestSha256, second.manifestSha256);
  assert.equal(first.manifest.bundle.sha256, sha256(first.bundle));
  assert.equal(first.manifest.source_map.sha256, sha256(first.sourceMap));
  assert.notEqual(
    first.manifestSha256,
    (await prepareUpload({ ...options, platform: "android" })).manifestSha256,
  );
  assert.equal(
    canonicalJson({ z: 1, a: { b: 2, a: 3 } }),
    '{"a":{"a":3,"b":2},"z":1}',
  );
  await prepareUpload({
    ...options,
    expectedBundleSha256: first.manifest.bundle.sha256,
    expectedSourceMapSha256: first.manifest.source_map.sha256,
  });
});

test("rejects missing or ambiguous release fields and wrong hashes before network", async (t) => {
  const options = await inputs(t);
  for (const field of ["appVersion", "nativeBuild", "bundleVersion"]) {
    await assert.rejects(prepareUpload({ ...options, [field]: undefined }), {
      code: "invalid_release",
    });
    await assert.rejects(
      prepareUpload({ ...options, [field]: "contains space" }),
      { code: "invalid_release" },
    );
  }
  await assert.rejects(
    prepareUpload({ ...options, platform: "react_native" }),
    { code: "invalid_platform" },
  );
  for (const field of ["expectedBundleSha256", "expectedSourceMapSha256"]) {
    await assert.rejects(
      prepareUpload({ ...options, [field]: "0".repeat(64) }),
      { code: "checksum_mismatch" },
    );
  }
});

test("rejects oversized, empty, missing and non-regular inputs", async (t) => {
  const options = await inputs(t);
  await truncate(options.bundle, MAX_ARTIFACT_BYTES + 1);
  await assert.rejects(prepareUpload(options), { code: "invalid_size" });
  await truncate(options.bundle, 0);
  await assert.rejects(prepareUpload(options), { code: "invalid_size" });
  await assert.rejects(prepareUpload({ ...options, bundle: tmpdir() }), {
    code: "invalid_file",
  });
  await assert.rejects(
    prepareUpload({ ...options, bundle: `${options.bundle}.missing` }),
    { code: "file_unavailable" },
  );
});

test("validates source-map structure without loading external sources", () => {
  const validate = (value) =>
    validateSourceMap(Buffer.from(JSON.stringify(value)));
  validate(sourceMap);
  validate({
    version: 3,
    sections: [{ offset: { line: 0, column: 0 }, map: sourceMap }],
  });
  for (const value of [
    null,
    { ...sourceMap, version: 2 },
    { ...sourceMap, mappings: "*" },
    { ...sourceMap, sourcesContent: [] },
    {
      version: 3,
      sections: [
        {
          offset: { line: 0, column: 0 },
          url: "https://example.com/private.map",
        },
      ],
    },
    {
      version: 3,
      sections: [1, 0].map((line) => ({
        offset: { line, column: 0 },
        map: sourceMap,
      })),
    },
  ]) {
    assert.throws(() => validate(value), { code: "invalid_source_map" });
  }
  assert.throws(() => validateSourceMap(Buffer.from([0xff])), {
    code: "invalid_source_map",
  });
});

test("sends credentials only to API, requires verification, and reuses deterministic idempotency keys", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  const calls = [];
  const mockedFetch = async (url, init) => {
    calls.push({ url: String(url), init });
    assert.equal(init.redirect, "error");
    if (String(url).endsWith("/init")) return targets(prepared);
    if (String(url).endsWith("/complete")) return response(prepared);
    assert.equal(init.headers.authorization, undefined);
    const expected = String(url).endsWith("/bundle")
      ? prepared.bundle
      : prepared.sourceMap;
    assert.deepEqual(Buffer.from(init.body), expected);
    return new Response(null, { status: 200 });
  };
  await upload(prepared, {
    url: "https://api.example",
    token,
    fetch: mockedFetch,
  });
  await upload(prepared, {
    url: "https://api.example",
    token,
    fetch: mockedFetch,
  });
  assert.equal(calls.length, 8);
  assert.equal(calls[0].init.headers.authorization, `Bearer ${token}`);
  assert.equal(
    calls[0].init.headers["idempotency-key"],
    calls[4].init.headers["idempotency-key"],
  );
  assert.equal(
    calls[3].init.headers["idempotency-key"],
    calls[7].init.headers["idempotency-key"],
  );
});

test("rejects all malformed destinations before uploading either artifact", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  const good = {
    kind: "bundle",
    method: "PUT",
    url: "https://artifacts.example/bundle",
    headers: { "content-type": "application/octet-stream" },
  };
  for (const bad of [
    good,
    { ...good, kind: "source_map", url: "http://example.com/map" },
    { ...good, kind: "source_map", headers: { authorization: "unsafe" } },
  ]) {
    let calls = 0;
    await assert.rejects(
      upload(prepared, {
        url: "https://api.example",
        token,
        fetch: async () => {
          calls++;
          return targets(prepared, [good, bad]);
        },
      }),
    );
    assert.equal(calls, 1);
  }
});

test("requires matching manifest and upload ID, verified completion, and bounded JSON responses", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  for (const fetcher of [
    async () => response(prepared, { manifest_sha256: "0".repeat(64) }),
    async () => response(prepared, { upload_id: "../unexpected" }),
    async () => new Response("x".repeat(65 * 1024)),
    async () => new Response("not json"),
    async (url) =>
      String(url).endsWith("/init")
        ? targets(prepared)
        : String(url).endsWith("/complete")
          ? response(prepared, { status: "pending" })
          : new Response(null),
  ])
    await assert.rejects(
      upload(prepared, { url: "https://api.example", token, fetch: fetcher }),
      { code: "invalid_response" },
    );
});

test("maps HTTP failures without exposing response content", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  for (const [status, code] of [
    [401, "unauthorized"],
    [403, "unauthorized"],
    [409, "release_conflict"],
    [413, "artifact_too_large"],
    [422, "artifact_rejected"],
    [429, "rate_limited"],
    [500, "service_unavailable"],
  ]) {
    await assert.rejects(
      upload(prepared, {
        url: "https://api.example",
        token,
        fetch: async () => new Response(`private source ${token}`, { status }),
      }),
      (error) =>
        error.code === code &&
        !error.message.includes(token) &&
        !error.message.includes("private source"),
    );
  }
  await assert.rejects(
    upload(prepared, {
      url: "https://api.example",
      token,
      fetch: async () => {
        throw new Error(token);
      },
    }),
    { code: "network_error" },
  );
});

async function server(t) {
  const releases = new Map();
  const artifacts = new Map();
  const requests = [];
  let loseCompletion = false;
  const service = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const bytes = Buffer.concat(chunks);
    requests.push({ path: req.url, headers: req.headers });
    const json = (status, body) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.url.startsWith("/artifacts/")) {
      assert.equal(req.headers.authorization, undefined);
      artifacts.set(req.url.split("/").at(-1), bytes);
      res.end();
      return;
    }
    if (req.headers.authorization !== `Bearer ${token}`) {
      json(401, { private: token });
      return;
    }
    if (req.url.endsWith("/init")) {
      const { manifest } = JSON.parse(bytes);
      const key = canonicalJson(manifest.release);
      const digest = sha256(canonicalJson(manifest));
      if (releases.has(key) && releases.get(key).digest !== digest) {
        json(409, {});
        return;
      }
      const release = releases.get(key) ?? {
        digest,
        manifest,
        verified: false,
      };
      releases.set(key, release);
      json(200, {
        upload_id: id,
        manifest_sha256: digest,
        status: release.verified ? "verified" : "initialized",
        ...(release.verified
          ? {}
          : {
              artifacts: ["bundle", "source_map"].map((kind) => ({
                kind,
                method: "PUT",
                url: `${origin}/artifacts/${kind}`,
                headers: { "content-type": "application/octet-stream" },
              })),
            }),
      });
      return;
    }
    const release = [...releases.values()].find(
      (item) =>
        req.headers["idempotency-key"] ===
        `source-maps:${item.digest}:complete`,
    );
    assert.ok(release);
    for (const kind of ["bundle", "source_map"]) {
      assert.equal(sha256(artifacts.get(kind)), release.manifest[kind].sha256);
      assert.equal(
        artifacts.get(kind).length,
        release.manifest[kind].byte_size,
      );
    }
    release.verified = true;
    if (loseCompletion) {
      loseCompletion = false;
      req.socket.destroy();
      return;
    }
    json(200, {
      upload_id: id,
      manifest_sha256: release.digest,
      status: "verified",
    });
  });
  await new Promise((resolve, reject) => {
    service.once("error", reject);
    service.listen(0, "127.0.0.1", resolve);
  });
  const origin = `http://127.0.0.1:${service.address().port}`;
  t.after(
    () =>
      new Promise((resolve) => {
        service.close(resolve);
        service.closeAllConnections();
      }),
  );
  return {
    origin,
    requests,
    artifacts,
    loseNextCompletion: () => {
      loseCompletion = true;
    },
  };
}

for (const platform of ["ios", "android"])
  test(`CLI fixture upload, duplicate, mismatch and credential failures on ${platform}`, async (t) => {
    const options = { ...(await inputs(t)), platform };
    const service = await server(t);
    const command = [
      ...args(options),
      "--url",
      service.origin,
      "--allow-localhost",
    ];
    const first = await cli(command, { CRUMB_SOURCE_MAP_TOKEN: token });
    assert.equal(first.code, 0, first.stderr);
    assert.equal(JSON.parse(first.stdout).status, "verified");
    assert.equal(service.artifacts.size, 2);
    const before = service.requests.length;
    const again = await cli(command, { CRUMB_SOURCE_MAP_TOKEN: token });
    assert.equal(again.stdout, first.stdout);
    assert.equal(service.requests.length, before + 1);
    await writeFile(options.bundle, "a different bundle");
    const conflict = await cli(command, { CRUMB_SOURCE_MAP_TOKEN: token });
    assert.equal(conflict.code, 1);
    assert.equal(JSON.parse(conflict.stderr).error.code, "release_conflict");
    const invalid = await cli(command, {
      CRUMB_SOURCE_MAP_TOKEN: "synthetic-wrong-credential",
    });
    assert.equal(invalid.code, 1);
    assert.equal(JSON.parse(invalid.stderr).error.code, "unauthorized");
    assert.ok(!invalid.stderr.includes(token));
  });

test("rerun recovers a lost completion response without retransmitting verified artifacts", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  const service = await server(t);
  service.loseNextCompletion();
  const transport = { url: service.origin, token, allowLocalhost: true };
  await assert.rejects(upload(prepared, transport), { code: "network_error" });
  const count = service.requests.length;
  assert.equal((await upload(prepared, transport)).status, "verified");
  assert.equal(service.requests.length, count + 1);
});

test("CLI dry-run, duplicate options, secret files and errors never print source or credential inputs", async (t) => {
  const options = await inputs(t);
  const dry = await cli([
    ...args(options),
    "--dry-run",
    "--token-file",
    "/does/not/exist",
  ]);
  assert.equal(dry.code, 0, dry.stderr);
  assert.equal(JSON.parse(dry.stdout).status, "dry_run");
  for (const extra of [
    ["--token", token],
    ["--platform", "android"],
    ["--bundle", token],
  ]) {
    const failure = await cli([...args(options), ...extra]);
    assert.equal(failure.code, 1);
    assert.equal(JSON.parse(failure.stderr).error.code, "invalid_arguments");
    assert.ok(!failure.stderr.includes(token));
  }
  const service = await server(t);
  const secretFile = `${options.bundle}.secret`;
  await writeFile(secretFile, `${token}\r\n`, { mode: 0o600 });
  const command = [
    ...args(options),
    "--url",
    service.origin,
    "--allow-localhost",
    "--token-file",
    secretFile,
  ];
  const result = await cli(command);
  assert.equal(result.code, 0, result.stderr);
  assert.ok(!result.stdout.includes(token));
  assert.ok(!result.stdout.includes("synthetic source"));
  const ambiguous = await cli(command, { CRUMB_SOURCE_MAP_TOKEN: token });
  assert.equal(JSON.parse(ambiguous.stderr).error.code, "ambiguous_token");
});

test("rejects HTTP and credential-bearing origins before sending network requests", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  for (const url of [
    "http://api.example",
    "https://user:password@api.example",
    "https://api.example/path",
    "https://api.example?token=secret",
  ]) {
    await assert.rejects(
      upload(prepared, {
        url,
        token,
        fetch: async () => {
          assert.fail("must not send");
        },
      }),
      { code: "invalid_url" },
    );
  }
  await assert.rejects(
    upload(prepared, {
      url: "https://api.example",
      token: "invalid\ncredential",
      fetch: async () => {
        assert.fail("must not send");
      },
    }),
    { code: "invalid_token" },
  );
});

test("real HTTP redirects are rejected and a stalled request times out safely", async (t) => {
  const prepared = await prepareUpload(await inputs(t));
  let redirected = false;
  const service = createServer((req, res) => {
    if (req.url === "/source-maps/v1/uploads/init") {
      res.writeHead(307, { location: "/unexpected" });
      res.end();
    } else {
      redirected = true;
      res.end();
    }
  });
  await new Promise((resolve, reject) => {
    service.once("error", reject);
    service.listen(0, "127.0.0.1", resolve);
  });
  t.after(
    () =>
      new Promise((resolve) => {
        service.close(resolve);
        service.closeAllConnections();
      }),
  );
  const origin = `http://127.0.0.1:${service.address().port}`;
  await assert.rejects(
    upload(prepared, { url: origin, token, allowLocalhost: true }),
    { code: "network_error" },
  );
  assert.equal(redirected, false);
  service.removeAllListeners("request");
  service.on("request", () => {});
  await assert.rejects(
    upload(prepared, {
      url: origin,
      token,
      allowLocalhost: true,
      timeoutMs: 20,
    }),
    { code: "network_error" },
  );
});
