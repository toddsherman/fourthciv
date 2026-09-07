import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile, readdir, mkdir, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';
import { handler } from '../lib/handler.mjs';
import { RelayStore } from '../lib/store.mjs';

const execute = promisify(execFile);
const root = fileURLToPath(new URL('../../', import.meta.url));

async function freePort() {
  const socket = createServer();
  await new Promise((resolve, reject) => socket.once('error', reject).listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return port;
}

test('native nodes retain and queue messages through a relay outage, then recover automatically', { timeout: 180000 }, async t => {
  assert.equal(process.platform, 'darwin', 'This native-node check requires macOS and Swift');
  const directory = await mkdtemp(join(tmpdir(), 'fourthciv-outage-'));
  const control = join(directory, 'relay-control.json');
  const report = join(directory, 'result.json');
  let db, server, child;
  t.after(async () => {
    if (child?.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
      await new Promise(resolve => child.once('exit', resolve));
    }
    if (server?.listening) {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
    if (db) await db.close();
    await rm(directory, { recursive: true, force: true });
  });
  await writeFile(control, JSON.stringify({ unavailable: false }));
  const sources = (await readdir(join(root, 'Sources/FourthCivCore')))
    .filter(name => name.endsWith('.swift')).sort().map(name => join(root, 'Sources/FourthCivCore', name));
  const executable = join(directory, 'outage-check');
  await execute('swiftc', ['-parse-as-library', ...sources, join(root, 'scripts/relay-outage-check.swift'), '-o', executable],
    { cwd: root, timeout: 30000 });
  db = new PGlite(join(directory, 'postgres'));
  await db.exec(await readFile(new URL('../schema.sql', import.meta.url), 'utf8'));
  const store = new RelayStore(async (text, params) => (await db.query(text, params)).rows);
  const responses = [];
  server = createServer(async (incoming, outgoing) => {
    try {
      const { unavailable } = JSON.parse(await readFile(control, 'utf8'));
      const respond = handler(() => {
        if (unavailable) throw new Error('Isolated test storage outage');
        return store;
      });
      const request = new Request('http://127.0.0.1' + incoming.url, {
        method: incoming.method, headers: incoming.headers,
        ...(incoming.method === 'POST' ? { body: incoming, duplex: 'half' } : {})
      });
      const response = await respond(request);
      responses.push({ status: response.status, path: incoming.url });
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      outgoing.end(Buffer.from(await response.arrayBuffer()));
    } catch {
      outgoing.writeHead(500); outgoing.end();
    }
  });
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  const portA = await freePort();
  let portB = await freePort();
  while (portB === portA) portB = await freePort();
  child = spawn(executable, ['http://127.0.0.1:' + server.address().port, directory,
    String(portA), String(portB), control, report], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', data => console.log(data.toString().trimEnd()));
  let errors = '';
  child.stderr.on('data', data => { errors += data.toString(); });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  assert.equal(code, 0, errors || 'Native outage check failed');
  assert.equal(responses.filter(value => value.status === 503).length, 2, 'Both nodes must observe the relay outage');
  assert.equal((await store.meta()).event_count, 3);
  const result = JSON.parse(await readFile(report, 'utf8'));
  assert.equal(result.passed, true);
  result.relayHTTP503Responses = responses.filter(value => value.status === 503).length;
  await writeFile(report, JSON.stringify(result, null, 2) + '\n');
  const evidence = join(root, '.local/relay-outage-check');
  await mkdir(evidence, { recursive: true });
  await copyFile(report, join(evidence, 'result.json'));
});
