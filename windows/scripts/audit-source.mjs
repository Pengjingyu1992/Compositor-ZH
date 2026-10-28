import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {sensitive}from'./private-patterns.mjs';
export {sensitive}from'./private-patterns.mjs';
const root = fileURLToPath(new URL('../../', import.meta.url));
const files = [...new Set(execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], { cwd: root }).toString().split('\0').filter(Boolean))];
const findings = [];
for (const file of files) {
  if (!/\.(?:mjs|cjs|ts|vue|md|yml|json|txt|py)$/.test(file) || !(file.startsWith('windows/') || file.startsWith('linux/') || /^docs\/(windows|linux)-/.test(file) || /\/(windows|linux)-/.test(file) || /^\.github\/workflows\/linux-/.test(file))) continue;
  const text = await readFile(path.join(root, file), 'utf8');
  if (sensitive.some(pattern => pattern.test(text))) findings.push(file);
}
const source = await readFile(path.join(root, 'windows/packages/locales/index.ts'), 'utf8');
// Catalogs are code-free constant objects. Import TypeScript using Node 24's type stripping.
const { messages } = await import('../packages/locales/index.ts');
function keys(v, prefix = '') { return Object.entries(v).flatMap(([key, value]) => typeof value === 'object' ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]); }
const {fullEditor}=await import('../apps/desktop/renderer/editor-labels.ts');
const {parityMessages}=await import('../apps/desktop/renderer/parity-labels.ts');
const en = [...keys(messages.en),...keys(fullEditor.en,'full.'),...keys(parityMessages.en,'parity.')].sort(), zh = [...keys(messages['zh-Hans']),...keys(fullEditor['zh-Hans'],'full.'),...keys(parityMessages['zh-Hans'],'parity.')].sort();
if (JSON.stringify(en) !== JSON.stringify(zh)) findings.push('localization-key-mismatch');
if (!source.includes('sourceNote')) findings.push('missing-credits');
if (findings.length) { console.error('Review failures:', findings); process.exitCode = 1; }
else console.log(`Source review: ${files.filter(f => /^(windows|linux)\//.test(f)).length} desktop files; ${en.length} bilingual keys; no matching private paths or credential patterns.`);
