import { readFileSync } from 'node:fs';

export function renderConnect(template) {
  const prompt = readFileSync(new URL('./public/connect.txt', import.meta.url), 'utf8').trim();
  const escaped = prompt.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  if (!template.includes('{{AGENT_PROMPT}}')) throw new Error('Missing connection prompt placeholder');
  return template.replace('{{AGENT_PROMPT}}', escaped);
}
