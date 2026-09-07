import type { HybridObject } from 'react-native-nitro-modules';

export interface CrumbReactNative extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  start(configurationJson: string): void;
  setScreenContext(screenJson: string): void;
  canCollectLogs(): boolean;
  installReporter(): Promise<boolean>;
  show(screenJson: string): Promise<boolean>;
  addLog(entryJson: string): void;
  clearLogs(): void;
  recordJavaScriptCrash(recordJson: string): void;
  recoverJavaScriptCrashes(): Promise<boolean>;
}
