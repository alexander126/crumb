jest.mock('../NativeCrumbReactNative', () => ({
  __esModule: true,
  default: {
    start: jest.fn(),
    addLog: jest.fn(),
    clearLogs: jest.fn(),
    canCollectLogs: jest.fn(() => true),
  },
}));

import {
  clearLogs,
  disableConsoleCapture,
  enableConsoleCapture,
  snapshotLogEntries,
  writeLog,
} from '../log-buffer';

describe('console capture coexistence', () => {
  let realWarn: typeof console.warn;
  let realError: typeof console.error;

  beforeEach(() => {
    realWarn = console.warn;
    realError = console.error;
    clearLogs();
  });

  afterEach(() => {
    disableConsoleCapture();
    console.warn = realWarn;
    console.error = realError;
    clearLogs();
  });

  /**
   * The defect this fixes: the wrapper forwarded through a module-level
   * binding that disable() cleared, so a wrapper another library had wrapped
   * on top of stopped reaching the real console entirely.
   */
  it('keeps host output reaching the real console after another library wraps it', () => {
    const delivered: unknown[][] = [];
    console.warn = (...data: unknown[]) => {
      delivered.push(data);
    };

    enableConsoleCapture();
    const crumbWrapper = console.warn;
    const foreign = (...data: unknown[]) => crumbWrapper.apply(console, data);
    console.warn = foreign;

    disableConsoleCapture();
    console.warn('after disable');

    expect(delivered).toEqual([['after disable']]);
  });

  it('does not recurse when capture is re-enabled under a foreign wrapper', () => {
    const delivered: unknown[][] = [];
    console.warn = (...data: unknown[]) => {
      delivered.push(data);
    };

    enableConsoleCapture();
    const crumbWrapper = console.warn;
    console.warn = (...data: unknown[]) => crumbWrapper.apply(console, data);
    disableConsoleCapture();
    enableConsoleCapture();

    expect(() => console.warn('no recursion')).not.toThrow();
    expect(delivered).toEqual([['no recursion']]);
  });

  it('records one entry per call when a chain contains two Crumb wrappers', () => {
    console.warn = () => {};

    enableConsoleCapture();
    const first = console.warn;
    console.warn = (...data: unknown[]) => first.apply(console, data);
    enableConsoleCapture();

    console.warn('single entry');

    const captured = snapshotLogEntries().filter(
      (entry) => entry.category === 'console'
    );
    expect(captured).toHaveLength(1);
  });

  it('restores the original function when its wrapper is still installed', () => {
    const original = (console.warn = () => {});

    enableConsoleCapture();
    expect(console.warn).not.toBe(original);
    disableConsoleCapture();

    expect(console.warn).toBe(original);
  });

  it('still forwards and still records while capture is enabled', () => {
    const delivered: unknown[][] = [];
    console.error = (...data: unknown[]) => {
      delivered.push(data);
    };

    enableConsoleCapture();
    console.error('captured message');

    expect(delivered).toEqual([['captured message']]);
    const captured = snapshotLogEntries().filter(
      (entry) => entry.category === 'console'
    );
    expect(captured).toHaveLength(1);
    expect(captured[0]?.level).toBe('error');
    expect(captured[0]?.message).toContain('captured message');
  });
});

describe('metadata serialization failures', () => {
  beforeEach(() => {
    clearLogs();
  });

  afterEach(() => {
    disableConsoleCapture();
    clearLogs();
  });

  /**
   * The defect this fixes: traversal ran before the try block, so a throwing
   * getter escaped serializeMetadata, escaped writeLog, and could make the
   * host's own console.error call throw.
   */
  it('keeps readable properties when a getter throws', () => {
    const metadata = {
      safe: 'kept',
      get hostile(): string {
        throw new Error('synthetic getter failure');
      },
    };

    expect(() =>
      writeLog('error', 'with hostile metadata', metadata)
    ).not.toThrow();

    const message = snapshotLogEntries().at(-1)?.message ?? '';
    expect(message).toContain('kept');
    expect(message).toContain('[Unreadable]');
  });

  it('handles a proxy whose get trap throws', () => {
    const metadata = new Proxy(
      { safe: 'kept', hostile: 'value' },
      {
        get(target, key, receiver) {
          if (key === 'hostile') throw new Error('synthetic trap failure');
          return Reflect.get(target, key, receiver);
        },
      }
    );

    expect(() =>
      writeLog('error', 'with hostile proxy', metadata)
    ).not.toThrow();

    const message = snapshotLogEntries().at(-1)?.message ?? '';
    expect(message).toContain('kept');
    expect(message).toContain('[Unreadable]');
  });

  it('handles a proxy whose ownKeys trap throws', () => {
    const metadata = new Proxy(
      { safe: 'kept' },
      {
        ownKeys() {
          throw new Error('synthetic ownKeys failure');
        },
      }
    );

    expect(() =>
      writeLog('error', 'with hostile keys', metadata)
    ).not.toThrow();
    expect(snapshotLogEntries().at(-1)?.message).toContain('with hostile keys');
  });

  it('does not let a hostile object escape through console capture', () => {
    console.error = () => {};
    enableConsoleCapture();

    const hostile = {
      get boom(): string {
        throw new Error('synthetic failure');
      },
    };

    expect(() => console.error('hostile', hostile)).not.toThrow();
  });

  it('still serializes ordinary metadata unchanged', () => {
    writeLog('info', 'ordinary', { user: 'synthetic', count: 2 });

    const message = snapshotLogEntries().at(-1)?.message ?? '';
    expect(message).toContain('"user":"synthetic"');
    expect(message).toContain('"count":2');
  });
});
