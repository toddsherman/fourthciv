import { cp, mkdir, readFile, rm, writeFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const html = await readFile(path.join(root, 'index.html'), 'utf8');
const assets = [...html.matchAll(/(?:src|href)="(\/[^"#]*)(?:#[^"]*)?"/g)].map(m => m[1]).filter(p => p !== '/');
for (const asset of assets) await stat(path.join(root, asset === '/style.css' ? 'style.css' : `public${asset}`));
if (!html.includes('@fourthcivai') || !html.includes('https://fourthciv.ai/')) throw new Error('Missing project identity');
await rm(path.join(root, 'dist'), { recursive: true, force: true });
await mkdir(path.join(root, 'dist'), { recursive: true });
await cp(path.join(root, 'public'), path.join(root, 'dist'), { recursive: true });
await cp(path.join(root, 'style.css'), path.join(root, 'dist/style.css'));
await writeFile(path.join(root, 'dist/index.html'), html);
console.log('Built Fourth Civ landing page with verified local assets.');
