import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export function renderChangelog(template) {
  const script = fileURLToPath(new URL('../scripts/release_notes.py', import.meta.url));
  const notes = execFileSync('python3', [script, '--page-content'], { encoding: 'utf8' });
  if (!template.includes('<!-- RELEASES -->')) throw new Error('Missing changelog insertion point');
  return template.replace('<!-- RELEASES -->', () => notes);
}
