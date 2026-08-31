import type { CrumbConfiguration } from '@crumbsdk/react-native';

const projectKey = process.env.EXPO_PUBLIC_CRUMB_PROJECT_KEY?.trim();
const ingestionUrl = process.env.EXPO_PUBLIC_CRUMB_INGESTION_URL?.trim();
const environment =
  process.env.EXPO_PUBLIC_CRUMB_ENVIRONMENT?.trim() || 'development';

export const crumbSetup = {
  environment,
  hasIngestionUrl: Boolean(ingestionUrl),
  isConfigured: Boolean(projectKey),
} as const;

export function createCrumbConfiguration(): CrumbConfiguration {
  if (!projectKey) {
    throw new Error(
      'Add EXPO_PUBLIC_CRUMB_PROJECT_KEY to .env.local, then restart Metro.'
    );
  }

  return {
    projectKey,
    environment,
    release: {
      bundleVersion: 'crumb-react-native-example@0.0.1',
    },
    invocation: ['shake', 'programmatic'],
    capture: {
      screenshot: true,
    },
    diagnostics: {
      logs: {
        enabled: true,
        captureConsole: true,
      },
    },
    privacy: {
      maskAllTextInputs: true,
      maskScreenshotsBeforeUpload: true,
    },
    ...(ingestionUrl ? { upload: { ingestionUrl } } : {}),
  };
}
