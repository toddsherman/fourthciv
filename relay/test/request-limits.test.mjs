import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { clientKey, vercelClientKey } from '../lib/client.mjs';
import { handler } from '../lib/handler.mjs';
import { RelayStore } from '../lib/store.mjs';

const schema = await readFile(new URL('../schema.sql', import.meta.url), 'utf8');
const secret = '18'.repeat(32); // Synthetic test key, never used by a deployed relay.
const start = Date.parse('2026-09-12T00:00:00Z');
async function context(t) {
  const db = new PGlite(); t.after(() => db.close()); await db.exec(schema);
  let now = start;
  const query = async (sql, params) => (await db.query(sql === 'SELECT fc_permit_request($1) AS permission'
    ? 'SELECT fc_permit_request($1,$2::timestamptz) AS permission' : sql,
    sql === 'SELECT fc_permit_request($1) AS permission' ? [...params, new Date(now).toISOString()] : params)).rows;
  const store = new RelayStore(query);
  const respond = handler(() => store, '', (_, address) => clientKey(address, secret, now));
  const call = (address = '192.0.2.1', headers = {}) => respond(new Request('https://relay.example/v1/health', { headers }), address);
  const budget = async () => (await db.query('SELECT minute_count,day_count FROM fc_request_budget')).rows[0];
  return { db, store, query, respond, call, budget, setTime: value => { now = value; } };
}

test('client keys normalize network aliases, rotate daily, and fail closed', () => {
  const key = address => clientKey(address, secret, start);
  assert.equal(key('192.0.2.1'), key('::ffff:192.0.2.1'));
  assert.equal(key('192.0.2.1'), key('::ffff:c000:201'));
  assert.equal(key('2001:db8::1'), key('2001:0db8:0000:0000:abcd:1:2:3'));
  assert.notEqual(key('2001:db8::1'), key('2001:db8:0:1::1'));
  assert.notEqual(key('192.0.2.1'), clientKey('192.0.2.1', secret, start + 86400000));
  assert.notEqual(key('192.0.2.1'), clientKey('192.0.2.1', '29'.repeat(32), start));
  for (const value of [undefined, '', 'unknown', '192.0.2.1, 198.51.100.1', '192.000.2.1', '[::1]', 'fe80::1%en0']) {
    assert.throws(() => key(value));
  }
  for (const value of [undefined, '', 'short', 'z'.repeat(64)]) assert.throws(() => clientKey('192.0.2.1', value));
});

test('Vercel adapter uses only its protected header and requires its deployment context', () => {
  const previous = { VERCEL: process.env.VERCEL, FOURTHCIV_REQUEST_KEY: process.env.FOURTHCIV_REQUEST_KEY };
  try {
    process.env.VERCEL = '1'; process.env.FOURTHCIV_REQUEST_KEY = secret;
    const request = new Request('https://relay.example', { headers: {
      'x-vercel-forwarded-for': '192.0.2.1', 'x-forwarded-for': '203.0.113.9', 'x-real-ip': '203.0.113.10'
    } });
    const expected = vercelClientKey(request);
    request.headers.set('x-forwarded-for', '198.51.100.7');
    request.headers.set('x-real-ip', '198.51.100.8');
    assert.equal(vercelClientKey(request), expected);
    request.headers.delete('x-vercel-forwarded-for'); assert.throws(() => vercelClientKey(request));
    request.headers.set('x-vercel-forwarded-for', '192.0.2.1');
    process.env.VERCEL = '0'; assert.throws(() => vercelClientKey(request));
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});

test('one noisy network cannot consume another host allowance, even with forged forwarding headers', async t => {
  const { call, budget, db, setTime, respond } = await context(t);
  for (let i = 0; i < 120; i++) assert.equal((await call()).status, 200);
  for (let i = 0; i < 600; i++) {
    const denied = await call('192.0.2.1', { 'x-forwarded-for': `198.51.100.${i % 250 + 1}`, 'x-vercel-forwarded-for': '203.0.113.99' });
    assert.equal(denied.status, 429); assert.equal(denied.headers.get('Retry-After'), '60');
  }
  assert.deepEqual(await budget(), { minute_count: 120, day_count: 120 });
  assert.equal((await call('192.0.2.2')).status, 200);
  const discovery = await respond(new Request('https://relay.example/.well-known/fourthciv'), '192.0.2.2');
  const { limits } = await discovery.json();
  assert.equal(limits.requestsPerClientPerMinute, 120); assert.equal(limits.requestsPerDay, 120000);
  const rows = (await db.query('SELECT client FROM fc_request_clients')).rows;
  assert.ok(rows.every(({ client }) => /^[a-f0-9]{64}$/.test(client)));
  assert.doesNotMatch(JSON.stringify(rows), /192\.0\.2/);
  setTime(start + 60000);
  assert.equal((await call()).status, 200);
});

test('daily limits persist across instances and recover at UTC midnight without charging rejected requests', async t => {
  const { db, store, query, call, budget, setTime } = await context(t);
  await call();
  await db.query('UPDATE fc_request_clients SET day_count=59999');
  await db.query('UPDATE fc_request_budget SET day_count=59999');
  setTime(start + 123000);
  assert.equal((await call()).status, 200);
  const otherInstance = new RelayStore(query);
  await assert.rejects(otherInstance.permitRequest(clientKey('192.0.2.1', secret, start)), error => error.status === 429 && error.retryAfter === 86277);
  assert.equal((await budget()).day_count, 60000);
  assert.equal((await call('192.0.2.2')).status, 200);
  assert.equal((await budget()).day_count, 60001);
  setTime(start + 86400000);
  assert.equal((await call()).status, 200);
  assert.deepEqual(await budget(), { minute_count: 1, day_count: 1 });
  // Old rotating keys are removed on the first admitted/denied request two days later.
  setTime(start + 2 * 86400000); await call();
  assert.equal((await db.query('SELECT count(*)::int AS count FROM fc_request_clients')).rows[0].count, 2);
  await assert.rejects(store.permitRequest('192.0.2.1'));
});

test('concurrent instances cannot overspend source or global allowances', async t => {
  const { db, query, budget, setTime } = await context(t);
  const key = clientKey('192.0.2.1', secret, start);
  const sameSource = await Promise.allSettled(Array.from({ length: 140 }, () => new RelayStore(query).permitRequest(key)));
  assert.equal(sameSource.filter(value => value.status === 'fulfilled').length, 120);
  assert.deepEqual(await budget(), { minute_count: 120, day_count: 120 });
  setTime(start + 60000);
  // Start one minute with ten global slots left, then race independent clients.
  const minute = Math.floor((start + 60000) / 60000);
  await db.query('UPDATE fc_request_budget SET minute=$1,minute_count=1190', [minute]);
  const differentSources = await Promise.allSettled(Array.from({ length: 20 }, (_, i) =>
    new RelayStore(query).permitRequest(clientKey(`198.51.100.${i + 1}`, secret, start))));
  assert.equal(differentSources.filter(value => value.status === 'fulfilled').length, 10);
  assert.equal((await budget()).minute_count, 1200);
  assert.equal((await db.query('SELECT count(*)::int AS count FROM fc_request_clients')).rows[0].count, 11);
});

test('global daily guard bounds admission and does not create client rows while exhausted', async t => {
  const { db, call, budget, setTime } = await context(t);
  await call(); await db.query('UPDATE fc_request_budget SET day_count=119999');
  assert.equal((await call()).status, 200);
  for (let i = 1; i <= 10; i++) {
    const denied = await call(`198.51.100.${i}`);
    assert.equal(denied.status, 429); assert.equal(denied.headers.get('Retry-After'), '86400');
  }
  assert.equal((await budget()).day_count, 120000);
  assert.equal((await db.query('SELECT count(*)::int AS count FROM fc_request_clients')).rows[0].count, 1);
  setTime(start + 86400000); assert.equal((await call('198.51.100.1')).status, 200);
});

test('eight hosts fit a full day of worst-case 30-second polling alongside one exhausted source', { timeout: 120000 }, async t => {
  const { db } = await context(t);
  // Reserve the full permitted daily traffic of a separate noisy source. Exercise
  // every discovery/page admission for eight hosts, rather than just checking arithmetic.
  await db.query('SELECT fc_permit_request($1,$2::timestamptz)', ['f'.repeat(64), new Date(start).toISOString()]);
  await db.query('UPDATE fc_request_budget SET day_count=60000');
  await db.query('UPDATE fc_request_clients SET day_count=60000');
  // Commit each simulated hour, as real HTTP requests do. One day-long SQL
  // transaction would accumulate obsolete row versions and distort this check.
  for (let firstSlot = 0; firstSlot < 2880; firstSlot += 120) {
    await db.exec(`DO $$
    DECLARE slot integer; host integer; request integer; permission jsonb;
    BEGIN
      FOR slot IN ${firstSlot}..${firstSlot + 119} LOOP
        FOR host IN 1..8 LOOP
          FOR request IN 1..2 LOOP
            permission := fc_permit_request(lpad(to_hex(host),64,'0'),
              '2026-09-12T00:00:00Z'::timestamptz + slot * interval '30 seconds');
            IF (permission->>'allowed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'legitimate-fleet-throttled'; END IF;
          END LOOP;
        END LOOP;
      END LOOP;
    END $$;`);
  }
  assert.equal((await db.query('SELECT day_count FROM fc_request_budget')).rows[0].day_count, 106080);
  assert.ok((await db.query("SELECT day_count FROM fc_request_clients WHERE client <> $1", ['f'.repeat(64)])).rows.every(row => row.day_count === 5760));
});

test('missing transport identity fails closed', async t => {
  const { store, respond } = await context(t);
  assert.equal((await respond(new Request('https://relay.example/v1/health'))).status, 503);
  const unconfigured = handler(() => store);
  const denied = await unconfigured(new Request('https://relay.example/v1/health', { headers: { 'x-forwarded-for': '192.0.2.1' } }));
  assert.equal(denied.status, 503); assert.doesNotMatch(await denied.text(), /192\.0\.2|key|address/);
});

test('upgrading the exact alpha.10 schema preserves history, publication counters, and epoch', async t => {
  const db = new PGlite(); t.after(() => db.close());
  // Frozen from 35dda6c:relay/schema.sql, so this exercises an actual old database.
  await db.exec(await readFile(new URL('./fixtures/schema-alpha10.sql', import.meta.url), 'utf8'));
  const store = new RelayStore(async (sql, params) => (await db.query(sql, params)).rows);
  const original = await store.meta();
  await db.query("INSERT INTO fc_events VALUES(0,'fixture','community','fixture','','{}')");
  await db.query('UPDATE fc_meta SET event_count=1,stored_bytes=2');
  await db.query("SELECT fc_take('publish-all',120,60),fc_take('requests-day',20000,86400)");
  const oldRates = (await db.query('SELECT * FROM fc_rates ORDER BY scope')).rows;
  await db.exec(schema);
  await db.exec(schema); // A repeated migration must also be harmless.
  assert.equal((await store.meta()).epoch, original.epoch);
  assert.equal((await store.meta()).event_count, 1);
  assert.equal((await db.query('SELECT count(*)::int AS count FROM fc_events')).rows[0].count, 1);
  assert.deepEqual((await db.query('SELECT * FROM fc_rates ORDER BY scope')).rows, oldRates);
  await store.permitRequest('a'.repeat(64));
  assert.equal((await db.query('SELECT day_count FROM fc_request_budget')).rows[0].day_count, 1);
});
