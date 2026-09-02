export type CrumbInvocation = 'shake' | 'programmatic';

export type CrumbTheme = 'system' | 'light' | 'dark';

export type CrumbReporterField = 'category' | 'description';

export type CrumbEvidenceCategory =
  | 'screenshot'
  | 'performance'
  | 'network'
  | 'logs'
  | 'thread_stacks'
  | 'health_check'
  | 'custom_context';

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

export interface CrumbReporterOptions {
  /** Controls only the built-in reporter appearance. */
  theme?: CrumbTheme;
  /** The description field is always required by the report contract. */
  visibleFields?: readonly CrumbReporterField[];
}

export interface CrumbApplicationMetadata {
  name?: string;
}

export interface CrumbCustomContextOptions {
  /** String-only context values; only explicitly allowed keys are persisted. */
  values?: Readonly<Record<string, string>>;
  allowedKeys?: readonly string[];
}

export interface CrumbWorkspacePolicyOptions {
  /** Public policy endpoint. Omit to keep configuration local-only. */
  url?: string;
  timeoutMs?: number;
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
  reporter?: CrumbReporterOptions;
  evidence?: readonly CrumbEvidenceCategory[];
  application?: CrumbApplicationMetadata;
  customContext?: CrumbCustomContextOptions;
  workspacePolicy?: CrumbWorkspacePolicyOptions;
}

export type CrumbLogMetadata = Readonly<Record<string, unknown>>;

export interface CrumbLogEntry {
  timestampMs: number;
  level: CrumbLogLevel;
  source: 'react-native';
  category: 'javascript' | 'console';
  message: string;
}
