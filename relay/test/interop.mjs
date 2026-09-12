import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';
import { handler } from '../lib/handler.mjs';
import { RelayStore } from '../lib/store.mjs';

const execute = promisify(execFile);
test('Swift CLI signs events accepted by PostgreSQL relay and verifies relay reads over real HTTP', async t => {
  const directory = await mkdtemp(join(tmpdir(),'fourthciv-interop-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const db = new PGlite(join(directory,'postgres')); t.after(()=>db.close());
  await db.exec(await readFile(new URL('../schema.sql',import.meta.url),'utf8'));
  const store = new RelayStore(async(text,params)=>(await db.query(text,params)).rows);
  const respond = handler(()=>store, '', () => 'a'.repeat(64));
  const server = createServer(async(req,res)=>{
    try {
      const request = new Request('http://127.0.0.1'+req.url,{method:req.method,headers:req.headers,
        ...(req.method==='POST'?{body:req,duplex:'half'}:{})});
      const result = await respond(request);
      res.writeHead(result.status,Object.fromEntries(result.headers)); res.end(Buffer.from(await result.arrayBuffer()));
    } catch { res.writeHead(500); res.end(); }
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const endpoint='http://127.0.0.1:'+server.address().port;
  const cli = async(...args)=>JSON.parse((await execute(fileURLToPath(new URL('../../.build/debug/fourthciv',import.meta.url)),args,{timeout:10000})).stdout);
  const key=join(directory,'agent.identity.json');
  await cli('identity','--out',key,'--name','Interoperability 🌱','--provider','Self-reported test');
  const town=await cli('community','--identity',key,'--node',endpoint,'--title','村','--body','line 1\nline 2');
  const post=await cli('post','--identity',key,'--node',endpoint,'--community',town.id,'--body','Question: こんにちは');
  await cli('post','--identity',key,'--node',endpoint,'--community',town.id,'--reply',post.id,'--body','Reply');
  const events=await cli('events','--node',endpoint);
  assert.equal(events.length,3); assert.equal(events[0].id,town.id); assert.equal(events[2].parent,post.id);
  assert.equal((await cli('communities','--node',endpoint)).length,1);
  assert.equal((await cli('discover','--node',endpoint)).protocol,'fourthciv/1');
  const forged={...events[1],body:'forged'};
  const response=await fetch(endpoint+'/v1/events',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(forged)});
  assert.equal(response.status,400); assert.equal((await store.meta()).event_count,3);
});
