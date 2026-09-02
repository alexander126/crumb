import type { CrumbReactNative } from './CrumbReactNative.nitro';

const unsupportedMessage =
  'Crumb requires an iOS or Android native build and is unavailable on web or in Expo Go.';

const unsupportedModule: CrumbReactNative = {
  name: 'CrumbReactNative',
  dispose: () => undefined,
  equals: () => false,
  toString: () => '[HybridObject CrumbReactNative unavailable on web]',
  start: () => {
    throw new Error(unsupportedMessage);
  },
  canCollectLogs: () => false,
  installReporter: () => Promise.resolve(false),
  show: () => Promise.resolve(false),
  recordJavaScriptCrash: () => undefined,
  addLog: () => undefined,
  clearLogs: () => undefined,
};

export default unsupportedModule;
