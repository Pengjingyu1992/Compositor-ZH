import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const files = execFileSync('git', ['ls-files', '-z'], { cwd: root }).toString().split('\0').filter(Boolean);
const findings = [];
export const sensitive = [
  /\/Users\/[A-Za-z0-9_-]+\//,
  /[A-Z]:\\Users\\[^\\\s]+\\(Desktop|Documents|Pictures|AppData)/i,
  /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})/,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /(?:api[_-]?key|access[_-]?token|password)\s*[:=]\s*["'][A-Za-z0-9_\-]{20,}["']/i
];
for (const file of files) {
  if (!/\.(?:mjs|cjs|ts|vue|md|yml|json|txt|py)$/.test(file) || !(file.startsWith('windows/') || file.startsWith('docs/windows-') || file.includes('/windows-'))) continue;
  const text = await readFile(path.join(root, file), 'utf8');
  if (sensitive.some(pattern => pattern.test(text))) findings.push(file);
}
const source = await readFile(path.join(root, 'windows/packages/locales/index.ts'), 'utf8');
// Catalogs are code-free constant objects. Import TypeScript using Node 24's type stripping.
const { messages } = await import('../packages/locales/index.ts');
function keys(v, prefix = '') { return Object.entries(v).flatMap(([key, value]) => typeof value === 'object' ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]); }
const {fullEditor}=await import('../apps/desktop/renderer/editor-labels.ts');
const en = [...keys(messages.en),...keys(fullEditor.en,'full.')].sort(), zh = [...keys(messages['zh-Hans']),...keys(fullEditor['zh-Hans'],'full.')].sort();
if (JSON.stringify(en) !== JSON.stringify(zh)) findings.push('localization-key-mismatch');
if (!source.includes('sourceNote')) findings.push('missing-credits');
if (findings.length) { console.error('Review failures:', findings); process.exitCode = 1; }
else console.log(`Source review: ${files.filter(f => f.startsWith('windows/')).length} Windows files; ${en.length} bilingual keys; no matching private paths or credential patterns.`);
