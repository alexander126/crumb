jest.mock('../NativeCrumbReactNative', () => ({
  __esModule: true,
  default: { setScreenContext: jest.fn() },
}));
jest.mock('react', () => ({ useEffect: jest.fn() }));
import { useEffect } from 'react';
import Native from '../NativeCrumbReactNative';
import {
  setScreen,
  trackReactNavigation,
  useExpoRouterScreen,
} from '../screen-context';
import type { CrumbNavigationRef } from '../screen-context';

const bridge = jest.mocked(Native.setScreenContext);
const effect = jest.mocked(useEffect);
const current = () => JSON.parse(bridge.mock.calls.at(-1)?.[0] ?? 'null');

beforeEach(() => {
  jest.clearAllMocks();
  setScreen(null);
});

test('manual context clears and rejects URLs, oversized labels and hierarchies', () => {
  setScreen('Checkout', { route: ['Shop', 'Checkout'] });
  expect(current()).toEqual({
    name: 'Checkout',
    route: ['Shop', 'Checkout'],
    source: 'manual',
  });
  for (const name of [
    '?token=secret',
    'https://example.invalid',
    'x'.repeat(129),
    '😀'.repeat(33),
    'bad\nname',
  ]) {
    expect(() => setScreen(name)).toThrow();
    expect(current()).toBeNull();
  }
  expect(() => setScreen('Home', { route: Array(9).fill('Home') })).toThrow();
  setScreen(null);
  expect(current()).toBeNull();
});

test('navigation tracks initial ready and nested focused routes without reading params', () => {
  let ready = false;
  let root: unknown = {
    index: 0,
    routes: [
      {
        name: 'Shop',
        state: {
          index: 1,
          routes: [
            { name: 'Product' },
            {
              name: 'Checkout',
              get params() {
                throw new Error('Must never read parameters');
              },
            },
          ],
        },
      },
    ],
  };
  const listeners: Partial<Record<'ready' | 'state', () => void>> = {};
  const unsubscribe = jest.fn();
  const ref: CrumbNavigationRef = {
    isReady: () => ready,
    getRootState: () => root,
    addListener: (event, listener) => {
      listeners[event] = listener;
      return unsubscribe;
    },
  };
  const cleanup = trackReactNavigation(ref);
  expect(current()).toBeNull();
  ready = true;
  listeners.ready?.();
  expect(current()).toEqual({
    name: 'Checkout',
    route: ['Shop', 'Checkout'],
    source: 'react_navigation',
  });
  root = { index: 1, routes: [{ name: 'Shop' }, { name: 'PaymentModal' }] };
  listeners.state?.();
  expect(current().name).toBe('PaymentModal');
  root = { index: 5, routes: [] };
  listeners.state?.();
  expect(current()).toBeNull();
  setScreen('Manual');
  cleanup();
  expect(unsubscribe).toHaveBeenCalledTimes(2);
  expect(current().name).toBe('Manual');
  listeners.state?.();
  expect(current().name).toBe('Manual');
});

test('ready containers are tracked immediately and cleanup clears their context', () => {
  const cleanup = trackReactNavigation({
    isReady: () => true,
    getRootState: () => ({ index: 0, routes: [{ name: 'Home' }] }),
    addListener: () => () => {},
  });
  expect(current().name).toBe('Home');
  cleanup();
  expect(current()).toBeNull();
});

test('Expo Router stores template segments and clears on root unmount', () => {
  useExpoRouterScreen(['orders', '[id]']);
  const cleanup = effect.mock.calls.at(-1)?.[0]();
  expect(current()).toEqual({
    name: '/orders/[id]',
    route: ['orders', '[id]'],
    source: 'expo_router',
  });
  if (typeof cleanup === 'function') cleanup();
  expect(current()).toBeNull();
  useExpoRouterScreen([]);
  effect.mock.calls.at(-1)?.[0]();
  expect(current().name).toBe('/');
});
