import NativeCrumbReactNative from './NativeCrumbReactNative';
import { clearBreadcrumbs, recordBreadcrumb } from './breadcrumb-buffer';
import type {
  CrumbLogEntry,
  CrumbLogLevel,
  CrumbLogMetadata,
  CrumbLogOptions,
} from './types';

const DEFAULT_LOOKBACK_MS = 60_000;
const DEFAULT_MAXIMUM_ENTRIES = 200;
const DEFAULT_MAXIMUM_BYTES = 65_536;
const MAXIMUM_METADATA_DEPTH = 4;
const MAXIMUM_OBJECT_KEYS = 24;
const MAXIMUM_ARRAY_ITEMS = 24;
const MAXIMUM_STRING_LENGTH = 2_048;
const MAXIMUM_ENTRY_BYTES = 16_384;

interface BufferLimits {
  lookbackMs: number;
  maximumEntries: number;
  maximumBytes: number;
}

type ConsoleMethod = (...data: unknown[]) => void;

let limits: BufferLimits = {
  lookbackMs: DEFAULT_LOOKBACK_MS,
  maximumEntries: DEFAULT_MAXIMUM_ENTRIES,
  maximumBytes: DEFAULT_MAXIMUM_BYTES,
};
let entries: CrumbLogEntry[] = [];
let usedBytes = 0;
let nativeStarted = false;
let originalWarn: ConsoleMethod | undefined;
let originalError: ConsoleMethod | undefined;
let capturedWarn: ConsoleMethod | undefined;
let capturedError: ConsoleMethod | undefined;

export function configureLogBuffer(options: CrumbLogOptions | undefined): void {
  limits = {
    lookbackMs: options?.lookbackMs ?? DEFAULT_LOOKBACK_MS,
    maximumEntries: options?.maximumEntries ?? DEFAULT_MAXIMUM_ENTRIES,
    maximumBytes: options?.maximumBytes ?? DEFAULT_MAXIMUM_BYTES,
  };
  prune(Date.now());
}

export function markNativeStarted(): void {
  nativeStarted = true;
  NativeCrumbReactNative.clearLogs();
  if (!canCollectLogs()) {
    clearBufferedEntries();
    clearBreadcrumbs();
    return;
  }
  for (const entry of entries) {
    NativeCrumbReactNative.addLog(JSON.stringify(entry));
  }
}

export function clearLogs(): void {
  clearBufferedEntries();
  clearBreadcrumbs();
  if (nativeStarted) {
    NativeCrumbReactNative.clearLogs();
  }
}

export function writeLog(
  level: CrumbLogLevel,
  message: string,
  metadata?: CrumbLogMetadata,
  category: CrumbLogEntry['category'] = 'javascript'
): void {
  if (!canCollectLogs()) return;

  const timestampMs = Date.now();
  const metadataText = metadata ? serializeMetadata(metadata) : undefined;
  const entry: CrumbLogEntry = {
    timestampMs,
    level,
    source: 'react-native',
    category,
    message: truncateUtf8(
      metadataText ? `${message}\nmetadata=${metadataText}` : message,
      MAXIMUM_ENTRY_BYTES
    ),
  };
  recordBreadcrumb(timestampMs, category, entry.message);

  const bytes = byteLength(JSON.stringify(entry));
  entries.push(entry);
  usedBytes += bytes;
  prune(timestampMs);

  if (nativeStarted && entries.includes(entry)) {
    NativeCrumbReactNative.addLog(JSON.stringify(entry));
  }
}

export function enableConsoleCapture(): void {
  if (capturedWarn || capturedError) return;

  originalWarn = console.warn;
  originalError = console.error;
  capturedWarn = (...data: unknown[]) => {
    originalWarn?.apply(console, data);
    writeConsoleLog('warning', data);
  };
  capturedError = (...data: unknown[]) => {
    originalError?.apply(console, data);
    writeConsoleLog('error', data);
  };
  console.warn = capturedWarn;
  console.error = capturedError;
}

export function disableConsoleCapture(): void {
  if (capturedWarn && console.warn === capturedWarn && originalWarn) {
    console.warn = originalWarn;
  }
  if (capturedError && console.error === capturedError && originalError) {
    console.error = originalError;
  }
  originalWarn = undefined;
  originalError = undefined;
  capturedWarn = undefined;
  capturedError = undefined;
}

function writeConsoleLog(level: 'warning' | 'error', data: unknown[]): void {
  if (!canCollectLogs()) return;

  const suppliedError = data.find(
    (value): value is Error => value instanceof Error
  );
  const rendered = data.map(renderConsoleValue).join(' ');
  const stack = suppliedError?.stack ?? new Error(`console.${level}`).stack;
  const message = stack ? `${rendered}\n${stack}` : rendered;
  writeLog(level, message, undefined, 'console');
}

function canCollectLogs(): boolean {
  return !nativeStarted || NativeCrumbReactNative.canCollectLogs();
}

function clearBufferedEntries(): void {
  entries = [];
  usedBytes = 0;
}

function renderConsoleValue(value: unknown): string {
  if (value instanceof Error) return value.stack ?? value.message;
  if (typeof value === 'string') return value;
  if (
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    typeof value === 'bigint'
  ) {
    return String(value);
  }
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  return serializeMetadata({ value });
}

function serializeMetadata(metadata: CrumbLogMetadata): string {
  const seen = new WeakSet<object>();
  const bounded = boundValue(metadata, 0, seen);
  try {
    return truncateUtf8(JSON.stringify(bounded), MAXIMUM_ENTRY_BYTES / 2);
  } catch {
    return '"[Unserializable metadata]"';
  }
}

function boundValue(
  value: unknown,
  depth: number,
  seen: WeakSet<object>
): unknown {
  if (value instanceof Error) {
    return {
      name: value.name,
      message: truncateString(value.message),
      stack: value.stack ? truncateString(value.stack) : undefined,
    };
  }
  if (typeof value === 'string') return truncateString(value);
  if (
    value === null ||
    typeof value === 'number' ||
    typeof value === 'boolean'
  ) {
    return value;
  }
  if (typeof value === 'bigint') return String(value);
  if (typeof value === 'undefined') return '[Undefined]';
  if (typeof value === 'function') return '[Function]';
  if (typeof value === 'symbol') return String(value);
  if (depth >= MAXIMUM_METADATA_DEPTH) return '[Max depth]';
  if (typeof value !== 'object') return String(value);
  if (seen.has(value)) return '[Circular]';

  seen.add(value);
  if (Array.isArray(value)) {
    const result = value
      .slice(0, MAXIMUM_ARRAY_ITEMS)
      .map((item) => boundValue(item, depth + 1, seen));
    seen.delete(value);
    return result;
  }

  const result: Record<string, unknown> = {};
  for (const key of Object.keys(value).slice(0, MAXIMUM_OBJECT_KEYS)) {
    result[truncateString(key)] = boundValue(
      (value as Record<string, unknown>)[key],
      depth + 1,
      seen
    );
  }
  seen.delete(value);
  return result;
}

function prune(now: number): void {
  const earliest = now - limits.lookbackMs;
  while (entries[0] && entries[0].timestampMs < earliest) {
    removeOldest();
  }
  while (
    entries.length > limits.maximumEntries ||
    usedBytes > limits.maximumBytes
  ) {
    removeOldest();
  }
}

function removeOldest(): void {
  const removed = entries.shift();
  if (!removed) return;
  usedBytes -= byteLength(JSON.stringify(removed));
}

function truncateString(value: string): string {
  return value.length <= MAXIMUM_STRING_LENGTH
    ? value
    : `${value.slice(0, MAXIMUM_STRING_LENGTH)}…`;
}

function truncateUtf8(value: string, maximumBytes: number): string {
  if (byteLength(value) <= maximumBytes) return value;

  let low = 0;
  let high = value.length;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (byteLength(value.slice(0, middle)) <= maximumBytes - 3) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return `${value.slice(0, low)}…`;
}

function byteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) index += 1;
      bytes += 4;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
