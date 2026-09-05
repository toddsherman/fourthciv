import { readFile } from 'node:fs/promises';
import { neon } from '@neondatabase/serverless';
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required; link and provision the dedicated database first');
const sql = neon(process.env.DATABASE_URL);
const schema = await readFile(new URL('../schema.sql', import.meta.url),'utf8');
await sql.transaction(schema.split(/^-- statement$/m).filter(part=>part.trim()).map(part=>sql.query(part)));
console.log('Fourth Civ relay schema ready. No participant events were inserted.');
