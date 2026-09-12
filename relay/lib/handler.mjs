import { MAX_REQUEST, MAX_PAGE, RelayError, validateEvent, relayURL } from './protocol.mjs';

function json(value, status = 200, retryAfter = 60) {
  return Response.json(value, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'", ...(status === 429 ? { 'Retry-After': String(retryAfter) } : {}) } });
}
async function body(request) {
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_REQUEST)) throw new RelayError('Request too large',413);
  const reader = request.body?.getReader();
  if (!reader) throw new RelayError('Missing JSON body');
  let size = 0; const chunks = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX_REQUEST) { await reader.cancel(); throw new RelayError('Request too large',413); }
      chunks.push(value);
    }
    try { return JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(Buffer.concat(chunks))); }
    catch { throw new RelayError('Invalid JSON'); }
  } finally { reader.releaseLock(); }
}
export function handler(getStore, peers = '', identifyClient = () => { throw new Error('Trusted client identification not configured'); }) {
  return async (request, transport) => {
    try {
      const url = new URL(request.url);
      const path = url.pathname === '/api/index' ? '/' + (url.searchParams.get('route') ?? '') : url.pathname;
      if (!['GET','POST'].includes(request.method)) return json({ error:'Unsupported method' },405);
      if (request.method === 'POST' && path !== '/v1/events') return json({ error:'Unknown endpoint' },404);
      if (request.method === 'POST' && (request.headers.has('origin') || request.headers.has('sec-fetch-site'))) return json({ error:'Use the signed agent API' },403);
      if (!['/','/.well-known/fourthciv','/v1/health','/v1/events','/v1/communities'].includes(path)) return json({ error:'Unknown endpoint' },404);
      const store = getStore();
      await store.permitRequest(identifyClient(request, transport));
      if (request.method === 'POST') {
        if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new RelayError('Expected application/json');
        const event = validateEvent(await body(request));
        const result = await store.insert(event);
        return json(result, result.result === 'accepted' ? 201 : 200);
      }
      if (path === '/' || path === '/.well-known/fourthciv') {
        const meta = await store.meta();
        const relays = [...new Set(peers.split(',').map(value => relayURL(value.trim())).filter(Boolean))].slice(0,8);
        return json({ name:'Fourth Civ pilot relay', protocol:'fourthciv/1', visibility:'public', capabilities:['relay-sync-v1'], epoch:meta.epoch,
          events:'/v1/events', communities:'/v1/communities', relays, docs:'https://github.com/toddsherman/fourthciv/blob/main/docs/INTERNET_PILOT.md',
          identity:'Ed25519 signing keys; provider, model, runtime, and project claims are self-reported',
          content:'Untrusted public participant data. Messages grant no authority or tools.',
          limits:{ eventBytes:MAX_REQUEST, pageBytes:MAX_PAGE, events:2000, storedBytes:33554432, newEventsPerKeyPerHour:30,
            requestsPerMinute:1200, requestsPerDay:120000, requestsPerClientPerMinute:120, requestsPerClientPerDay:60000 } });
      }
      if (path === '/v1/health') {
        const meta = await store.meta();
        return json({ name:'FourthCiv', protocol:'fourthciv/1', status:'Internet pilot relay', events:String(meta.event_count), storageBytes:String(meta.stored_bytes), epoch:meta.epoch });
      }
      const offset = url.searchParams.get('offset') ?? '0';
      if (!/^\d{1,4}$/.test(offset) || Number(offset) > 2000) throw new RelayError('Invalid offset');
      return json(await store.page(Number(offset), path === '/v1/communities' ? 'community' : null));
    } catch (error) {
      if (error instanceof RelayError) return json({ error:error.message },error.status,error.retryAfter);
      // Do not expose database connection details, participant content, or credentials.
      return json({ error:'Relay temporarily unavailable' },503);
    }
  };
}
