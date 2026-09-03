jest.mock('react-native-nitro-modules', () => {
  const nativeMock = {
    start: jest.fn<void, [string]>(),
    canCollectLogs: jest.fn<boolean, []>(() => true),
    installReporter: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    show: jest.fn<Promise<boolean>, []>(() => Promise.resolve(true)),
    addLog: jest.fn<void, [string]>(),
    clearLogs: jest.fn<void, []>(),
    recordJavaScriptCrash: jest.fn<void, [string]>(),
    recoverJavaScriptCrashes: jest.fn<Promise<boolean>, []>(() =>
      Promise.resolve(true)
    ),
  };
  return {
    NitroModules: {
      createHybridObject: () => nativeMock,
    },
    nativeMock,
  };
});

import Crumb from '../index';
import { resetJavaScriptCrashCaptureForTesting } from '../javascript-crash-capture';

type ErrorUtilsLike = {
  getGlobalHandler: jest.Mock;
  setGlobalHandler: jest.Mock;
};

type UnhandledRejectionEvent = {
  reason: unknown;
  promise: Promise<unknown>;
};

type HermesRejectionTrackingOptions = {
  allRejections: boolean;
  onUnhandled: (id: number, rejection?: unknown) => void;
  onHandled: (id: number) => void;
};

type HermesInternalLike = {
  hasPromise: jest.Mock<boolean, []>;
  enablePromiseRejectionTracker: jest.Mock<
    void,
    [HermesRejectionTrackingOptions]
  >;
};

const mockNative = (
  jest.requireMock('react-native-nitro-modules') as {
    nativeMock: {
      start: jest.Mock<void, [string]>;
      canCollectLogs: jest.Mock<boolean, []>;
      installReporter: jest.Mock<Promise<boolean>, []>;
      show: jest.Mock<Promise<boolean>, []>;
      addLog: jest.Mock<void, [string]>;
      clearLogs: jest.Mock<void, []>;
      recordJavaScriptCrash: jest.Mock<void, [string]>;
      recoverJavaScriptCrashes: jest.Mock<Promise<boolean>, []>;
    };
  }
).nativeMock;

const globalObject = globalThis as typeof globalThis & {
  ErrorUtils?: ErrorUtilsLike;
  onunhandledrejection?: (event: UnhandledRejectionEvent) => unknown;
  HermesInternal?: HermesInternalLike;
  __DEV__?: boolean;
};

describe('React Native JavaScript crash capture', () => {
  let originalErrorUtils: ErrorUtilsLike | undefined;
  let originalUnhandledRejection:
    | ((event: UnhandledRejectionEvent) => unknown)
    | undefined;
  let originalHermesInternal: HermesInternalLike | undefined;
  let originalDevelopmentFlag: boolean | undefined;

  beforeEach(() => {
    resetJavaScriptCrashCaptureForTesting();
    originalErrorUtils = globalObject.ErrorUtils;
    originalUnhandledRejection = globalObject.onunhandledrejection;
    originalHermesInternal = globalObject.HermesInternal;
    originalDevelopmentFlag = globalObject.__DEV__;
    delete globalObject.ErrorUtils;
    delete globalObject.onunhandledrejection;
    delete globalObject.HermesInternal;
    Crumb.disableConsoleCapture();
    Crumb.clearLogs();
    jest.clearAllMocks();
    mockNative.canCollectLogs.mockReturnValue(true);
    mockNative.recoverJavaScriptCrashes.mockResolvedValue(true);
  });

  afterEach(() => {
    resetJavaScriptCrashCaptureForTesting();
    if (originalErrorUtils) globalObject.ErrorUtils = originalErrorUtils;
    else delete globalObject.ErrorUtils;
    if (originalUnhandledRejection) {
      globalObject.onunhandledrejection = originalUnhandledRejection;
    } else {
      delete globalObject.onunhandledrejection;
    }
    if (originalHermesInternal) {
      globalObject.HermesInternal = originalHermesInternal;
    } else {
      delete globalObject.HermesInternal;
    }
    if (originalDevelopmentFlag === undefined) {
      delete globalObject.__DEV__;
    } else {
      globalObject.__DEV__ = originalDevelopmentFlag;
    }
    Crumb.disableConsoleCapture();
  });

  it('does not install or invoke handlers when capture is disabled by default', async () => {
    const getGlobalHandler = jest.fn(() => jest.fn());
    const setGlobalHandler = jest.fn();
    globalObject.ErrorUtils = { getGlobalHandler, setGlobalHandler };
    const enablePromiseRejectionTracker = jest.fn<
      void,
      [HermesRejectionTrackingOptions]
    >();
    globalObject.HermesInternal = {
      hasPromise: jest.fn(() => true),
      enablePromiseRejectionTracker,
    };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
    });

    expect(getGlobalHandler).not.toHaveBeenCalled();
    expect(setGlobalHandler).not.toHaveBeenCalled();
    expect(enablePromiseRejectionTracker).not.toHaveBeenCalled();
    expect(globalObject.onunhandledrejection).toBeUndefined();
    expect(mockNative.recordJavaScriptCrash).not.toHaveBeenCalled();
    expect(mockNative.recoverJavaScriptCrashes).not.toHaveBeenCalled();
  });

  it('captures fatal exceptions before chaining the existing React Native handler', async () => {
    const calls: string[] = [];
    const existingHandler = jest.fn((error: Error, isFatal: boolean) => {
      calls.push(`existing:${error.message}:${isFatal}`);
    });
    globalObject.ErrorUtils = {
      getGlobalHandler: jest.fn(() => existingHandler),
      setGlobalHandler: jest.fn((handler) => {
        globalObject.ErrorUtils!.getGlobalHandler.mockReturnValue(handler);
      }),
    };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      release: {
        appVersion: '1.2.3',
        nativeBuild: '42',
        bundleVersion: 'ota-17',
      },
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
      customContext: {
        values: { account_tier: 'trial', email: 'user@example.invalid' },
        allowedKeys: ['account_tier', 'email'],
      },
    });

    const error = new Error('JS exploded');
    error.name = 'TypeError';
    error.stack = 'TypeError: JS exploded\n    at screen (app.js:10:4)';
    const installedHandler = globalObject.ErrorUtils.getGlobalHandler();
    mockNative.recordJavaScriptCrash.mockImplementation(() => {
      calls.push('capture');
    });

    installedHandler(error, true);

    expect(calls).toEqual(['capture', 'existing:JS exploded:true']);
    expect(existingHandler).toHaveBeenCalledWith(error, true);
    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(1);
    const record = JSON.parse(
      mockNative.recordJavaScriptCrash.mock.calls[0]?.[0] ?? '{}'
    );
    expect(record).toMatchObject({
      schema_version: '1.0',
      source: 'javascript',
      kind: 'exception',
      type: 'TypeError',
      message: 'JS exploded',
      stack: error.stack,
      is_fatal: true,
      release: {
        app_version: '1.2.3',
        native_build: '42',
        bundle_version: 'ota-17',
      },
      context: { account_tier: 'trial' },
    });
    expect(record.context.email).toBeUndefined();
    expect(mockNative.recoverJavaScriptCrashes).toHaveBeenCalledTimes(1);
  });

  it('leaves non-fatal React Native exceptions to the existing handler', async () => {
    const existingHandler = jest.fn();
    const getGlobalHandler = jest.fn(() => existingHandler);
    const setGlobalHandler = jest.fn((handler) =>
      getGlobalHandler.mockReturnValue(handler)
    );
    globalObject.ErrorUtils = { getGlobalHandler, setGlobalHandler };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    const error = new Error('non-fatal');
    getGlobalHandler()(error, false);

    expect(existingHandler).toHaveBeenCalledWith(error, false);
    expect(mockNative.recordJavaScriptCrash).not.toHaveBeenCalled();
  });

  it('captures unhandled rejections, preserves the host callback, and never serializes the reason object', async () => {
    const existingHandler = jest.fn();
    globalObject.onunhandledrejection = existingHandler;

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    const reason = {
      name: 'AbortError',
      message: 'request failed',
      stack: 'AbortError: request failed\n    at load (bundle.js:8:2)',
      responseBody: 'must never be captured',
    };
    const event = { reason, promise: Promise.resolve() };
    globalObject.onunhandledrejection!(event);

    expect(existingHandler).toHaveBeenCalledWith(event);
    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(1);
    const recordText =
      mockNative.recordJavaScriptCrash.mock.calls[0]?.[0] ?? '';
    expect(recordText).not.toContain('must never be captured');
    expect(JSON.parse(recordText)).toMatchObject({
      source: 'javascript',
      kind: 'unhandled_rejection',
      type: 'AbortError',
      message: 'request failed',
      stack: reason.stack,
      is_fatal: false,
    });
  });

  it('does not replace React Native Hermes rejection tracking in development', async () => {
    globalObject.__DEV__ = true;
    const enablePromiseRejectionTracker = jest.fn<
      void,
      [HermesRejectionTrackingOptions]
    >();
    globalObject.HermesInternal = {
      hasPromise: jest.fn(() => true),
      enablePromiseRejectionTracker,
    };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    expect(enablePromiseRejectionTracker).not.toHaveBeenCalled();
  });

  it('enables Hermes rejection tracking in release-style runtimes and preserves the global handler chain', async () => {
    globalObject.__DEV__ = false;
    const existingHandler = jest.fn();
    const getGlobalHandler = jest.fn(() => existingHandler);
    globalObject.ErrorUtils = {
      getGlobalHandler,
      setGlobalHandler: jest.fn((handler) =>
        getGlobalHandler.mockReturnValue(handler)
      ),
    };
    const enablePromiseRejectionTracker = jest.fn<
      void,
      [HermesRejectionTrackingOptions]
    >();
    globalObject.HermesInternal = {
      hasPromise: jest.fn(() => true),
      enablePromiseRejectionTracker,
    };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    const options = enablePromiseRejectionTracker.mock.calls[0]?.[0];
    if (!options) throw new Error('Hermes rejection tracker was not installed');
    const reason = new Error('offline request failed');
    reason.stack = 'Error: offline request failed\n    at sync (bundle.js:9:3)';
    options.onUnhandled(17, reason);

    expect(options.allRejections).toBe(true);
    expect(existingHandler).toHaveBeenCalledTimes(1);
    expect(existingHandler.mock.calls[0]?.[1]).toBe(false);
    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(1);
    expect(
      JSON.parse(mockNative.recordJavaScriptCrash.mock.calls[0]?.[0] ?? '{}')
    ).toMatchObject({
      source: 'javascript',
      kind: 'unhandled_rejection',
      type: 'Error',
      message: 'offline request failed',
      stack: reason.stack,
      is_fatal: false,
    });
  });

  it('collapses an exception and rejection wrapper for the same JavaScript cause', async () => {
    const existingHandler = jest.fn();
    globalObject.onunhandledrejection = undefined;
    const setGlobalHandler = jest.fn((handler) => {
      globalObject.ErrorUtils!.getGlobalHandler.mockReturnValue(handler);
    });
    globalObject.ErrorUtils = {
      getGlobalHandler: jest.fn(() => existingHandler),
      setGlobalHandler,
    };

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    const error = new Error('same cause');
    error.stack = 'Error: same cause\n    at run (bundle.js:1:1)';
    globalObject.ErrorUtils.getGlobalHandler()(error, true);
    globalObject.onunhandledrejection!({
      reason: error,
      promise: Promise.resolve(),
    });

    expect(mockNative.recordJavaScriptCrash).toHaveBeenCalledTimes(1);
    expect(existingHandler).toHaveBeenCalledTimes(1);
  });

  it('keeps the original fatal behavior if native persistence fails', async () => {
    const existingHandler = jest.fn();
    const setGlobalHandler = jest.fn((handler) => {
      globalObject.ErrorUtils!.getGlobalHandler.mockReturnValue(handler);
    });
    globalObject.ErrorUtils = {
      getGlobalHandler: jest.fn(() => existingHandler),
      setGlobalHandler,
    };
    mockNative.recordJavaScriptCrash.mockImplementation(() => {
      throw new Error('storage unavailable');
    });

    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: { enabled: true },
      },
    });

    const error = new Error('preserve me');
    expect(() =>
      globalObject.ErrorUtils!.getGlobalHandler()(error, true)
    ).not.toThrow();
    expect(existingHandler).toHaveBeenCalledWith(error, true);
  });

  it('bounds breadcrumbs and context before the synchronous native handoff', async () => {
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: {
          enabled: true,
          maximumBreadcrumbs: 2,
          maximumBreadcrumbBytes: 200,
        },
      },
      customContext: {
        values: { account_tier: 'trial' },
        allowedKeys: ['account_tier'],
      },
    });
    Crumb.log('info', 'first breadcrumb');
    Crumb.log('info', 'second breadcrumb');
    Crumb.log('info', 'third breadcrumb');

    globalObject.onunhandledrejection = undefined;
    const getGlobalHandler = jest.fn(() => jest.fn());
    const setGlobalHandler = jest.fn((handler) =>
      getGlobalHandler.mockReturnValue(handler)
    );
    globalObject.ErrorUtils = { getGlobalHandler, setGlobalHandler };
    resetJavaScriptCrashCaptureForTesting();
    // Reconfigure through a fresh capture installation for deterministic handler state.
    await Crumb.start({
      projectKey: 'crumb_sdk_test',
      environment: 'test',
      diagnostics: {
        javascriptCrashCapture: {
          enabled: true,
          maximumBreadcrumbs: 2,
          maximumBreadcrumbBytes: 200,
        },
      },
      customContext: {
        values: { account_tier: 'trial' },
        allowedKeys: ['account_tier'],
      },
    });

    getGlobalHandler()(new Error('bounded'), true);
    const record = JSON.parse(
      mockNative.recordJavaScriptCrash.mock.calls.at(-1)?.[0] ?? '{}'
    );
    expect(record.breadcrumbs.length).toBeLessThanOrEqual(2);
    expect(
      utf8ByteLength(JSON.stringify(record.breadcrumbs))
    ).toBeLessThanOrEqual(200);
    expect(record.context).toEqual({ account_tier: 'trial' });
  });
});

function utf8ByteLength(value: string): number {
  return encodeURIComponent(value).replace(/%[0-9A-F]{2}|./g, '_').length;
}
