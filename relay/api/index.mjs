import { database } from '../lib/database.mjs';
import { handler } from '../lib/handler.mjs';
export default { fetch: handler(database, process.env.FOURTHCIV_RELAY_PEERS ?? '') };
