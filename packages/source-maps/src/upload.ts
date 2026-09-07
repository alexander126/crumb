import {
  canonicalJson,
  identity,
  MAX_ARTIFACT_BYTES,
  MAX_RESPONSE_BYTES,
  readBoundedFile,
  record,
  safeUrl,
  sha256,
  UploadError,
  validateSourceMap,
  verifyExpectedHash,
} from "./validation.js";

export interface UploadOptions {
  readonly platform: string | undefined;
  readonly appVersion: string | undefined;
  readonly nativeBuild: string | undefined;
  readonly bundleVersion: string | undefined;
  readonly bundle: string;
  readonly sourceMap: string;
  readonly expectedBundleSha256?: string | undefined;
  readonly expectedSourceMapSha256?: string | undefined;
}

export interface PreparedUpload {
  readonly manifest: {
    readonly schema_version: "1.0";
    readonly release: {
      readonly platform: "ios" | "android";
      readonly app_version: string;
      readonly native_build: string;
      readonly js_bundle_version: string;
    };
    readonly bundle: { readonly byte_size: number; readonly sha256: string };
    readonly source_map: {
      readonly byte_size: number;
      readonly sha256: string;
    };
  };
  readonly manifestSha256: string;
  readonly bundle: Buffer;
  readonly sourceMap: Buffer;
}

export async function prepareUpload(
  options: UploadOptions,
): Promise<PreparedUpload> {
  if (options.platform !== "ios" && options.platform !== "android")
    throw new UploadError(
      "invalid_platform",
      "The platform must be ios or android, including for React Native.",
    );
  const release = {
    platform: options.platform,
    app_version: identity(options.appVersion, 64),
    native_build: identity(options.nativeBuild, 64),
    js_bundle_version: identity(options.bundleVersion, 128),
  };
  const bundle = await readBoundedFile(options.bundle, MAX_ARTIFACT_BYTES);
  const sourceMap = await readBoundedFile(
    options.sourceMap,
    MAX_ARTIFACT_BYTES,
  );
  validateSourceMap(sourceMap);
  const manifest: PreparedUpload["manifest"] = {
    schema_version: "1.0",
    release: { ...release, platform: options.platform },
    bundle: {
      byte_size: bundle.length,
      sha256: verifyExpectedHash(bundle, options.expectedBundleSha256),
    },
    source_map: {
      byte_size: sourceMap.length,
      sha256: verifyExpectedHash(sourceMap, options.expectedSourceMapSha256),
    },
  };
  return {
    manifest,
    manifestSha256: sha256(canonicalJson(manifest)),
    bundle,
    sourceMap,
  };
}

export interface TransportOptions {
  readonly url: string;
  readonly token: string;
  readonly allowLocalhost?: boolean;
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
}

interface UploadTarget {
  readonly kind: "bundle" | "source_map";
  readonly url: string;
}
const UUID =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;

export async function upload(
  prepared: PreparedUpload,
  options: TransportOptions,
): Promise<{
  readonly ok: true;
  readonly status: "verified";
  readonly upload_id: string;
  readonly manifest_sha256: string;
}> {
  const base = safeUrl(options.url, options.allowLocalhost === true, true);
  if (!/^[\x21-\x7e]{16,4096}$/.test(options.token))
    throw new UploadError(
      "invalid_token",
      "Supply a valid source-map upload credential using the environment or a secret file.",
    );
  const request = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 60_000;

  async function send(url: string | URL, init: RequestInit): Promise<Response> {
    try {
      return await request(url, {
        ...init,
        redirect: "error",
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw new UploadError(
        "network_error",
        "The upload request did not complete. Check connectivity and rerun the same command to resume safely.",
      );
    }
  }

  async function api(
    path: string,
    body: unknown,
    operation: "init" | "complete",
  ): Promise<unknown> {
    const response = await send(new URL(path, base), {
      method: "POST",
      headers: {
        authorization: `Bearer ${options.token}`,
        "content-type": "application/json",
        "idempotency-key": `source-maps:${prepared.manifestSha256}:${operation}`,
      },
      body: canonicalJson(body),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw httpError(response.status);
    }
    const result = await readJson(response);
    if (
      !record(result) ||
      result.manifest_sha256 !== prepared.manifestSha256 ||
      typeof result.upload_id !== "string" ||
      !UUID.test(result.upload_id)
    )
      throw protocolError();
    return result;
  }

  const initialized = await api(
    "/source-maps/v1/uploads/init",
    { manifest: prepared.manifest },
    "init",
  );
  if (!record(initialized) || typeof initialized.upload_id !== "string")
    throw protocolError();
  const uploadId = initialized.upload_id;
  if (initialized.status === "verified")
    return {
      ok: true,
      status: "verified",
      upload_id: uploadId,
      manifest_sha256: prepared.manifestSha256,
    };
  if (
    initialized.status !== "initialized" ||
    !Array.isArray(initialized.artifacts) ||
    initialized.artifacts.length !== 2
  )
    throw protocolError();
  const targets: UploadTarget[] = [];
  for (const target of initialized.artifacts) {
    if (
      !record(target) ||
      (target.kind !== "bundle" && target.kind !== "source_map") ||
      target.method !== "PUT" ||
      typeof target.url !== "string" ||
      !record(target.headers) ||
      Object.keys(target.headers).length !== 1 ||
      target.headers["content-type"] !== "application/octet-stream"
    )
      throw protocolError();
    safeUrl(target.url, options.allowLocalhost === true);
    if (targets.some((existing) => existing.kind === target.kind))
      throw protocolError();
    targets.push({ kind: target.kind, url: target.url });
  }
  // Validate every destination before sending either private artifact. Credentials
  // are sent only to the API, never to a signed upload target or redirect.
  for (const target of targets) {
    const bytes =
      target.kind === "bundle" ? prepared.bundle : prepared.sourceMap;
    const response = await send(target.url, {
      method: "PUT",
      headers: { "content-type": "application/octet-stream" },
      body: new Uint8Array(bytes),
    });
    await response.body?.cancel();
    if (!response.ok)
      throw new UploadError(
        "artifact_upload_failed",
        "An artifact upload failed. Rerun the same command to obtain fresh upload locations and resume.",
      );
  }
  const completed = await api(
    `/source-maps/v1/uploads/${uploadId}/complete`,
    {},
    "complete",
  );
  if (
    !record(completed) ||
    completed.status !== "verified" ||
    completed.upload_id !== uploadId
  )
    throw protocolError();
  return {
    ok: true,
    status: "verified",
    upload_id: uploadId,
    manifest_sha256: prepared.manifestSha256,
  };
}

async function readJson(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw protocolError();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_RESPONSE_BYTES) throw protocolError();
      chunks.push(value);
    }
    return JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
    );
  } catch {
    throw protocolError();
  } finally {
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
}

function protocolError(): UploadError {
  return new UploadError(
    "invalid_response",
    "The upload service returned an invalid response. No verification is assumed; retry with a compatible service.",
  );
}
function httpError(status: number): UploadError {
  if (status === 401 || status === 403)
    return new UploadError(
      "unauthorized",
      "The upload credential is invalid, expired or not permitted for this project.",
    );
  if (status === 409)
    return new UploadError(
      "release_conflict",
      "This release identity already has different artifacts. Use the matching build or a new bundle version.",
    );
  if (status === 413)
    return new UploadError(
      "artifact_too_large",
      "The release artifacts exceed the service limits.",
    );
  if (status === 422)
    return new UploadError(
      "artifact_rejected",
      "The release metadata or artifact verification failed. Check the build identity and checksums.",
    );
  if (status === 429)
    return new UploadError(
      "rate_limited",
      "Upload requests are rate limited. Wait before retrying the same command.",
    );
  return new UploadError(
    "service_unavailable",
    "The upload service could not finish the request. Retry the same command later.",
  );
}
