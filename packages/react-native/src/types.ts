export type CrumbInvocation = 'shake' | 'programmatic';

export type CrumbLogLevel =
  | 'debug'
  | 'info'
  | 'notice'
  | 'warning'
  | 'error'
  | 'fault';

export interface CrumbRelease {
  /** Defaults to the native bundle version name. */
  appVersion?: string;
  /** Defaults to the native bundle build number. */
  nativeBuild?: string;
  /** OTA or JavaScript bundle identity supplied by the host app. */
  bundleVersion?: string;
}

export interface CrumbCaptureOptions {
  screenshot?: boolean;
  maximumScreenshotDimension?: number;
  maximumScreenshotBytes?: number;
}

export interface CrumbLogOptions {
  enabled?: boolean;
  lookbackMs?: number;
  maximumEntries?: number;
  maximumBytes?: number;
  /** Captures console.warn and console.error while preserving their behavior. */
  captureConsole?: boolean;
}

export interface CrumbDiagnosticsOptions {
  healthCheckUrl?: string;
  timeoutMs?: number;
  logs?: CrumbLogOptions;
}

export interface CrumbPrivacyOptions {
  maskAllTextInputs?: boolean;
  maskScreenshotsBeforeUpload?: boolean;
}

export interface CrumbUploadOptions {
  /** Base URL of the Crumb ingestion API. Omit to keep reports local-only. */
  ingestionUrl?: string;
}

export interface CrumbConfiguration {
  projectKey: string;
  environment: string;
  release?: CrumbRelease;
  invocation?: readonly CrumbInvocation[];
  capture?: CrumbCaptureOptions;
  diagnostics?: CrumbDiagnosticsOptions;
  privacy?: CrumbPrivacyOptions;
  upload?: CrumbUploadOptions;
}

export type CrumbLogMetadata = Readonly<Record<string, unknown>>;

export interface CrumbLogEntry {
  timestampMs: number;
  level: CrumbLogLevel;
  source: 'react-native';
  category: 'javascript' | 'console';
  message: string;
}
