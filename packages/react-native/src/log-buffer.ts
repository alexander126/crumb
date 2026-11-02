import NativeCrumbReactNative from './NativeCrumbReactNative';
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
let captureEnabled = false;
let installedWarn: ConsoleMethod | undefined;
let installedError: ConsoleMethod | undefined;
let restoreWarn: ConsoleMethod | undefined;
let restoreError: ConsoleMethod | undefined;
/** Set while one of our wrappers is forwarding, so a chain that contains more
 *  than one of them records a single entry per call. */
let forwarding = false;
const crumbWrappers = new WeakSet<ConsoleMethod>();

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
    return;
  }
  for (const entry of entries) {
    NativeCrumbReactNative.addLog(JSON.stringify(entry));
  }
}

export function clearLogs(): void {
  clearBufferedEntries();
  if (nativeStarted) {
    NativeCrumbReactNative.clearLogs();
  }
}

export function snapshotLogEntries(): readonly CrumbLogEntry[] {
  if (!canCollectLogs()) {
    clearBufferedEntries();
    return [];
  }
  prune(Date.now());
  return entries.slice();
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

  const bytes = byteLength(JSON.stringify(entry));
  entries.push(entry);
  usedBytes += bytes;
  prune(timestampMs);

  if (nativeStarted && entries.includes(entry)) {
    NativeCrumbReactNative.addLog(JSON.stringify(entry));
  }
}

export function enableConsoleCapture(): void {
  // Arming first means a wrapper that is still installed from an earlier cycle
  // starts recording again without being wrapped a second time.
  captureEnabled = true;

  if (!crumbWrappers.has(console.warn)) {
    restoreWarn = console.warn;
    installedWarn = wrapConsoleMethod('warning', console.warn);
    console.warn = installedWarn;
  }
  if (!crumbWrappers.has(console.error)) {
    restoreError = console.error;
    installedError = wrapConsoleMethod('error', console.error);
    console.error = installedError;
  }
}

export function disableConsoleCapture(): void {
  // A wrapper we cannot uninstall - because another library wrapped on top of
  // it - stays installed and becomes a pass-through. It must never be left
  // unable to reach what it wrapped.
  captureEnabled = false;

  if (installedWarn && console.warn === installedWarn && restoreWarn) {
    console.warn = restoreWarn;
    crumbWrappers.delete(installedWarn);
    installedWarn = undefined;
    restoreWarn = undefined;
  }
  if (installedError && console.error === installedError && restoreError) {
    console.error = restoreError;
    crumbWrappers.delete(installedError);
    installedError = undefined;
    restoreError = undefined;
  }
}

function wrapConsoleMethod(
  level: 'warning' | 'error',
  wrapped: ConsoleMethod
): ConsoleMethod {
  // `wrapped` is captured immutably: the wrapper can always reach the function
  // it was installed over, whatever happens to module state afterwards.
  const wrapper: ConsoleMethod = (...data: unknown[]) => {
    if (forwarding) {
      wrapped.apply(console, data);
      return;
    }
    forwarding = true;
    try {
      wrapped.apply(console, data);
    } finally {
      forwarding = false;
    }
    if (!captureEnabled) return;
    try {
      writeConsoleLog(level, data);
    } catch {
      // Capturing a log must never make the host's console call throw.
    }
  };
  crumbWrappers.add(wrapper);
  return wrapper;
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
  try {
    // Traversal belongs inside the boundary: it reads properties, so a throwing
    // getter or proxy trap would otherwise escape through writeLog and out of
    // the host's own console.error call.
    const bounded = boundValue(metadata, 0, new WeakSet<object>());
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
  for (const key of ownKeys(value).slice(0, MAXIMUM_OBJECT_KEYS)) {
    result[truncateString(key)] = readProperty(value, key, depth, seen);
  }
  seen.delete(value);
  return result;
}

function ownKeys(value: object): string[] {
  try {
    return Object.keys(value);
  } catch {
    // A proxy can throw from ownKeys itself.
    return [];
  }
}

/** One unreadable property degrades to a placeholder; the rest is still kept. */
function readProperty(
  value: object,
  key: string,
  depth: number,
  seen: WeakSet<object>
): unknown {
  let read: unknown;
  try {
    read = (value as Record<string, unknown>)[key];
  } catch {
    return '[Unreadable]';
  }
  try {
    return boundValue(read, depth + 1, seen);
  } catch {
    return '[Unreadable]';
  }
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
