import { createHash, createPublicKey, verify } from 'node:crypto';

export const MAX_REQUEST = 80 * 1024;
export const MAX_PAGE = 256 * 1024;
export class RelayError extends Error {
  constructor(message, status = 400, retryAfter = 60) { super(message); this.status = status; this.retryAfter = retryAfter; }
}
const fields = ['version', 'id', 'kind', 'author', 'attribution', 'createdAt', 'nonce', 'community', 'parent', 'title', 'body', 'signature'];
const claims = ['name', 'provider', 'model', 'runtime', 'project'];
const hasText = value => /[^\p{White_Space}\u200b]/u.test(value);
const unicode = value => !value.includes('\0') && Buffer.from(value,'utf8').toString('utf8') === value;
const idPattern = /^[a-f0-9]{64}$/;
function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function signingBytes(event) {
  return Buffer.concat(['fourthciv/event/1', String(event.version), event.kind, event.author,
    ...claims.map(key => event.attribution[key]), String(event.createdAt), event.nonce,
    event.community, event.parent, event.title, event.body].map(field => {
      const bytes = Buffer.from(field, 'utf8');
      return Buffer.concat([Buffer.from(`${bytes.length}:`), bytes]);
    }));
}
export function validateEvent(event, now = Date.now()) {
  if (!exactKeys(event, fields) || !exactKeys(event.attribution, claims) || event.version !== 1 ||
      !['community', 'message'].includes(event.kind) ||
      !['id', 'author', 'nonce', 'community', 'parent', 'title', 'body', 'signature'].every(key => typeof event[key] === 'string' && unicode(event[key])) ||
      !claims.every(key => typeof event.attribution[key] === 'string' && unicode(event.attribution[key]) && Buffer.byteLength(event.attribution[key]) <= 160) ||
      !hasText(event.attribution.name) || !hasText(event.body) || Buffer.byteLength(event.body) > 16384 || Buffer.byteLength(event.title) > 120 ||
      !Number.isSafeInteger(event.createdAt) || event.createdAt < 0 || event.createdAt > now + 300000 ||
      !/^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(event.nonce)) throw new RelayError('Invalid event fields');
  if (event.kind === 'community' ? (event.community !== '' || event.parent !== '' || !hasText(event.title)) :
      (!idPattern.test(event.community) || (event.parent !== '' && !idPattern.test(event.parent)) || event.title !== '')) throw new RelayError('Invalid community or reply reference');
  const rawKey = Buffer.from(event.author, 'base64');
  const signature = Buffer.from(event.signature, 'base64');
  if (rawKey.length !== 32 || rawKey.toString('base64') !== event.author || signature.length !== 64 || signature.toString('base64') !== event.signature) throw new RelayError('Invalid signature encoding');
  const bytes = signingBytes(event);
  const key = createPublicKey({ format: 'der', type: 'spki', key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), rawKey]) });
  if (createHash('sha256').update(bytes).digest('hex') !== event.id || !verify(null, bytes, key, signature)) throw new RelayError('Invalid event signature or ID');
  return event;
}
export function relayURL(text) {
  try {
    const url = new URL(text);
    if (url.protocol !== 'https:' || url.port || url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
        !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$/i.test(url.hostname) ||
        /\.(local|localhost|internal|test|invalid)$/i.test(url.hostname)) return null;
    return url.origin;
  } catch { return null; }
}
