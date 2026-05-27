import '@testing-library/jest-dom';
import React from 'react';
import { vi } from 'vitest';

vi.mock('recharts', async () => {
  const actual = await vi.importActual<typeof import('recharts')>('recharts');

  return {
    ...actual,
    ResponsiveContainer: ({ children }: { children: React.ReactNode }) => (
      React.createElement('div', { style: { width: 800, height: 600 } }, children)
    ),
  };
});

class ResizeObserverMock {
  observe() {}
  unobserve() {}
  disconnect() {}
}

globalThis.ResizeObserver = ResizeObserverMock;

Object.defineProperties(HTMLElement.prototype, {
  clientWidth: {
    configurable: true,
    get() {
      return 800;
    },
  },
  clientHeight: {
    configurable: true,
    get() {
      return 600;
    },
  },
  offsetWidth: {
    configurable: true,
    get() {
      return 800;
    },
  },
  offsetHeight: {
    configurable: true,
    get() {
      return 600;
    },
  },
});

HTMLElement.prototype.getBoundingClientRect = function () {
  return {
    width: 800,
    height: 600,
    top: 0,
    left: 0,
    right: 800,
    bottom: 600,
    x: 0,
    y: 0,
    toJSON() {
      return {};
    },
  };
};
