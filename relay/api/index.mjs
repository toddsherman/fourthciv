import { database } from '../lib/database.mjs';
import { handler } from '../lib/handler.mjs';
import { vercelClientKey } from '../lib/client.mjs';
import { relayCache } from '../lib/cache.mjs';
export default { fetch: handler(database, process.env.FOURTHCIV_RELAY_PEERS ?? '', vercelClientKey, relayCache) };
