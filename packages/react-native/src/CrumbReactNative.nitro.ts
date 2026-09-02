import type { HybridObject } from 'react-native-nitro-modules';

export interface CrumbReactNative extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  start(configurationJson: string): void;
  canCollectLogs(): boolean;
  installReporter(): Promise<boolean>;
  show(): Promise<boolean>;
  addLog(entryJson: string): void;
  clearLogs(): void;
}
