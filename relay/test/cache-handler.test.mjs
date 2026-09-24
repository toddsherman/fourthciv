import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { handler } from '../lib/handler.mjs';
import { RelayStore } from '../lib/store.mjs';
import { RelayError, signingBytes } from '../lib/protocol.mjs';
import { setTimeout as delay } from 'node:timers/promises';

const schema = await readFile(new URL('../schema.sql', import.meta.url), 'utf8');
const tag = 'fourthciv-relay:test';
const client = () => 'c'.repeat(64);
const meta = { epoch: randomUUID(), event_count: 0, stored_bytes: 0 };
const cache = purge => ({ tag, ttl: 3600, purge });

function signedEvent(overrides = {}) {
  const key = generateKeyPairSync('ed25519');
  const value = { version: 1, id: '', kind: 'community',
    author: key.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64'),
    attribution: { name: 'Cache test', provider: '', model: '', runtime: 'Integration test', project: '' },
    createdAt: Date.now(), nonce: randomUUID(), community: '', parent: '',
    title: 'Cache test town', body: 'Public test conversation', signature: '', ...overrides };
  const bytes = signingBytes(value);
  value.id = createHash('sha256').update(bytes).digest('hex');
  value.signature = sign(null, bytes, key.privateKey).toString('base64');
  return value;
}

function request(path, event, headers = {}) {
  return new Request(`https://relay.example${path}`, event === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(event),
  });
}

function assertNotCached(response) {
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Vercel-CDN-Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Vercel-Cache-Tag'), null);
}

function assertCached(response) {
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(response.headers.get('Vercel-CDN-Cache-Control') ?? '', /^public,\s*max-age=3600$/);
  assert.equal(response.headers.get('Vercel-Cache-Tag'), tag);
  assert.ok(Number.isFinite(Date.parse(response.headers.get('X-FourthCiv-Snapshot-At'))));
}

function readStore() {
  return { permitRequest: async () => {}, meta: async () => meta,
    page: async offset => ({ events: [], cursor: offset, next: null, epoch: meta.epoch }) };
}

async function database(t) {
  const db = new PGlite();
  t.after(() => db.close());
  await db.exec(schema);
  const store = new RelayStore(async (text, params) => (await db.query(text, params)).rows);
  return { db, store };
}

test('all successful public reads use the shared tag while clients remain uncached', async () => {
  let purges = 0;
  const respond = handler(readStore, '', client, cache(async () => { purges += 1; }));
  for (const path of ['/', '/.well-known/fourthciv', '/v1/health', '/v1/events',
    '/v1/events?offset=0', '/v1/communities', '/v1/communities?offset=0',
    '/?route=', '/.well-known/fourthciv?route=.well-known/fourthciv',
    '/.well-known/fourthciv?route=.well-known%2Ffourthciv',
    '/v1/health?route=v1/health', '/v1/health?route=v1%2Fhealth',
    '/v1/events?route=v1/events', '/v1/events?route=v1/events&offset=0',
    '/v1/events?offset=0&route=v1/events', '/v1/events?offset=0&route=v1%2Fevents',
    '/v1/communities?route=v1/communities&offset=0',
    '/v1/communities?offset=0&route=v1%2Fcommunities',
    '/api/index?route=', '/api/index?route=.well-known/fourthciv',
    '/api/index?route=v1/health', '/api/index?route=v1/events&offset=0',
    '/api/index?offset=0&route=v1/events', '/api/index?route=v1%2Fevents&offset=0',
    '/api/index?offset=0&route=v1%2Fevents',
    '/api/index?route=v1/communities&offset=0']) {
    const response = await respond(request(path));
    assertCached(response);
  }
  assert.equal(purges, 0, 'reads never invalidate the cache');
  const discovery = await (await respond(request('/.well-known/fourthciv'))).json();
  assert.equal(discovery.limits.requestScope, 'origin');
  assert.deepEqual(discovery.caching, { maxAgeSeconds: 3600, refresh: 'after-publication', visibility: 'public' });
  const healthResponse = await respond(request('/v1/health'));
  const health = await healthResponse.json();
  assert.equal(health.snapshotAt, healthResponse.headers.get('X-FourthCiv-Snapshot-At'));
  assert.equal(health.healthSemantics, 'Stored history snapshot; not a live write-availability check');
});

test('standalone handler preserves uncached operation without a purge adapter', async () => {
  const respond = handler(readStore, '', client);
  for (const path of ['/', '/.well-known/fourthciv', '/v1/health', '/v1/events', '/v1/communities']) {
    const response = await respond(request(path));
    assert.equal(response.status, 200);
    assertNotCached(response);
  }
  const discovery = await (await respond(request('/.well-known/fourthciv'))).json();
  assert.equal(discovery.limits.requestScope, 'all');
  assert.equal(discovery.caching, undefined);
});

test('noncanonical routes and parameters are rejected before any database access', async () => {
  let stores = 0;
  let purges = 0;
  const respond = handler(() => { stores += 1; return readStore(); }, '', client,
    cache(async () => { purges += 1; }));
  const paths = [
    '/missing', '/v1/events/', '/v1/health?offset=0', '/?offset=0',
    '/.well-known/fourthciv?offset=0', '/v1/events?offset=-1',
    '/v1/events?offset=2001', '/v1/events?offset=00', '/v1/events?offset=01',
    '/v1/events?offset=%30', '/v1/events?offset=%31', '/v1/events?%6fffset=0',
    '/v1/events?offset=', '/v1/events?offset=1.0', '/v1/events?offset=+1',
    '/v1/events?offset=0&offset=0', '/v1/events?unused=1',
    '/v1/events?offset=0&unused=1', '/v1/events?route=v1/health',
    '/v1/health?route=v1/events', '/.well-known/fourthciv?route=missing',
    '/v1/events?route=v1/events&route=v1/events',
    '/v1/events?offset=0&route=v1/events&route=v1%2Fevents',
    '/v1/events?offset=%30&route=v1/events', '/v1/events?route=v1/events&offset=00',
    '/v1/events?offset=0&route=v1/events&unused=1',
    '/v1/communities?offset=0001', '/v1/communities?offset=0&offset=1',
    '/api/index', '/api/index?route=missing', '/api/index?route=v1/events/',
    '/api/index?route=v1/events&route=v1/events',
    '/api/index?route=v1/events&offset=0&unused=1',
    '/api/index?route=v1/events&offset=%30',
    '/api/index?route=v1/health&offset=0',
  ];
  for (const path of paths) {
    const response = await respond(request(path));
    assert.ok(response.status >= 400 && response.status < 500, `${path}: ${response.status}`);
    assertNotCached(response);
  }
  const post = signedEvent();
  for (const path of ['/v1/events?offset=0', '/v1/events?unused=1',
    '/api/index?route=v1/events&offset=0', '/v1/communities']) {
    const response = await respond(request(path, post));
    assert.ok(response.status >= 400 && response.status < 500, `${path}: ${response.status}`);
    assertNotCached(response);
  }
  for (const method of ['PUT', 'DELETE', 'OPTIONS']) {
    const response = await respond(new Request('https://relay.example/v1/events', { method }));
    assert.equal(response.status, 405);
    assertNotCached(response);
  }
  assert.equal(stores, 0);
  assert.equal(purges, 0);
});

test('malformed or unsigned publications never open the database or purge cached reads', async () => {
  let stores = 0;
  let purges = 0;
  const respond = handler(() => { stores += 1; return readStore(); }, '', client,
    cache(async () => { purges += 1; }));
  const valid = signedEvent();
  const invalid = [
    request('/v1/events', { ...valid, body: 'tampered' }),
    request('/v1/events', { ...valid, extra: 'unsigned' }),
    request('/v1/events', valid, { 'Content-Type': 'text/plain' }),
    request('/v1/events', valid, { Origin: 'https://browser.example' }),
    request('/v1/events', valid, { 'Content-Length': '90000' }),
    new Request('https://relay.example/v1/events', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: '{' }),
  ];
  for (const item of invalid) {
    const response = await respond(item);
    assert.ok(response.status >= 400 && response.status < 500);
    assertNotCached(response);
  }
  assert.equal(stores, 0);
  assert.equal(purges, 0);
});

test('origin refusals and failures stay uncached and cannot expose sensitive errors', async () => {
  for (const failure of [new RelayError('Admission denied', 429, 42), new Error('secret://database-credentials')]) {
    let purges = 0;
    const store = { ...readStore(), permitRequest: async () => { throw failure; } };
    const respond = handler(() => store, '', client, cache(async () => { purges += 1; }));
    const response = await respond(request('/v1/events?offset=0'));
    assert.equal(response.status, failure instanceof RelayError ? 429 : 503);
    assertNotCached(response);
    assert.doesNotMatch(await response.text(), /secret|credentials/);
    if (failure instanceof RelayError) assert.equal(response.headers.get('Retry-After'), '42');
    assert.equal(purges, 0);
  }
});

test('committed publications and duplicate retries purge before success without changing event history', async t => {
  const { store } = await database(t);
  const town = signedEvent();
  let purges = 0;
  const respond = handler(() => store, '', client, cache(async ({ signal }) => {
    assert.ok(signal instanceof AbortSignal);
    assert.equal(signal.aborted, false);
    assert.deepEqual((await store.page(0)).events, [town], 'purge happens after durable commit');
    purges += 1;
  }));
  const first = await respond(request('/v1/events', town));
  assert.equal(first.status, 201);
  assertNotCached(first);
  assert.deepEqual(await first.json(), { id: town.id, result: 'accepted' });
  assert.equal(purges, 1);
  for (const path of ['/api/index?route=v1/events', '/v1/events?route=v1/events',
    '/v1/events?route=v1%2Fevents']) {
    const duplicate = await respond(request(path, town));
    assert.equal(duplicate.status, 200);
    assertNotCached(duplicate);
    assert.deepEqual(await duplicate.json(), { id: town.id, result: 'already-present' });
  }
  assert.equal(purges, 4);
  const pageResponse = await respond(request('/v1/events?offset=0'));
  assertCached(pageResponse);
  const page = await pageResponse.json();
  assert.deepEqual(page.events, [town]);
  assert.equal(page.cursor, 1);
  assert.equal(page.next, null);
  assert.equal((await store.meta()).event_count, 1);
});

test('a publication success response waits for cache deletion to complete', { timeout: 2000 }, async () => {
  const town = signedEvent();
  let releasePurge;
  let enterPurge;
  const blocked = new Promise(resolve => { releasePurge = resolve; });
  const entered = new Promise(resolve => { enterPurge = resolve; });
  const store = { ...readStore(), insert: async value => ({ id: value.id, result: 'accepted' }) };
  const respond = handler(() => store, '', client, cache(async () => {
    enterPurge();
    await blocked;
  }));
  let settled = false;
  const pending = respond(request('/v1/events', town)).then(response => {
    settled = true;
    return response;
  });
  await entered;
  try {
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(settled, false, 'the caller must not receive success while deletion is still pending');
  } finally {
    releasePurge();
  }
  assert.equal((await pending).status, 201);
});

test('purge failure after commit returns a safe error and a repeated signed event repairs without duplication', async t => {
  const { store } = await database(t);
  const town = signedEvent();
  let fail = true;
  let purges = 0;
  const respond = handler(() => store, '', client, cache(async () => {
    purges += 1;
    if (fail) throw new Error('secret://purge-access-token');
  }));
  const failed = await respond(request('/v1/events', town));
  assert.equal(failed.status, 503);
  assertNotCached(failed);
  assert.doesNotMatch(await failed.text(), /secret|access-token/);
  assert.equal((await store.meta()).event_count, 1, 'publication survives a failed cache deletion');
  const attempts = purges;
  assert.ok(attempts > 0);
  const visible = await respond(request('/v1/events?offset=0'));
  assertCached(visible);
  assert.deepEqual((await visible.json()).events, [town], 'a fresh read can expose the committed event despite purge failure');
  assert.equal(purges, attempts, 'a later read is not a guaranteed repair for other cached snapshots');
  fail = false;
  const retry = await respond(request('/v1/events', town));
  assert.equal(retry.status, 200);
  assertNotCached(retry);
  assert.deepEqual(await retry.json(), { id: town.id, result: 'already-present' });
  assert.ok(purges > attempts, 'already-present retry still deletes the tag');
  assert.deepEqual((await store.page(0)).events, [town]);
});

test('failed database commits never trigger purge or publication success', async () => {
  let purges = 0;
  const store = { ...readStore(), insert: async () => { throw new Error('secret://unavailable-database'); } };
  const respond = handler(() => store, '', client, cache(async () => { purges += 1; }));
  const response = await respond(request('/v1/events', signedEvent()));
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.doesNotMatch(await response.text(), /secret|unavailable-database/);
  assert.equal(purges, 0);
});

test('an already-cancelled request never starts a database operation', async () => {
  const controller = new AbortController();
  controller.abort(new Error('secret://cancel-reason'));
  let operations = 0;
  let purges = 0;
  const store = { ...readStore(), permitRequest: async () => { operations += 1; } };
  const respond = handler(() => store, '', client, cache(async () => { purges += 1; }));
  const response = await respond(new Request('https://relay.example/v1/events', { signal: controller.signal }));
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.doesNotMatch(await response.text(), /secret|cancel-reason/);
  assert.equal(operations, 0);
  assert.equal(purges, 0);
});

test('cancelling a stalled streaming body releases it without database or cache work', { timeout: 2000 }, async () => {
  const controller = new AbortController();
  let cancelBody;
  const cancelled = new Promise(resolve => { cancelBody = resolve; });
  let stores = 0;
  let purges = 0;
  const respond = handler(() => { stores += 1; return readStore(); }, '', client,
    cache(async () => { purges += 1; }));
  const stream = new ReadableStream({
    start(streamController) { streamController.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelBody(); },
  });
  const pending = respond(new Request('https://relay.example/v1/events', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: stream,
    duplex: 'half', signal: controller.signal,
  }));
  await new Promise(resolve => setImmediate(resolve));
  controller.abort();
  const response = await pending;
  await cancelled;
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.equal(stores, 0);
  assert.equal(purges, 0);
  assert.equal(stream.locked, false);
});

test('cancellation reaches database work and bounds a stalled admission', { timeout: 2000 }, async () => {
  const controller = new AbortController();
  let startAdmission;
  const started = new Promise(resolve => { startAdmission = resolve; });
  let storeSignal;
  let reads = 0;
  const respond = handler(({ signal }) => {
    storeSignal = signal;
    return { ...readStore(), permitRequest: () => { startAdmission(); return new Promise(() => {}); },
      page: async () => { reads += 1; throw new Error('should not read'); } };
  }, '', client, cache(async () => { throw new Error('should not purge'); }));
  const pending = respond(new Request('https://relay.example/v1/events', { signal: controller.signal }));
  await started;
  controller.abort();
  const response = await pending;
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.equal(storeSignal.aborted, true);
  assert.equal(reads, 0);
});

test('cancellation during purge reports failure while preserving the completed publication', { timeout: 2000 }, async () => {
  const controller = new AbortController();
  let startPurge;
  const started = new Promise(resolve => { startPurge = resolve; });
  let committed = false;
  let purgeSignal;
  const town = signedEvent();
  const store = { ...readStore(), insert: async value => {
    committed = true;
    return { id: value.id, result: 'accepted' };
  } };
  const respond = handler(() => store, '', client, cache(({ signal }) => {
    purgeSignal = signal;
    startPurge();
    return new Promise(() => {});
  }));
  const pending = respond(new Request(request('/v1/events', town), { signal: controller.signal }));
  await started;
  controller.abort();
  const response = await pending;
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.equal(committed, true);
  assert.equal(purgeSignal.aborted, true);
});

test('cacheable reads have a bounded deadline that reaches a stalled database call', async () => {
  let storeSignal;
  const respond = handler(({ signal }) => {
    storeSignal = signal;
    return { ...readStore(), page: () => new Promise(() => {}) };
  }, '', client, { ...cache(async () => {}), readTimeoutMs: 30 });
  // Keep the test alive: AbortSignal.timeout deliberately does not keep Node up.
  const response = await Promise.race([respond(request('/v1/events')), delay(500).then(() => { throw new Error('Unbounded read'); })]);
  assert.equal(response.status, 503);
  assertNotCached(response);
  assert.equal(storeSignal.aborted, true);
});

test('an overdue synchronous response cannot enter the cache before its timer fires', async () => {
  const store = { ...readStore(), page: async () => ({ toJSON() {
    const started = performance.now();
    while (performance.now() - started < 50) { /* Simulate blocked serialization. */ }
    return { events: [], cursor: 0, next: null, epoch: meta.epoch };
  } }) };
  const respond = handler(() => store, '', client, { ...cache(async () => {}), readTimeoutMs: 30 });
  const response = await respond(request('/v1/events'));
  assert.equal(response.status, 503);
  assertNotCached(response);
});

test('publication keeps its longer deadline while readers have a shorter budget', async () => {
  const store = { ...readStore(), insert: async event => {
    await delay(60);
    return { id: event.id, result: 'accepted' };
  } };
  const respond = handler(() => store, '', client, { ...cache(async () => {}), readTimeoutMs: 30 });
  const response = await respond(request('/v1/events', signedEvent()));
  assert.equal(response.status, 201);
  assertNotCached(response);
});
