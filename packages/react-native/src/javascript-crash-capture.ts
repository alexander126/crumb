import NativeCrumbReactNative from './NativeCrumbReactNative';
import { snapshotLogEntries } from './log-buffer';
import type {
  CrumbConfiguration,
  CrumbJavaScriptCrashCaptureOptions,
  CrumbRelease,
} from './types';
import type { CrumbReactNative } from './CrumbReactNative.nitro';

declare const require: ((moduleName: string) => unknown) | undefined;
declare const __DEV__: boolean | undefined;

const DEFAULT_MAXIMUM_BREADCRUMBS = 32;
const DEFAULT_MAXIMUM_BREADCRUMB_BYTES = 16_384;
const MAXIMUM_BREADCRUMB_MESSAGE_BYTES = 2_048;
const MAXIMUM_CRASH_TYPE_BYTES = 128;
const MAXIMUM_CRASH_MESSAGE_BYTES = 4_000;
const MAXIMUM_CRASH_STACK_BYTES = 16_384;
const MAXIMUM_CONTEXT_VALUE_BYTES = 512;
const MAXIMUM_CONTEXT_BYTES = 8_192;
const MAXIMUM_HANDOFF_RECORD_BYTES = 32_768;
const DEDUPLICATION_WINDOW_MS = 10_000;

type GlobalErrorHandler = (error: unknown, isFatal?: boolean) => unknown;
type UnhandledRejectionHandler = (
  event: UnhandledRejectionEventLike
) => unknown;

interface ErrorUtilsLike {
  getGlobalHandler: () => GlobalErrorHandler;
  setGlobalHandler: (handler: GlobalErrorHandler) => void;
}

interface UnhandledRejectionEventLike {
  reason: unknown;
  promise?: unknown;
}

interface ProcessLike {
  on?: (event: string, listener: (...args: unknown[]) => void) => unknown;
  removeListener?: (
    event: string,
    listener: (...args: unknown[]) => void
  ) => unknown;
}

interface ReactNativeExceptionsManagerLike {
  handleException: (error: unknown, isFatal: boolean) => unknown;
}

interface HermesInternalLike {
  hasPromise?: () => boolean;
  enablePromiseRejectionTracker?: (options: {
    allRejections: boolean;
    onUnhandled: (id: number, rejection?: unknown) => void;
    onHandled: (id: number) => void;
  }) => void;
}

interface GlobalObjectLike {
  ErrorUtils?: ErrorUtilsLike;
  onunhandledrejection?: UnhandledRejectionHandler;
  addEventListener?: (
    event: string,
    handler: UnhandledRejectionHandler
  ) => void;
  removeEventListener?: (
    event: string,
    handler: UnhandledRejectionHandler
  ) => void;
  process?: ProcessLike;
  HermesInternal?: HermesInternalLike;
}

interface CrashCaptureState {
  native: Pick<
    CrumbReactNative,
    'recordJavaScriptCrash' | 'recoverJavaScriptCrashes'
  >;
  release?: CrumbRelease;
  context: Readonly<Record<string, string>>;
  maximumBreadcrumbs: number;
  maximumBreadcrumbBytes: number;
  configured: boolean;
  errorUtils?: {
    target: ErrorUtilsLike;
    previous: GlobalErrorHandler;
    wrapper: GlobalErrorHandler;
  };
  property?: {
    target: GlobalObjectLike;
    previous?: UnhandledRejectionHandler;
    wrapper: UnhandledRejectionHandler;
  };
  eventTarget?: {
    target: GlobalObjectLike;
    wrapper: UnhandledRejectionHandler;
  };
  process?: {
    target: ProcessLike;
    wrapper: (...args: unknown[]) => void;
  };
  reactNativeExceptionsManager?: {
    target: ReactNativeExceptionsManagerLike;
    previous: ReactNativeExceptionsManagerLike['handleException'];
    wrapper: ReactNativeExceptionsManagerLike['handleException'];
  };
  fingerprints: Map<string, number>;
}

const globalObject = globalThis as unknown as GlobalObjectLike;

let state: CrashCaptureState = emptyState();

export function configureJavaScriptCrashCapture(
  options: CrumbJavaScriptCrashCaptureOptions | undefined,
  configuration: CrumbConfiguration,
  native: CrashCaptureState['native'] = NativeCrumbReactNative
): void {
  if (!options?.enabled) {
    disableJavaScriptCrashCapture();
    return;
  }

  if (state.configured) {
    state.release = configuration.release;
    state.context = allowlistedContext(configuration);
    state.maximumBreadcrumbs =
      options.maximumBreadcrumbs ?? DEFAULT_MAXIMUM_BREADCRUMBS;
    state.maximumBreadcrumbBytes =
      options.maximumBreadcrumbBytes ?? DEFAULT_MAXIMUM_BREADCRUMB_BYTES;
    return;
  }

  state = {
    ...emptyState(),
    native,
    release: configuration.release,
    context: allowlistedContext(configuration),
    maximumBreadcrumbs:
      options.maximumBreadcrumbs ?? DEFAULT_MAXIMUM_BREADCRUMBS,
    maximumBreadcrumbBytes:
      options.maximumBreadcrumbBytes ?? DEFAULT_MAXIMUM_BREADCRUMB_BYTES,
    configured: true,
    fingerprints: new Map(),
  };

  installErrorUtilsHandler();
  installReactNativeExceptionsManagerHandler();
  installUnhandledRejectionHandler();
  installHermesPromiseRejectionTracker();
}

export async function recoverJavaScriptCrashes(): Promise<void> {
  if (!state.configured) return;
  try {
    await state.native.recoverJavaScriptCrashes();
  } catch {
    // Crash recovery must never make application startup fail.
  }
}

export function disableJavaScriptCrashCapture(): void {
  restoreErrorUtilsHandler();
  restoreReactNativeExceptionsManagerHandler();
  restoreUnhandledRejectionHandler();
  state = emptyState();
}

/** Used by the deterministic adapter tests to release process-global handlers. */
export function resetJavaScriptCrashCaptureForTesting(): void {
  disableJavaScriptCrashCapture();
}

function installErrorUtilsHandler(): void {
  const errorUtils = globalObject.ErrorUtils;
  if (
    !errorUtils ||
    typeof errorUtils.getGlobalHandler !== 'function' ||
    typeof errorUtils.setGlobalHandler !== 'function'
  ) {
    return;
  }

  let previous: GlobalErrorHandler;
  try {
    previous = errorUtils.getGlobalHandler();
  } catch {
    return;
  }
  if (typeof previous !== 'function') return;

  const wrapper: GlobalErrorHandler = (error, isFatal) => {
    if (isFatal) captureFailure('exception', error, true);
    else if (isUnhandledRejectionFailure(error)) {
      captureFailure('unhandled_rejection', rejectionReason(error), false);
    }
    return previous(error, isFatal);
  };
  try {
    errorUtils.setGlobalHandler(wrapper);
    state.errorUtils = { target: errorUtils, previous, wrapper };
  } catch {
    // A host-owned handler remains authoritative if its setter rejects us.
  }
}

function installReactNativeExceptionsManagerHandler(): void {
  if (typeof require !== 'function') return;

  let moduleValue: unknown;
  try {
    // React Native does not expose its promise tracker through a public API.
    // This optional bridge preserves the existing ExceptionsManager chain.
    // eslint-disable-next-line @react-native/no-deep-imports
    moduleValue = require('react-native/Libraries/Core/ExceptionsManager');
  } catch {
    return;
  }

  const moduleObject = asObject(moduleValue);
  const targetValue = moduleObject?.default ?? moduleValue;
  const targetObject = asObject(targetValue);
  if (!targetObject || typeof targetObject.handleException !== 'function') {
    return;
  }

  const target = targetObject as unknown as ReactNativeExceptionsManagerLike;
  const previous = target.handleException;
  const wrapper: ReactNativeExceptionsManagerLike['handleException'] = (
    error,
    isFatal
  ) => {
    if (!isFatal && isUnhandledRejectionFailure(error)) {
      captureFailure('unhandled_rejection', rejectionReason(error), false);
    }
    return previous.call(target, error, isFatal);
  };
  try {
    target.handleException = wrapper;
    state.reactNativeExceptionsManager = { target, previous, wrapper };
  } catch {
    // A runtime with an immutable module surface keeps the existing handler.
  }
}

function installUnhandledRejectionHandler(): void {
  const previous = globalObject.onunhandledrejection;
  const wrapper: UnhandledRejectionHandler = (event) => {
    captureFailure('unhandled_rejection', event?.reason, false);
    return previous?.call(globalObject, event);
  };
  try {
    // React Native does not consistently predeclare this browser-compatible
    // hook. Defining it only while opted in gives runtimes that dispatch the
    // standard event a stable handoff without touching disabled mode.
    globalObject.onunhandledrejection = wrapper;
    state.property = { target: globalObject, previous, wrapper };
  } catch {
    // Some runtimes expose a read-only event property; use their fallback.
  }
  if (
    typeof globalObject.addEventListener === 'function' &&
    typeof globalObject.removeEventListener === 'function'
  ) {
    const eventWrapper: UnhandledRejectionHandler = (event) => {
      captureFailure('unhandled_rejection', event?.reason, false);
    };
    try {
      globalObject.addEventListener('unhandledrejection', eventWrapper);
      state.eventTarget = { target: globalObject, wrapper: eventWrapper };
    } catch {
      // Continue to the process fallback when available.
    }
  }

  const process = globalObject.process;
  if (
    !process ||
    typeof process.on !== 'function' ||
    typeof process.removeListener !== 'function'
  ) {
    return;
  }
  const processWrapper = (...args: unknown[]) => {
    captureFailure('unhandled_rejection', args[0], false);
  };
  try {
    process.on('unhandledRejection', processWrapper);
    state.process = { target: process, wrapper: processWrapper };
  } catch {
    // A runtime without a usable rejection hook remains unsupported safely.
  }
}

function installHermesPromiseRejectionTracker(): void {
  // React Native and Expo already install their Hermes tracker in development.
  // Release builds leave it disabled, which is the gap Crumb needs to fill.
  if (typeof __DEV__ !== 'undefined' && __DEV__) return;

  const hermes = globalObject.HermesInternal;
  if (
    !hermes?.hasPromise?.() ||
    typeof hermes.enablePromiseRejectionTracker !== 'function'
  ) {
    return;
  }

  const exceptionsManager = state.reactNativeExceptionsManager?.target;
  const errorUtils = state.errorUtils?.target;

  try {
    hermes.enablePromiseRejectionTracker({
      allRejections: true,
      onUnhandled: (id, rejection) => {
        captureFailure('unhandled_rejection', rejection, false);

        const error = unhandledRejectionError(id, rejection);
        if (errorUtils) {
          errorUtils.getGlobalHandler()(error, false);
          return;
        }
        exceptionsManager?.handleException(error, false);
      },
      onHandled: (id) => {
        console.warn(
          `Promise rejection handled (id: ${id}); the earlier unhandled-rejection record may be ignored.`
        );
      },
    });
  } catch {
    // Runtimes without a usable Hermes tracker keep the other handlers.
  }
}

function unhandledRejectionError(id: number, rejection: unknown): Error {
  const normalized = normalizeFailure(rejection);
  const prefix = `Uncaught (in promise, id: ${id})`;
  const error = new Error(`${prefix}: ${normalized.message}`);
  (error as Error & { cause?: unknown }).cause = rejection;
  if (normalized.stack) error.stack = `${prefix} ${normalized.stack}`;
  return error;
}

function restoreErrorUtilsHandler(): void {
  const installed = state.errorUtils;
  if (!installed) return;
  try {
    if (installed.target.getGlobalHandler() === installed.wrapper) {
      installed.target.setGlobalHandler(installed.previous);
    }
  } catch {
    // Never replace a host handler that became unavailable during teardown.
  }
}

function restoreReactNativeExceptionsManagerHandler(): void {
  const installed = state.reactNativeExceptionsManager;
  if (!installed) return;
  try {
    if (installed.target.handleException === installed.wrapper) {
      installed.target.handleException = installed.previous;
    }
  } catch {
    // Never replace a host handler that became unavailable during teardown.
  }
}

function restoreUnhandledRejectionHandler(): void {
  const property = state.property;
  if (property) {
    try {
      if (property.target.onunhandledrejection === property.wrapper) {
        if (property.previous === undefined) {
          delete property.target.onunhandledrejection;
        } else {
          property.target.onunhandledrejection = property.previous;
        }
      }
    } catch {
      // Leave a host replacement untouched.
    }
  }

  const eventTarget = state.eventTarget;
  if (eventTarget) {
    try {
      eventTarget.target.removeEventListener?.(
        'unhandledrejection',
        eventTarget.wrapper
      );
    } catch {
      // Teardown is best effort and never affects the application.
    }
  }

  const process = state.process;
  if (process) {
    try {
      process.target.removeListener?.('unhandledRejection', process.wrapper);
    } catch {
      // Teardown is best effort and never affects the application.
    }
  }
}

function isUnhandledRejectionFailure(value: unknown): boolean {
  const message = readStringProperty(value, 'message');
  return (
    message?.startsWith('Uncaught (in promise') === true ||
    message?.startsWith('Possible Unhandled Promise Rejection') === true
  );
}

function rejectionReason(value: unknown): unknown {
  if (
    (typeof value !== 'object' && typeof value !== 'function') ||
    value === null
  ) {
    return value;
  }
  try {
    if ('cause' in value) {
      return (value as Record<string, unknown>).cause;
    }
  } catch {
    // Fall back to the wrapper when its cause is inaccessible.
  }
  return value;
}

function asObject(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

function captureFailure(
  kind: 'exception' | 'unhandled_rejection',
  reason: unknown,
  isFatal: boolean
): void {
  if (!state.configured) return;
  try {
    const normalized = normalizeFailure(reason);
    const fingerprint = fingerprintFor(normalized);
    const now = Date.now();
    pruneFingerprints(now);
    const previous = state.fingerprints.get(fingerprint);
    if (previous !== undefined && now - previous <= DEDUPLICATION_WINDOW_MS) {
      return;
    }
    state.fingerprints.set(fingerprint, now);

    const record: Record<string, unknown> = {
      schema_version: '1.0',
      record_id: makeRecordId(),
      fingerprint,
      source: 'javascript',
      kind,
      type: normalized.type,
      message: normalized.message,
      occurred_at: new Date(now).toISOString(),
      release: state.release
        ? {
            ...(state.release.appVersion
              ? { app_version: state.release.appVersion }
              : {}),
            ...(state.release.nativeBuild
              ? { native_build: state.release.nativeBuild }
              : {}),
            ...(state.release.bundleVersion
              ? { bundle_version: state.release.bundleVersion }
              : {}),
          }
        : undefined,
      breadcrumbs: [],
      context: state.context,
      is_fatal: isFatal,
      native_termination_wrapper_observed: false,
    };
    if (normalized.stack) record.stack = normalized.stack;
    record.breadcrumbs = captureBreadcrumbsWithinRecordBudget(record);
    state.native.recordJavaScriptCrash(JSON.stringify(record));
  } catch {
    // The original host handler must still run if local capture or persistence fails.
  }
}

function normalizeFailure(reason: unknown): {
  type: string;
  message: string;
  stack?: string;
} {
  const type =
    readStringProperty(reason, 'name') ??
    (reason instanceof Error
      ? 'Error'
      : reason === null
        ? 'null'
        : typeof reason);
  const message =
    readStringProperty(reason, 'message') ??
    (typeof reason === 'string' ? reason : safeRender(reason));
  const stack = readStringProperty(reason, 'stack');
  return {
    type: sanitizeText(type, MAXIMUM_CRASH_TYPE_BYTES),
    message: sanitizeText(
      message || 'JavaScript failure',
      MAXIMUM_CRASH_MESSAGE_BYTES
    ),
    ...(stack
      ? { stack: sanitizeText(stack, MAXIMUM_CRASH_STACK_BYTES, true) }
      : {}),
  };
}

function readStringProperty(
  value: unknown,
  property: string
): string | undefined {
  if (
    (typeof value !== 'object' && typeof value !== 'function') ||
    value === null
  ) {
    return undefined;
  }
  try {
    const candidate = (value as Record<string, unknown>)[property];
    return typeof candidate === 'string' ? candidate : undefined;
  } catch {
    return undefined;
  }
}

function safeRender(value: unknown): string {
  try {
    if (value === null) return 'null';
    if (value === undefined) return 'undefined';
    if (
      typeof value === 'number' ||
      typeof value === 'boolean' ||
      typeof value === 'bigint'
    ) {
      return String(value);
    }
    return Object.prototype.toString.call(value);
  } catch {
    return 'Unserializable JavaScript failure';
  }
}

function captureBreadcrumbsWithinRecordBudget(
  record: Record<string, unknown>
): Array<{
  timestamp: string;
  source: string;
  category: string;
  message: string;
}> {
  const availableBytes = Math.max(
    0,
    MAXIMUM_HANDOFF_RECORD_BYTES - byteLength(JSON.stringify(record))
  );
  const breadcrumbs = captureBreadcrumbs(availableBytes);
  while (
    breadcrumbs.length > 0 &&
    byteLength(JSON.stringify({ ...record, breadcrumbs })) >
      MAXIMUM_HANDOFF_RECORD_BYTES
  ) {
    breadcrumbs.shift();
  }
  return breadcrumbs;
}

function captureBreadcrumbs(maximumBytes: number): Array<{
  timestamp: string;
  source: string;
  category: string;
  message: string;
}> {
  const entries = snapshotLogEntries();
  const selected: Array<{
    timestamp: string;
    source: string;
    category: string;
    message: string;
  }> = [];
  let bytes = 0;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (selected.length >= state.maximumBreadcrumbs) break;
    const entry = entries[index];
    if (!entry) continue;
    const breadcrumb = {
      timestamp: new Date(entry.timestampMs).toISOString(),
      source: sanitizeText(entry.source, 64),
      category: sanitizeText(entry.category, 256),
      message: sanitizeText(
        entry.message,
        MAXIMUM_BREADCRUMB_MESSAGE_BYTES,
        true
      ),
    };
    const breadcrumbBytes = byteLength(JSON.stringify(breadcrumb));
    if (
      bytes + breadcrumbBytes >
      Math.min(state.maximumBreadcrumbBytes, maximumBytes)
    ) {
      continue;
    }
    selected.push(breadcrumb);
    bytes += breadcrumbBytes;
  }
  return selected.reverse();
}

function allowlistedContext(
  configuration: CrumbConfiguration
): Readonly<Record<string, string>> {
  const values = configuration.customContext?.values ?? {};
  const allowedKeys = new Set(configuration.customContext?.allowedKeys ?? []);
  const result: Record<string, string> = {};
  let bytes = 0;
  for (const key of Object.keys(values).sort()) {
    if (
      !allowedKeys.has(key) ||
      !isValidContextKey(key) ||
      isSensitiveContextKey(key)
    ) {
      continue;
    }
    const value = sanitizeText(values[key] ?? '', MAXIMUM_CONTEXT_VALUE_BYTES);
    if (!value) continue;
    const entryBytes = byteLength(key) + byteLength(value);
    if (bytes + entryBytes > MAXIMUM_CONTEXT_BYTES) break;
    result[key] = value;
    bytes += entryBytes;
    if (Object.keys(result).length >= 16) break;
  }
  return result;
}

function isValidContextKey(value: string): boolean {
  return value.length <= 64 && /^[A-Za-z][A-Za-z0-9_.-]*$/.test(value);
}

function isSensitiveContextKey(value: string): boolean {
  return [
    'password',
    'passwd',
    'secret',
    'token',
    'authorization',
    'cookie',
    'api_key',
    'apikey',
    'access_key',
    'private_key',
    'card',
    'cvv',
    'cvc',
    'ssn',
    'email',
    'phone',
    'address',
  ].some((fragment) => value.toLowerCase().includes(fragment));
}

function sanitizeText(
  value: string,
  maximumBytes: number,
  preserveNewlines = false
): string {
  let sanitized = value
    .replace(/(https?:\/\/)[^/\s:@]+:[^/@\s]+@/gi, '$1[REDACTED]@')
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [REDACTED]')
    .replace(
      /\b(authorization|cookie|set-cookie|password|passwd|secret|token|api[_-]?key)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)/gi,
      '$1=[REDACTED]'
    )
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[REDACTED_EMAIL]')
    .replace(/\b(?:\d[ -]*?){13,19}\b/g, '[REDACTED_NUMBER]')
    .replace(/([?&][A-Za-z0-9._~-]+)=([^&#\s]*)/g, '$1=[REDACTED]')
    .replace(/\r\n?/g, '\n');
  sanitized = [...sanitized]
    .map((character) => {
      if (character === '\n' && preserveNewlines) return character;
      if (character === '\t' && preserveNewlines) return character;
      return character < ' ' || character === '\u007f' ? ' ' : character;
    })
    .join('');
  return truncateUtf8(sanitized.trim(), maximumBytes);
}

function fingerprintFor(normalized: {
  type: string;
  message: string;
  stack?: string;
}): string {
  const value = `${normalized.type}\u0000${normalized.message}\u0000${normalized.stack ?? ''}`;
  return `${fnv1a(value, 2_166_136_261)}${fnv1a(value, 2_247_766_997)}`;
}

function fnv1a(value: string, seed: number): string {
  let hash = seed;
  for (let index = 0; index < value.length; index += 1) {
    hash = Math.abs(Math.imul(hash, 16_777_619) + value.charCodeAt(index));
  }
  return hash.toString(16).padStart(8, '0');
}

function pruneFingerprints(now: number): void {
  for (const [fingerprint, timestamp] of state.fingerprints) {
    if (now - timestamp > DEDUPLICATION_WINDOW_MS) {
      state.fingerprints.delete(fingerprint);
    }
  }
}

let recordSequence = 0;

function makeRecordId(): string {
  recordSequence = (recordSequence + 1) % 36 ** 4;
  const random = Math.random().toString(36).slice(2, 14);
  return `jsc_${Date.now().toString(36)}${recordSequence.toString(36)}${random}`.slice(
    0,
    80
  );
}

function truncateUtf8(value: string, maximumBytes: number): string {
  if (byteLength(value) <= maximumBytes) return value;
  let result = '';
  for (const character of value) {
    if (byteLength(`${result}${character}…`) > maximumBytes) break;
    result += character;
  }
  return `${result}…`;
}

function byteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (
      code >= 0xd800 &&
      code <= 0xdbff &&
      index + 1 < value.length &&
      value.charCodeAt(index + 1) >= 0xdc00 &&
      value.charCodeAt(index + 1) <= 0xdfff
    ) {
      bytes += 4;
      index += 1;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function emptyState(): CrashCaptureState {
  return {
    native: NativeCrumbReactNative,
    context: {},
    maximumBreadcrumbs: DEFAULT_MAXIMUM_BREADCRUMBS,
    maximumBreadcrumbBytes: DEFAULT_MAXIMUM_BREADCRUMB_BYTES,
    configured: false,
    fingerprints: new Map(),
  };
}
