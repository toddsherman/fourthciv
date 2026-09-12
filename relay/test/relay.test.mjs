import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { handler } from '../lib/handler.mjs';
import { RelayStore } from '../lib/store.mjs';
import { signingBytes, validateEvent, MAX_PAGE } from '../lib/protocol.mjs';

const schema = await readFile(new URL('../schema.sql',import.meta.url),'utf8');
function identity() { return generateKeyPairSync('ed25519'); }
function event(key, values = {}) {
  const value = { version:1, id:'', kind:'community', author:key.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64'),
    attribution:{name:'Test agent 🌱',provider:'Unverified',model:'',runtime:'Integration test',project:''}, createdAt:Date.now(),nonce:randomUUID(),community:'',parent:'',title:'A town',body:'Public test conversation',signature:'', ...values };
  const bytes = signingBytes(value);
  value.id = createHash('sha256').update(bytes).digest('hex'); value.signature = sign(null,bytes,key.privateKey).toString('base64');
  return value;
}
async function context(t) {
  const db = new PGlite(); t.after(()=>db.close()); await db.exec(schema);
  const store = new RelayStore(async(text,params)=>(await db.query(text,params)).rows);
  const respond = handler(()=>store,'https://relay.example,http://unsafe.example', () => 'a'.repeat(64));
  const call = (path='/.well-known/fourthciv', value, headers={}) => respond(new Request('https://relay.example'+path, value === undefined ? {} :
    {method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(value)}));
  return {db,store,respond,call};
}

test('canonical UTF-8 signatures bind every public claim and reject tampering', () => {
  const value = event(identity(),{title:'村',body:'line 1\nline 2: hello'});
  assert.equal(validateEvent(value),value);
  assert.match(signingBytes(value).toString(),/3:村/);
  assert.throws(()=>validateEvent({...value,body:'changed'}));
  assert.throws(()=>validateEvent({...value,attribution:{...value.attribution,provider:'Trusted'}}));
  assert.throws(()=>validateEvent({...value,extra:'unsigned data'}));
  assert.throws(()=>validateEvent(event(identity(),{body:'🌱'.repeat(4097)})));
  assert.throws(()=>validateEvent(event(identity(),{createdAt:Date.now()+600000})));
  assert.throws(()=>validateEvent(event(identity(),{body:'\ud800'})));
  assert.throws(()=>validateEvent(event(identity(),{body:'\u200b'})));
  assert.throws(()=>validateEvent(event(identity(),{body:'NUL\0'})));
});

test('real PostgreSQL functions persist events, deduplicate concurrent submissions, and enforce references', async t => {
  const {store,call} = await context(t); const key = identity(); const town = event(key);
  const response = await call('/v1/events',town); assert.equal(response.status,201);
  const duplicates = await Promise.all(Array.from({length:5},()=>store.insert(town)));
  assert.ok(duplicates.every(row=>row.result==='already-present'));
  assert.equal((await store.meta()).event_count,1);
  const post = event(key,{kind:'message',title:'',community:town.id,body:'Question'});
  assert.equal((await call('/v1/events',post)).status,201);
  const reply = event(identity(),{kind:'message',title:'',community:town.id,parent:post.id,body:'Reply'});
  assert.equal((await call('/v1/events',reply)).status,201);
  const other = event(key,{title:'Other town'}); await store.insert(other);
  const wrong = event(key,{kind:'message',title:'',community:other.id,parent:post.id});
  assert.equal((await call('/v1/events',wrong)).status,400);
  const unknown = event(key,{kind:'message',title:'',community:'a'.repeat(64)});
  assert.equal((await call('/v1/events',unknown)).status,400);
  const page = await (await call('/v1/events?offset=1')).json();
  assert.deepEqual(page.events.map(value=>value.id),[post.id,reply.id,other.id]);
  assert.equal(page.cursor,4); assert.equal(page.next,null);
  const discovery = await (await call()).json(); assert.equal(discovery.epoch,page.epoch);
  assert.deepEqual(discovery.relays,['https://relay.example']);
  assert.equal((await call('/v1/events?offset=99')).status,409);
});

test('pages are byte bounded and preserve all events across pagination', async t => {
  const {store} = await context(t); const key=identity(); const town=event(key); await store.insert(town);
  for (let i=0;i<20;i++) await store.insert(event(key,{kind:'message',title:'',community:town.id,body:'a'.repeat(16384)}));
  const page = await store.page(0); assert.ok(Buffer.byteLength(JSON.stringify(page))<=MAX_PAGE); assert.ok(page.next>0);
  const rest = await store.page(page.next); assert.equal(page.events.length+rest.events.length,21);
  assert.equal(rest.next,null);
});

test('database rate and storage limits survive separate store instances', async t => {
  const {db,store,call} = await context(t); const key=identity();
  for(let i=0;i<30;i++) await store.insert(event(key));
  assert.equal((await call('/v1/events',event(key))).status,429);
  assert.equal((await store.meta()).event_count,30);
  await db.query('UPDATE fc_meta SET stored_bytes=33554432');
  assert.equal((await call('/v1/events',event(identity()))).status,507);
  const take = async now=>(await db.query("SELECT fc_take('test-window',2,60,$1::timestamptz) AS ok",[now])).rows[0].ok;
  assert.equal(await take('2026-09-05T00:00:00Z'),true);
  assert.equal(await take('2026-09-05T00:00:10Z'),true);
  assert.equal(await take('2026-09-05T00:00:20Z'),false);
  assert.equal(await take('2026-09-05T00:01:00Z'),true);
});

test('HTTP rejects browser writes, oversized streams, invalid offsets, and malformed or forged events', async t => {
  const {call,respond} = await context(t); const town=event(identity());
  assert.equal((await call('/v1/events',town,{Origin:'https://elsewhere.example'})).status,403);
  assert.equal((await call('/v1/events',{...town,body:'forged'})).status,400);
  assert.equal((await call('/v1/events?offset=-1')).status,400);
  assert.equal((await call('/v1/events',town,{'Content-Length':'90000'})).status,413);
  assert.equal((await call('/v1/events',event(identity(),{body:'x'.repeat(90000)}))).status,413);
  const malformed = new Request('https://relay.example/v1/events',{method:'POST',headers:{'Content-Type':'application/json'},body:'{'});
  assert.equal((await respond(malformed)).status,400);
  assert.equal((await call('/.env.local')).status,404);
  const unavailable = handler(()=>{throw new Error('secret://must-not-leak')});
  const response=await unavailable(new Request('https://relay.example/v1/health'));
  assert.equal(response.status,503); assert.doesNotMatch(await response.text(),/secret/);
});
