import { createHash } from "node:crypto";
import { open } from "node:fs/promises";
import { constants } from "node:fs";

export const MAX_ARTIFACT_BYTES = 25 * 1024 * 1024;
export const MAX_RESPONSE_BYTES = 64 * 1024;

export class UploadError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function sha256(value: Uint8Array | string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (record(value))
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  const result = JSON.stringify(value);
  if (result === undefined)
    throw new UploadError(
      "invalid_manifest",
      "The release manifest is invalid.",
    );
  return result;
}

export function identity(value: string | undefined, maximum: number): string {
  if (
    !value ||
    value.length > maximum ||
    !/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
  ) {
    throw new UploadError(
      "invalid_release",
      "Supply platform, app version, native build and a unique bundle version using letters, digits, dot, underscore, plus or hyphen.",
    );
  }
  return value;
}

/** Read only a bounded regular file, even if it changes or grows after stat. */
export async function readBoundedFile(
  path: string,
  maximum: number,
): Promise<Buffer> {
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
    const info = await file.stat();
    if (!info.isFile())
      throw new UploadError(
        "invalid_file",
        "Upload inputs must be regular files.",
      );
    if (info.size === 0 || info.size > maximum)
      throw new UploadError(
        "invalid_size",
        "An input is empty or exceeds its size limit.",
      );
    const buffer = Buffer.alloc(Math.min(info.size + 1, maximum + 1));
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await file.read(
        buffer,
        offset,
        buffer.length - offset,
        null,
      );
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    if (offset !== info.size)
      throw new UploadError(
        "file_changed",
        "An input changed while being read. Finish the build and retry.",
      );
    return buffer.subarray(0, offset);
  } catch (error) {
    if (error instanceof UploadError) throw error;
    throw new UploadError(
      "file_unavailable",
      "An input file could not be read. Check its path and permissions.",
    );
  } finally {
    await file?.close();
  }
}

export function verifyExpectedHash(
  bytes: Buffer,
  expected: string | undefined,
): string {
  const actual = sha256(bytes);
  if (
    expected !== undefined &&
    (!/^[a-f0-9]{64}$/.test(expected) || expected !== actual)
  ) {
    throw new UploadError(
      "checksum_mismatch",
      "An input does not match its expected SHA-256. Use the artifacts from the same release build.",
    );
  }
  return actual;
}

/** Check the v3 JSON structure without executing bundles or resolving source URLs. */
export function validateSourceMap(bytes: Buffer): void {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new UploadError(
      "invalid_source_map",
      "The source map must be valid UTF-8 JSON.",
    );
  }
  let count = 0;
  function validate(map: unknown, depth: number): void {
    if (++count > 1024 || depth > 8 || !record(map) || map.version !== 3)
      throw invalidMap();
    if (map.file !== undefined && typeof map.file !== "string")
      throw invalidMap();
    if (map.sourceRoot !== undefined && typeof map.sourceRoot !== "string")
      throw invalidMap();
    if (map.sections !== undefined) {
      if (
        !Array.isArray(map.sections) ||
        map.sections.length === 0 ||
        map.mappings !== undefined ||
        map.sources !== undefined
      )
        throw invalidMap();
      let previousLine = -1;
      let previousColumn = -1;
      for (const section of map.sections) {
        if (
          !record(section) ||
          section.url !== undefined ||
          !record(section.offset)
        )
          throw invalidMap();
        const { line, column } = section.offset;
        if (
          typeof line !== "number" ||
          typeof column !== "number" ||
          !Number.isSafeInteger(line) ||
          !Number.isSafeInteger(column) ||
          line < 0 ||
          column < 0
        )
          throw invalidMap();
        if (
          line < previousLine ||
          (line === previousLine && column <= previousColumn)
        )
          throw invalidMap();
        previousLine = line;
        previousColumn = column;
        validate(section.map, depth + 1);
      }
      return;
    }
    if (
      typeof map.mappings !== "string" ||
      !/^[A-Za-z0-9+/;,]*$/.test(map.mappings) ||
      !Array.isArray(map.sources) ||
      !map.sources.every((source) => typeof source === "string")
    )
      throw invalidMap();
    if (
      map.names !== undefined &&
      (!Array.isArray(map.names) ||
        !map.names.every((name) => typeof name === "string"))
    )
      throw invalidMap();
    if (
      map.sourcesContent !== undefined &&
      (!Array.isArray(map.sourcesContent) ||
        map.sourcesContent.length !== map.sources.length ||
        !map.sourcesContent.every(
          (source) => source === null || typeof source === "string",
        ))
    )
      throw invalidMap();
  }
  validate(value, 0);
}

function invalidMap(): UploadError {
  return new UploadError(
    "invalid_source_map",
    "Use a version 3 source map with inline sections only. Check its sources, mappings and offsets.",
  );
}

export function safeUrl(input: string, allowLocal: boolean, base = false): URL {
  let url;
  try {
    url = new URL(input);
  } catch {
    throw invalidUrl();
  }
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" &&
      !(allowLocal && loopback && url.protocol === "http:")) ||
    url.username ||
    url.password ||
    url.hash ||
    (base && (url.search || url.pathname !== "/"))
  )
    throw invalidUrl();
  return url;
}

function invalidUrl(): UploadError {
  return new UploadError(
    "invalid_url",
    "Use an HTTPS API origin without credentials, path, query or fragment. HTTP loopback requires --allow-localhost.",
  );
}
