# UI React

Main React + Vite frontend for Coin-Ops.

## Requirements

Before running the app or the tests, you need:

- Node.js
- npm

## Setup

Install frontend dependencies:

```bash
cd ui-react
npm install
```

## Run The App

Start the local development server:

```bash
npm run dev
```

Then open the URL printed in the terminal. In this project it is usually:

```text
http://localhost:3000/
```

## Run Tests

Start Vitest in watch mode:

```bash
npm test
```

This keeps running and re-runs tests when files change.

Run the full test suite one time:

```bash
npm run test:run
```

You can also run a one-time test run with:

```bash
npm test -- --run
```

Both one-time commands do the same job.

## Test Structure

Tests are grouped into 3 small parts:

- Unit tests
  Helper logic such as formatting, labels, and filtering.

- Component tests
  Small UI pieces such as cards, charts, and modals.

- App-level tests
  The main `App` component with mocked API responses.

Main test locations:

- `src/lib/*.test.ts`
  Helper tests

- `src/components/*.test.tsx`
  Component tests

- `src/App.test.tsx`
  App-level tests

- `src/test/setup.ts`
  Shared test setup

- `src/test/mockFetch.ts`
  Shared fetch mocking helper

## Mocking

The tests do not call the real backend.

Instead, app-level tests replace `fetch(...)` with mocked responses.

Example:

- app asks for `/api/current`
- test returns fake market data
- app asks for `/api/prices`
- test returns fake price data

Shared fetch mocking lives in:

- `src/test/mockFetch.ts`

This keeps tests:

- local
- fast
- independent from VMs, Docker, and backend services

## Troubleshooting

### Missing browser APIs in jsdom

Some UI tests use browser-like APIs that do not fully exist in the test environment.

Examples:

- `ResizeObserver`
- element size/layout APIs used by chart components

These are handled in:

- `src/test/setup.ts`

That setup file adds small test-only mocks so chart and UI tests can run in jsdom.

### A test fails

Start with the first real error message.

Then check:

1. which test file failed
2. what the test expected
3. what was actually rendered

Run the tests again with:

```bash
npm run test:run
```

## Useful Extra Commands

Type-check the frontend:

```bash
npm run lint
```

Build the frontend:

```bash
npm run build
```
