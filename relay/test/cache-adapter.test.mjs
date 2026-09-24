import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { CachePurgeError, createRelayCache, relayCache, RELAY_CACHE_TAG, RELAY_CACHE_TTL,
  RELAY_CACHE_READ_TIMEOUT_MS, RELAY_CACHE_DRAIN_MS } from '../lib/cache.mjs';

const cacheWithoutDrain = options => createRelayCache({ drainMs: 0, ...options });

function runtime(t, context) {
  const symbol = Symbol.for('@vercel/request-context');
  const previous = Object.getOwnPropertyDescriptor(globalThis, symbol);
  Object.defineProperty(globalThis, symbol, { configurable: true, value: { get: () => context } });
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, symbol, previous);
    else delete globalThis[symbol];
  });
}

test('official SDK uses request-scoped runtime purge with immediate deletion', async t => {
  const calls = [];
  runtime(t, { purge: { dangerouslyDeleteByTag: async (...args) => calls.push(args) } });
  const cache = cacheWithoutDrain();
  assert.equal(cache.tag, RELAY_CACHE_TAG);
  assert.equal(cache.ttl, RELAY_CACHE_TTL);
  assert.equal(relayCache.readTimeoutMs, RELAY_CACHE_READ_TIMEOUT_MS);
  assert.equal(RELAY_CACHE_READ_TIMEOUT_MS, 4000);
  assert.equal(RELAY_CACHE_DRAIN_MS, 5000);
  await cache.purge();
  assert.deepEqual(calls, [['fourthciv-relay-v1', { revalidationDeadlineSeconds: 0 }]]);
});

test('missing runtime capability fails closed instead of accepting the SDK no-op', async t => {
  runtime(t, {});
  await assert.rejects(cacheWithoutDrain().purge(), error =>
    error instanceof CachePurgeError && error.code === 'runtime-unavailable');
});

test('completed failures have bounded sequential retries before success', async () => {
  let attempts = 0; let active = 0;
  const cache = cacheWithoutDrain({ retryDelaysMs: [0, 0], deleteByTag: async (tag, options) => {
    assert.equal(tag, RELAY_CACHE_TAG);
    assert.deepEqual(options, { revalidationDeadlineSeconds: 0 });
    active += 1; assert.equal(active, 1); attempts += 1;
    await delay(1); active -= 1;
    if (attempts < 3) throw new Error('Synthetic provider error');
  } });
  await cache.purge();
  assert.equal(attempts, 3);
});

test('exhausted retries discard provider messages and causes', async () => {
  let attempts = 0;
  const cache = cacheWithoutDrain({ retryDelaysMs: [0, 0], deleteByTag: async () => {
    attempts += 1; throw new Error('secret://synthetic-provider-detail');
  } });
  await assert.rejects(cache.purge(), error => {
    assert.equal(error.code, 'unavailable');
    assert.equal(error.cause, undefined);
    assert.doesNotMatch(String(error), /secret|synthetic-provider-detail/);
    return true;
  });
  assert.equal(attempts, 3);
});

test('deadline stops awaiting a stuck SDK operation without starting overlapping retries', async () => {
  let attempts = 0; let finish;
  const cache = cacheWithoutDrain({ timeoutMs: 25, retryDelaysMs: [0, 0], deleteByTag: () => {
    attempts += 1;
    return new Promise(resolve => { finish = resolve; });
  } });
  const started = Date.now();
  await assert.rejects(cache.purge(), error => error.code === 'timeout');
  assert.ok(Date.now() - started < 1000);
  assert.equal(attempts, 1);
  finish(); // An uncancellable platform operation may complete after we stop waiting.
  await delay(0);
  assert.equal(attempts, 1);
});

test('an already-aborted request performs no purge and exposes no abort reason', async () => {
  let attempts = 0;
  const cache = cacheWithoutDrain({ deleteByTag: async () => { attempts += 1; } });
  const controller = new AbortController();
  controller.abort(new Error('private-request-reason'));
  await assert.rejects(cache.purge({ signal: controller.signal }), error => {
    assert.equal(error.code, 'aborted');
    assert.doesNotMatch(String(error), /private-request-reason/);
    return true;
  });
  assert.equal(attempts, 0);
});

test('request cancellation interrupts retry delay and prevents later attempts', async () => {
  let attempts = 0;
  const controller = new AbortController();
  const cache = cacheWithoutDrain({ retryDelaysMs: [1000, 1000], deleteByTag: async () => {
    attempts += 1;
    setTimeout(() => controller.abort(), 5);
    throw new Error('Synthetic retryable error');
  } });
  await assert.rejects(cache.purge({ signal: controller.signal }), error => error.code === 'aborted');
  assert.equal(attempts, 1);
});

test('request cancellation stops waiting for an in-flight purge and consumes its late rejection', async () => {
  let attempts = 0; let fail;
  const controller = new AbortController();
  const cache = cacheWithoutDrain({ deleteByTag: () => {
    attempts += 1;
    setTimeout(() => controller.abort(), 5);
    return new Promise((_, reject) => { fail = reject; });
  } });
  await assert.rejects(cache.purge({ signal: controller.signal }), error => error.code === 'aborted');
  fail(new Error('private-late-provider-reason'));
  await delay(0);
  assert.equal(attempts, 1);
});

test('purge starts only after draining and receives its own budget after the drain', async () => {
  let attempts = 0;
  const start = performance.now();
  const cache = createRelayCache({ drainMs: 50, timeoutMs: 20, deleteByTag: async () => {
    assert.ok(performance.now() - start >= 40, 'the drain must finish before SDK deletion starts');
    attempts += 1;
  } });
  const pending = cache.purge();
  assert.equal(attempts, 0);
  await pending;
  assert.equal(attempts, 1, 'the shorter purge budget must not expire during the longer drain');
});

test('request cancellation during the production drain prevents every purge attempt', async () => {
  let attempts = 0;
  const controller = new AbortController();
  const cache = createRelayCache({ deleteByTag: async () => { attempts += 1; } });
  const pending = cache.purge({ signal: controller.signal });
  setTimeout(() => controller.abort(new Error('private-drain-cancellation')), 5);
  await assert.rejects(pending, error => {
    assert.equal(error.code, 'aborted');
    assert.doesNotMatch(String(error), /private-drain-cancellation/);
    return true;
  });
  await delay(10);
  assert.equal(attempts, 0);
});

test('a stuck purge times out after the drain and is not retried concurrently', async () => {
  let attempts = 0; let finish; let purgeStarted;
  const start = performance.now();
  const cache = createRelayCache({ drainMs: 40, timeoutMs: 25, retryDelaysMs: [0, 0], deleteByTag: () => {
    attempts += 1; purgeStarted = performance.now();
    return new Promise(resolve => { finish = resolve; });
  } });
  await assert.rejects(cache.purge(), error => error.code === 'timeout');
  assert.ok(purgeStarted - start >= 30);
  assert.ok(performance.now() - purgeStarted >= 15, 'the purge receives a separate time budget');
  assert.equal(attempts, 1);
  finish();
  await delay(0);
  assert.equal(attempts, 1);
});
