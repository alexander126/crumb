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
  CrumbCaptureOptions,
  CrumbConfiguration,
  CrumbDiagnosticsOptions,
  CrumbInvocation,
  CrumbLogLevel,
  CrumbLogMetadata,
  CrumbLogOptions,
  CrumbPrivacyOptions,
  CrumbRelease,
  CrumbUploadOptions,
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
