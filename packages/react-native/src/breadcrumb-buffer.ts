import type { CrumbJavaScriptCrashCaptureOptions } from './types';

export interface CrumbBreadcrumb {
  timestampMs: number;
  category: string;
  message: string;
}

const DEFAULT_MAXIMUM_BREADCRUMBS = 20;
const DEFAULT_MAXIMUM_BYTES = 16_384;
const MAXIMUM_MESSAGE_LENGTH = 2_048;

let enabled = false;
let maximumBreadcrumbs = DEFAULT_MAXIMUM_BREADCRUMBS;
let maximumBytes = DEFAULT_MAXIMUM_BYTES;
let breadcrumbs: CrumbBreadcrumb[] = [];
let usedBytes = 0;

export function configureBreadcrumbBuffer(
  options: CrumbJavaScriptCrashCaptureOptions | undefined
): void {
  enabled = options?.enabled === true;
  maximumBreadcrumbs =
    options?.maximumBreadcrumbs ?? DEFAULT_MAXIMUM_BREADCRUMBS;
  maximumBytes = options?.maximumBreadcrumbBytes ?? DEFAULT_MAXIMUM_BYTES;
  breadcrumbs = [];
  usedBytes = 0;
}

export function recordBreadcrumb(
  timestampMs: number,
  category: string,
  message: string
): void {
  if (!enabled) return;

  const breadcrumb: CrumbBreadcrumb = {
    timestampMs,
    category: truncate(category, 64),
    message: truncate(message, MAXIMUM_MESSAGE_LENGTH),
  };
  breadcrumbs.push(breadcrumb);
  usedBytes += byteLength(JSON.stringify(breadcrumb));
  prune();
}

export function snapshotBreadcrumbs(): CrumbBreadcrumb[] {
  if (!enabled) return [];
  prune();
  return breadcrumbs.map((breadcrumb) => ({ ...breadcrumb }));
}

export function clearBreadcrumbs(): void {
  breadcrumbs = [];
  usedBytes = 0;
}

function prune(): void {
  while (breadcrumbs.length > maximumBreadcrumbs || usedBytes > maximumBytes) {
    const removed = breadcrumbs.shift();
    if (!removed) return;
    usedBytes -= byteLength(JSON.stringify(removed));
  }
}

function truncate(value: string, maximum: number): string {
  return value.length <= maximum ? value : `${value.slice(0, maximum - 1)}…`;
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
