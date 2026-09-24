import { neon } from '@neondatabase/serverless';
import { RelayStore } from './store.mjs';
let sql;
export function database({ signal } = {}) {
  if (!process.env.DATABASE_URL) throw new Error('Database not configured');
  if (!sql) sql = neon(process.env.DATABASE_URL);
  return new RelayStore((text, params) => sql.query(text, params, { fetchOptions: {
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(10000)]) : AbortSignal.timeout(10000)
  } }));
}
