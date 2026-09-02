import NativeCrumbReactNative from './NativeCrumbReactNative';
import {
  clearLogs,
  configureLogBuffer,
  disableConsoleCapture,
  enableConsoleCapture,
  markNativeStarted,
  writeLog,
} from './log-buffer';
import type {
  CrumbConfiguration,
  CrumbLogLevel,
  CrumbLogMetadata,
} from './types';

export type {
  CrumbApplicationMetadata,
  CrumbCaptureOptions,
  CrumbConfiguration,
  CrumbCustomContextOptions,
  CrumbDiagnosticsOptions,
  CrumbEvidenceCategory,
  CrumbInvocation,
  CrumbLogLevel,
  CrumbLogMetadata,
  CrumbLogOptions,
  CrumbPrivacyOptions,
  CrumbReporterField,
  CrumbReporterOptions,
  CrumbRelease,
  CrumbTheme,
  CrumbUploadOptions,
  CrumbWorkspacePolicyOptions,
} from './types';

export async function start(configuration: CrumbConfiguration): Promise<void> {
  validateConfiguration(configuration);
  const logOptions = configuration.diagnostics?.logs;
  configureLogBuffer(logOptions);
  NativeCrumbReactNative.start(JSON.stringify(configuration));
  markNativeStarted();

  if (logOptions?.captureConsole) {
    enableConsoleCapture();
  } else {
    disableConsoleCapture();
  }
}

export function installReporter(): Promise<boolean> {
  return NativeCrumbReactNative.installReporter();
}

export function show(): Promise<boolean> {
  return NativeCrumbReactNative.show();
}

export function log(
  level: CrumbLogLevel,
  message: string,
  metadata?: CrumbLogMetadata
): void {
  if (!message.trim()) {
    throw new TypeError('Crumb.log message must not be empty.');
  }
  writeLog(level, message, metadata);
}

export { clearLogs, disableConsoleCapture, enableConsoleCapture };

function validateConfiguration(configuration: CrumbConfiguration): void {
  if (!configuration.projectKey?.trim()) {
    throw new TypeError('Crumb projectKey must not be empty.');
  }
  if (!configuration.environment?.trim()) {
    throw new TypeError('Crumb environment must not be empty.');
  }

  assertPositiveInteger(
    configuration.capture?.maximumScreenshotDimension,
    'capture.maximumScreenshotDimension'
  );
  assertPositiveInteger(
    configuration.capture?.maximumScreenshotBytes,
    'capture.maximumScreenshotBytes'
  );
  assertPositiveInteger(
    configuration.diagnostics?.timeoutMs,
    'diagnostics.timeoutMs'
  );
  assertPositiveInteger(
    configuration.diagnostics?.logs?.lookbackMs,
    'diagnostics.logs.lookbackMs'
  );
  assertPositiveInteger(
    configuration.diagnostics?.logs?.maximumEntries,
    'diagnostics.logs.maximumEntries'
  );
  assertPositiveInteger(
    configuration.diagnostics?.logs?.maximumBytes,
    'diagnostics.logs.maximumBytes'
  );

  if (
    configuration.reporter?.theme !== undefined &&
    !['system', 'light', 'dark'].includes(configuration.reporter.theme)
  ) {
    throw new TypeError('Crumb reporter.theme is unsupported.');
  }
  assertReporterFields(configuration.reporter?.visibleFields);
  assertEvidence(configuration.evidence);
  assertApplicationMetadata(configuration.application?.name);
  assertCustomContext(configuration.customContext);
  assertWorkspacePolicy(configuration.workspacePolicy);
}

function assertReporterFields(value: readonly string[] | undefined): void {
  if (value === undefined) return;
  if (
    new Set(value).size !== value.length ||
    value.some((field) => !['category', 'description'].includes(field)) ||
    !value.includes('description')
  ) {
    throw new TypeError(
      'Crumb reporter.visibleFields must contain unique supported fields including description.'
    );
  }
}

function assertEvidence(value: readonly string[] | undefined): void {
  if (value === undefined) return;
  const supported = [
    'screenshot',
    'performance',
    'network',
    'logs',
    'thread_stacks',
    'health_check',
    'custom_context',
  ];
  if (
    new Set(value).size !== value.length ||
    value.some((item) => !supported.includes(item))
  ) {
    throw new TypeError(
      'Crumb evidence must contain unique supported categories.'
    );
  }
}

function assertApplicationMetadata(value: string | undefined): void {
  if (value === undefined) return;
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.length > 256 ||
    hasControlCharacters(value)
  ) {
    throw new TypeError(
      'Crumb application.name must be printable and at most 256 characters.'
    );
  }
}

function assertCustomContext(value: CrumbConfiguration['customContext']): void {
  if (value === undefined) return;
  const allowedKeys = value.allowedKeys ?? [];
  const values = value.values ?? {};
  if (
    !Array.isArray(allowedKeys) ||
    new Set(allowedKeys).size !== allowedKeys.length ||
    allowedKeys.length > 16 ||
    allowedKeys.some((key) => !isValidContextKey(key))
  ) {
    throw new TypeError(
      'Crumb customContext.allowedKeys contains an invalid key.'
    );
  }
  if (values === null || typeof values !== 'object' || Array.isArray(values)) {
    throw new TypeError('Crumb customContext.values must be a string map.');
  }
  const entries = Object.entries(values);
  if (
    entries.length > 16 ||
    entries.some(
      ([key, item]) => !isValidContextKey(key) || typeof item !== 'string'
    )
  ) {
    throw new TypeError(
      'Crumb customContext.values must contain bounded string values.'
    );
  }
}

function assertWorkspacePolicy(
  value: CrumbConfiguration['workspacePolicy']
): void {
  if (value === undefined) return;
  assertPositiveInteger(value.timeoutMs, 'workspacePolicy.timeoutMs');
  if (
    value.timeoutMs !== undefined &&
    (value.timeoutMs < 250 || value.timeoutMs > 5000)
  ) {
    throw new TypeError(
      'Crumb workspacePolicy.timeoutMs must be between 250 and 5000.'
    );
  }
  if (value.url === undefined) return;
  let url: WorkspacePolicyUrl;
  try {
    url = new URL(value.url) as unknown as WorkspacePolicyUrl;
  } catch {
    throw new TypeError(
      'Crumb workspacePolicy.url must be a valid HTTP or HTTPS URL.'
    );
  }
  if (
    !['http:', 'https:'].includes(url.protocol) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new TypeError(
      'Crumb workspacePolicy.url must be an HTTP or HTTPS URL without credentials or query values.'
    );
  }
}

interface WorkspacePolicyUrl {
  protocol: string;
  username: string;
  password: string;
  search: string;
  hash: string;
}

function isValidContextKey(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length <= 64 &&
    /^[A-Za-z][A-Za-z0-9_.-]*$/.test(value)
  );
}

function hasControlCharacters(value: string): boolean {
  return [...value].some(
    (character) => character < ' ' || character === '\u007f'
  );
}

function assertPositiveInteger(value: number | undefined, field: string): void {
  if (value === undefined) return;
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`Crumb ${field} must be a positive integer.`);
  }
}

const Crumb = Object.freeze({
  start,
  installReporter,
  show,
  log,
  clearLogs,
  enableConsoleCapture,
  disableConsoleCapture,
});

export default Crumb;
