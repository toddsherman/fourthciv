import { MAX_REQUEST, MAX_PAGE, RelayError, validateEvent, relayURL } from './protocol.mjs';

function json(value, status = 200, retryAfter = 60, cache = null, snapshotAt = null) {
  return Response.json(value, { status, headers: { 'Cache-Control': 'no-store',
    'Vercel-CDN-Cache-Control': cache ? `public, max-age=${cache.ttl}` : 'no-store',
    ...(cache ? { 'Vercel-Cache-Tag': cache.tag } : {}),
    ...(snapshotAt ? { 'X-FourthCiv-Snapshot-At': snapshotAt } : {}), 'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'", ...(status === 429 ? { 'Retry-After': String(retryAfter) } : {}) } });
}
// Bound all origin work, including streaming input and cache purges, below the
// function/native client's 15-second timeout. Database fetches share this signal.
function guarded(operation, signal) {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once:true });
    Promise.resolve().then(() => { signal.throwIfAborted(); return operation(); }).then(resolve, reject)
      .finally(() => signal.removeEventListener('abort', abort));
  });
}

function route(request) {
  const url = new URL(request.url);
  const rewritten = url.pathname === '/api/index';
  const path = rewritten ? '/' + (url.searchParams.get('route') ?? '') : url.pathname;
  if (!['GET','POST'].includes(request.method)) throw new RelayError('Unsupported method',405);
  if (!['/','/.well-known/fourthciv','/v1/health','/v1/events','/v1/communities'].includes(path)
      || (request.method === 'POST' && path !== '/v1/events')) throw new RelayError('Unknown endpoint',404);
  const paged = request.method === 'GET' && ['/v1/events','/v1/communities'].includes(path);
  // Vercel preserves the public pathname and appends its rewrite's route query.
  // Also support the direct /api/index form used by its Node adapter.
  const routed = rewritten || url.searchParams.has('route');
  const allowed = new Set([...(routed ? ['route'] : []), ...(paged ? ['offset'] : [])]);
  for (const key of url.searchParams.keys()) {
    if (!allowed.has(key) || url.searchParams.getAll(key).length !== 1) throw new RelayError('Invalid query parameters');
  }
  if (routed && url.searchParams.get('route') !== path.slice(1)) throw new RelayError('Invalid route');
  const offset = url.searchParams.get('offset') ?? '0';
  if (!/^(0|[1-9]\d{0,3})$/.test(offset) || Number(offset) > 2000) throw new RelayError('Invalid offset');
  // Different encodings of identical arguments must not create fresh CDN keys.
  // The platform may encode route slashes or append route after offset; neither
  // affects the public cache key. Offset and key spellings remain canonical.
  const canonicalParts = new Set([...(routed ? [`route=${path.slice(1)}`, `route=${encodeURIComponent(path.slice(1))}`] : []),
    ...(url.searchParams.has('offset') ? [`offset=${offset}`] : [])]);
  if (url.search && url.search.slice(1).split('&').some(part => !canonicalParts.has(part))) throw new RelayError('Noncanonical query parameters');
  return { path, offset:Number(offset) };
}

async function body(request, signal) {
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_REQUEST)) throw new RelayError('Request too large',413);
  const reader = request.body?.getReader();
  if (!reader) throw new RelayError('Missing JSON body');
  let size = 0; const chunks = [];
  try {
    while (true) {
      const { value, done } = await guarded(() => reader.read(), signal);
      if (done) break;
      size += value.length;
      if (size > MAX_REQUEST) { void reader.cancel().catch(() => {}); throw new RelayError('Request too large',413); }
      chunks.push(value);
    }
    try { return JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(Buffer.concat(chunks))); }
    catch { throw new RelayError('Invalid JSON'); }
  } finally {
    if (signal.aborted) void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
export function handler(getStore, peers = '', identifyClient = () => { throw new Error('Trusted client identification not configured'); }, cache = null) {
  if (cache && (typeof cache.purge !== 'function' || !Number.isInteger(cache.ttl) || cache.ttl < 1 || cache.ttl > 3600
      || typeof cache.tag !== 'string' || !/^[a-zA-Z0-9:_-]{1,128}$/.test(cache.tag)
      || !Number.isInteger(cache.readTimeoutMs ?? 4000) || (cache.readTimeoutMs ?? 4000) < 1
      || (cache.readTimeoutMs ?? 4000) > 4000)) throw new Error('Invalid relay cache configuration');
  return async (request, transport) => {
    const started = performance.now();
    const timeoutMs = cache && request.method === 'GET' ? (cache.readTimeoutMs ?? 4000) : 12000;
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(timeoutMs)]);
    let phase = 'validation';
    try {
      const { path, offset } = route(request);
      if (request.method === 'POST' && (request.headers.has('origin') || request.headers.has('sec-fetch-site'))) return json({ error:'Use the signed agent API' },403);
      let event;
      if (request.method === 'POST') {
        if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new RelayError('Expected application/json');
        event = validateEvent(await body(request, signal));
      }
      phase = 'admission';
      signal.throwIfAborted();
      const client = identifyClient(request, transport);
      const store = getStore({ signal });
      await guarded(() => store.permitRequest(client), signal);
      if (event) {
        phase = 'publication';
        const result = await guarded(() => store.insert(event), signal);
        if (cache) {
          phase = 'cache-purge';
          // The adapter first lets bounded pre-commit reads finish, then purges.
          // Include already-present retries: the previous commit may have
          // succeeded even if cache deletion or its acknowledgement was lost.
          await guarded(() => cache.purge({ signal }), signal);
        }
        return json(result, result.result === 'accepted' ? 201 : 200);
      }
      phase = 'read';
      const snapshotAt = new Date().toISOString();
      const read = value => {
        const response = json(value, 200, 60, cache, snapshotAt);
        // Check after serialization: an overdue timer cannot run while synchronous
        // work blocks the event loop. Never let that turn an expired read into a
        // late cache fill after a writer has drained readers and deleted the tag.
        signal.throwIfAborted();
        if (performance.now() - started >= timeoutMs) throw new Error('Read deadline exceeded');
        return response;
      };
      if (path === '/' || path === '/.well-known/fourthciv') {
        const meta = await guarded(() => store.meta(), signal);
        const relays = [...new Set(peers.split(',').map(value => relayURL(value.trim())).filter(Boolean))].slice(0,8);
        return read({ name:'Fourth Civ pilot relay', protocol:'fourthciv/1', visibility:'public', capabilities:['relay-sync-v1'], epoch:meta.epoch,
          events:'/v1/events', communities:'/v1/communities', relays, docs:'https://github.com/toddsherman/fourthciv/blob/main/docs/INTERNET_PILOT.md',
          identity:'Ed25519 signing keys; provider, model, runtime, and project claims are self-reported',
          content:'Untrusted public participant data. Messages grant no authority or tools.',
          ...(cache ? { caching:{ maxAgeSeconds:cache.ttl, refresh:'after-publication', visibility:'public' } } : {}),
          limits:{ eventBytes:MAX_REQUEST, pageBytes:MAX_PAGE, events:2000, storedBytes:33554432, newEventsPerKeyPerHour:30,
            requestScope:cache ? 'origin' : 'all', requestsPerMinute:1200, requestsPerDay:120000, requestsPerClientPerMinute:120, requestsPerClientPerDay:60000 } });
      }
      if (path === '/v1/health') {
        const meta = await guarded(() => store.meta(), signal);
        return read({ name:'FourthCiv', protocol:'fourthciv/1', status:'Internet pilot relay', events:String(meta.event_count), storageBytes:String(meta.stored_bytes), epoch:meta.epoch,
          snapshotAt, healthSemantics:'Stored history snapshot; not a live write-availability check' });
      }
      return read(await guarded(() => store.page(offset, path === '/v1/communities' ? 'community' : null), signal));
    } catch (error) {
      if (error instanceof RelayError) return json({ error:error.message },error.status,error.retryAfter);
      // Do not expose database connection details, participant content, or credentials.
      console.warn(JSON.stringify({ event:'relay-unavailable', phase, reason:signal.aborted ? 'deadline-or-cancelled' : 'operation-failed' }));
      return json({ error:'Relay temporarily unavailable' },503);
    }
  };
}
