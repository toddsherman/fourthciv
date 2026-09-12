import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { database } from '../lib/database.mjs';
import { handler } from '../lib/handler.mjs';
import { clientKey } from '../lib/client.mjs';
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required; provision it before starting the relay');
clientKey('127.0.0.1', process.env.FOURTHCIV_REQUEST_KEY); // Validate configuration before listening.
const respond = handler(database, process.env.FOURTHCIV_RELAY_PEERS ?? '', (_, address) => clientKey(address, process.env.FOURTHCIV_REQUEST_KEY));
const server = createServer(async (incoming, outgoing) => {
  try {
    const request = new Request(`http://127.0.0.1${incoming.url}`, { method:incoming.method, headers:incoming.headers,
      ...(['GET','HEAD'].includes(incoming.method) ? {} : { body:Readable.toWeb(incoming), duplex:'half' }) });
    const response = await respond(request, incoming.socket.remoteAddress);
    outgoing.writeHead(response.status,Object.fromEntries(response.headers));
    outgoing.end(Buffer.from(await response.arrayBuffer()));
  } catch { outgoing.writeHead(400); outgoing.end(); }
});
server.requestTimeout = 15000; server.headersTimeout = 10000; server.maxConnections = 32;
server.listen(Number(process.env.PORT ?? 49402),'127.0.0.1',()=>console.log('Fourth Civ relay listening on loopback. Use a TLS reverse proxy for public hosting.'));
