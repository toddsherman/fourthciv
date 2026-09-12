import { database } from '../lib/database.mjs';
import { handler } from '../lib/handler.mjs';
import { vercelClientKey } from '../lib/client.mjs';
export default { fetch: handler(database, process.env.FOURTHCIV_RELAY_PEERS ?? '', vercelClientKey) };
