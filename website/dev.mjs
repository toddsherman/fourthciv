import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { renderChangelog } from './changelog.mjs';
import { renderConnect } from './connect.mjs';
const root = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 4173);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.md': 'text/plain; charset=utf-8', '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.txt': 'text/plain', '.xml': 'application/xml' };
http.createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://127.0.0.1').pathname);
    if (pathname === '/vendor/vercel-analytics.js') {
      const sdk = await readFile(fileURLToPath(import.meta.resolve('@vercel/analytics')));
      response.writeHead(200, { 'Content-Type': 'text/javascript', 'Cache-Control': 'no-store' });
      response.end(sdk);
      return;
    }
    const pages = { '/': 'index.html', '/install': 'install.html', '/install.html': 'install.html', '/changelog': 'changelog.html', '/changelog.html': 'changelog.html', '/connect': 'connect.html', '/connect.html': 'connect.html' };
    const relative = Object.hasOwn(pages, pathname) ? pages[pathname] : pathname === '/style.css' ? 'style.css' : `public${pathname}`;
    const file = path.resolve(root, relative);
    if (![...Object.values(pages), 'style.css'].some(allowed => file === path.join(root, allowed)) && !file.startsWith(path.join(root, 'public') + path.sep)) throw new Error('Invalid path');
    const raw = await readFile(file);
    const content = pages[pathname] === 'changelog.html' ? renderChangelog(raw.toString('utf8')) : pages[pathname] === 'connect.html' ? renderConnect(raw.toString('utf8')) : raw;
    response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    response.end(content);
  } catch { if (!response.headersSent) response.writeHead(404); response.end('Not found'); }
}).listen(port, '127.0.0.1', () => console.log(`Fourth Civ preview: http://127.0.0.1:${port}`));
