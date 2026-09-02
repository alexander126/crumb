import NativeCrumbReactNative from './NativeCrumbReactNative';
import {
  configureBreadcrumbBuffer,
  snapshotBreadcrumbs,
} from './breadcrumb-buffer';
import type {
  CrumbJavaScriptCrashCaptureOptions,
  CrumbJavaScriptCrashKind,
} from './types';

type ErrorUtilsHandler = (...args: unknown[]) => unknown;

interface ErrorUtilsLike {
  getGlobalHandler?: () => ErrorUtilsHandler | null | undefined;
  setGlobalHandler?: (handler: ErrorUtilsHandler | null | undefined) => void;
}

interface CrumbRuntimeGlobal {
  ErrorUtils?: ErrorUtilsLike;
  onunhandledrejection?: ((event: unknown) => unknown) | null;
}

interface InstalledErrorUtilsHandler {
  api: ErrorUtilsLike;
  wrapper: ErrorUtilsHandler;
  previous: ErrorUtilsHandler | null | undefined;
}

interface InstalledRejectionHandler {
  wrapper: (this: unknown, event: unknown) => unknown;
  previous: ((event: unknown) => unknown) | null | undefined;
}

let installedErrorUtils: InstalledErrorUtilsHandler | undefined;
let installedRejection: InstalledRejectionHandler | undefined;

export function configureJavaScriptCrashCapture(
  options: CrumbJavaScriptCrashCaptureOptions | undefined
): void {
  disableJavaScriptCrashCapture();
  configureBreadcrumbBuffer(options);
  if (options?.enabled !== true) return;

  installErrorUtilsHandler();
  installUnhandledRejectionHandler();
}

export function disableJavaScriptCrashCapture(): void {
  const runtimeGlobal = globalThis as unknown as CrumbRuntimeGlobal;

  if (installedErrorUtils) {
    const { api, wrapper, previous } = installedErrorUtils;
    try {
      if (api.getGlobalHandler?.() === wrapper) {
        api.setGlobalHandler?.(previous);
      }
    } catch {
      // A host-owned ErrorUtils implementation may reject restoration.
    }
    installedErrorUtils = undefined;
  }

  if (installedRejection) {
    const { wrapper, previous } = installedRejection;
    try {
      if (runtimeGlobal.onunhandledrejection === wrapper) {
        runtimeGlobal.onunhandledrejection = previous;
      }
    } catch {
      // A host may expose a read-only global property.
    }
    installedRejection = undefined;
  }

  configureBreadcrumbBuffer(undefined);
}

function installErrorUtilsHandler(): void {
  const runtimeGlobal = globalThis as unknown as CrumbRuntimeGlobal;
  const api = runtimeGlobal.ErrorUtils;
  if (
    !api ||
    typeof api.getGlobalHandler !== 'function' ||
    typeof api.setGlobalHandler !== 'function'
  ) {
    return;
  }

  let previous: ErrorUtilsHandler | null | undefined;
  try {
    previous = api.getGlobalHandler();
  } catch {
    return;
  }

  const wrapper: ErrorUtilsHandler = function (this: unknown, ...args) {
    if (args[1] !== false) {
      captureJavaScriptFailure('fatal_exception', args[0]);
    }
    return previous?.apply(this, args);
  };

  try {
    api.setGlobalHandler(wrapper);
    installedErrorUtils = { api, wrapper, previous };
  } catch {
    // Installing a capture hook must never prevent the host from starting.
  }
}

function installUnhandledRejectionHandler(): void {
  const runtimeGlobal = globalThis as unknown as CrumbRuntimeGlobal;
  let previous: ((event: unknown) => unknown) | null | undefined;
  try {
    previous = runtimeGlobal.onunhandledrejection;
    const wrapper = function (this: unknown, event: unknown) {
      captureJavaScriptFailure(
        'unhandled_rejection',
        readProperty(event, 'reason')
      );
      return previous?.call(this, event);
    };
    runtimeGlobal.onunhandledrejection = wrapper;
    installedRejection = { wrapper, previous };
  } catch {
    // Some JavaScript hosts do not expose a writable global rejection hook.
  }
}

function captureJavaScriptFailure(
  kind: CrumbJavaScriptCrashKind,
  reason: unknown
): void {
  try {
    const normalized = normalizeFailure(reason, kind);
    const payload = {
      kind,
      source: 'javascript' as const,
      errorType: normalized.errorType,
      message: normalized.message,
      rawStack: normalized.rawStack,
      fingerprint: fingerprint(kind, normalized),
      occurredAtMs: Date.now(),
      nativeTerminationWrapper: false,
      breadcrumbs: snapshotBreadcrumbs(),
    };
    NativeCrumbReactNative.recordJavaScriptCrash(JSON.stringify(payload));
  } catch {
    // Crash capture is best effort; the host handler must still run.
  }
}

function normalizeFailure(
  reason: unknown,
  kind: CrumbJavaScriptCrashKind
): { errorType: string; message: string; rawStack?: string } {
  if (reason instanceof Error) {
    return {
      errorType: truncate(reason.name || 'Error', 128),
      message: truncate(reason.message || safeString(reason), 4_096),
      rawStack: reason.stack ? truncate(reason.stack, 16_384) : undefined,
    };
  }

  if (typeof reason === 'string') {
    return {
      errorType:
        kind === 'unhandled_rejection' ? 'UnhandledRejection' : 'Error',
      message: truncate(reason, 4_096),
    };
  }

  const errorType = readProperty(reason, 'name');
  const message = readProperty(reason, 'message');
  const rawStack = readProperty(reason, 'stack');
  return {
    errorType: truncate(
      typeof errorType === 'string' && errorType.trim()
        ? errorType
        : kind === 'unhandled_rejection'
          ? 'UnhandledRejection'
          : 'Error',
      128
    ),
    message: truncate(
      typeof message === 'string' && message.trim()
        ? message
        : safeString(reason),
      4_096
    ),
    rawStack:
      typeof rawStack === 'string' ? truncate(rawStack, 16_384) : undefined,
  };
}

function readProperty(value: unknown, property: string): unknown {
  if (
    value === null ||
    (typeof value !== 'object' && typeof value !== 'function')
  ) {
    return undefined;
  }
  try {
    return (value as Record<string, unknown>)[property];
  } catch {
    return undefined;
  }
}

function safeString(value: unknown): string {
  try {
    const rendered = String(value);
    return rendered.trim() ? rendered : '[Unknown JavaScript failure]';
  } catch {
    return '[Unserializable JavaScript failure]';
  }
}

function fingerprint(
  kind: CrumbJavaScriptCrashKind,
  normalized: { errorType: string; message: string; rawStack?: string }
): string {
  const value = `${kind}|${normalized.errorType}|${normalized.message}|${normalized.rawStack ?? ''}`;
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return `js_${(hash >>> 0).toString(16).padStart(8, '0')}`;
}

function truncate(value: string, maximum: number): string {
  return value.length <= maximum ? value : `${value.slice(0, maximum - 1)}…`;
}
