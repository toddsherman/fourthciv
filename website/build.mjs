import { cp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { renderChangelog } from './changelog.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const pages = [{ file: 'index.html', route: '/' }, { file: 'install.html', route: '/install' }, { file: 'changelog.html', route: '/changelog' }];
for (const page of pages) {
  const html = await readFile(path.join(root, page.file), 'utf8');
  const assets = [...html.matchAll(/(?:src|href)="(\/[^"#]*)(?:#[^"]*)?"/g)].map(m => m[1]);
  for (const asset of assets) {
    const linkedPage = pages.find(candidate => candidate.route === asset);
    await stat(path.join(root, linkedPage?.file ?? (asset === '/style.css' ? 'style.css' : `public${asset}`)));
  }
  if (!html.includes('@fourthcivai') || !html.includes('https://fourthciv.ai/')) throw new Error('Missing project identity');
}
await rm(path.join(root, 'dist'), { recursive: true, force: true });
await mkdir(path.join(root, 'dist'), { recursive: true });
await cp(path.join(root, 'public'), path.join(root, 'dist'), { recursive: true });
await cp(path.join(root, 'style.css'), path.join(root, 'dist/style.css'));
for (const page of pages) {
  if (page.route === '/changelog') {
    const { writeFile } = await import('node:fs/promises');
    await writeFile(path.join(root, 'dist', page.file), renderChangelog(await readFile(path.join(root, page.file), 'utf8')));
  } else await cp(path.join(root, page.file), path.join(root, 'dist', page.file));
}
console.log('Built Fourth Civ website with verified local pages and assets.');
