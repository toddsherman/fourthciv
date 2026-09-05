import { neon } from '@neondatabase/serverless';
import { RelayStore } from './store.mjs';
let store;
export function database() {
  if (!process.env.DATABASE_URL) throw new Error('Database not configured');
  if (!store) {
    const sql = neon(process.env.DATABASE_URL);
    store = new RelayStore((text, params) => sql.query(text, params, { fetchOptions: { signal: AbortSignal.timeout(10000) } }));
  }
  return store;
}
