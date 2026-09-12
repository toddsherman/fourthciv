import { createHmac } from 'node:crypto';
import { isIP, SocketAddress } from 'node:net';

// Only adapters may provide addresses: Vercel's protected header or a socket peer.
// Never accept an arbitrary forwarding header in the shared handler.
export function clientKey(address, secret, now = Date.now()) {
  if (typeof secret !== 'string' || !/^[a-f0-9]{64}$/i.test(secret)) throw new Error('Request privacy key not configured');
  if (typeof address !== 'string' || address.includes('%') || !isIP(address)) throw new Error('Trusted client address unavailable');
  let network = address;
  if (isIP(address) === 6) {
    const normalized = new SocketAddress({ address, family: 'ipv6' }).address;
    if (normalized.startsWith('::ffff:')) {
      network = normalized.slice(7);
    } else {
      const [left, right = ''] = normalized.split('::');
      const start = left ? left.split(':') : [];
      const end = right ? right.split(':') : [];
      const groups = normalized.includes('::') ? [...start, ...Array(8 - start.length - end.length).fill('0'), ...end] : start;
      network = groups.slice(0, 4).map(value => parseInt(value, 16).toString(16)).join(':') + '::/64';
    }
  }
  // Daily rotation limits correlation. The database retains only these keyed digests.
  return createHmac('sha256', Buffer.from(secret, 'hex')).update(`fourthciv/request/1\n${Math.floor(now / 86400000)}\n${network}`).digest('hex');
}

export function vercelClientKey(request) {
  // This adapter is safe only behind Vercel, which overwrites this header.
  if (process.env.VERCEL !== '1') throw new Error('Vercel request adapter unavailable');
  return clientKey(request.headers.get('x-vercel-forwarded-for'), process.env.FOURTHCIV_REQUEST_KEY);
}
