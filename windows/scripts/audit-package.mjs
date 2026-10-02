import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { listPackage, extractFile } from '@electron/asar';

const directory = path.resolve('release'), unpacked = path.join(directory, 'win-unpacked');
const asar = path.join(unpacked, 'resources/app.asar');
const entries = listPackage(asar).map(p => p.replaceAll('\\', '/'));
const forbidden = entries.filter(p => /(?:node_modules|\.map$|\/tests\/|\.comp\/|\.env|\.git\/|\/release\/)/.test(p));
if (forbidden.length) throw new Error(`Unexpected packaged files: ${forbidden.join(', ')}`);
const privatePath = /\/Users\/[A-Za-z0-9_-]+\/|[A-Z]:\\Users\\[^\\\s]+\\(?:Desktop|Documents|Pictures|AppData)|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}/;
for (const entry of entries.filter(p => /\.(?:js|mjs|cjs|json|html|css)$/.test(p))) {
  const filename = entry.replace(/^\//, '').replaceAll('/', path.sep);
  if (privatePath.test(extractFile(asar, filename).toString('utf8'))) throw new Error(`Sensitive pattern in ${entry}`);
}
for (const license of ['LICENSE.electron.txt', 'LICENSES.chromium.html']) await readFile(path.join(unpacked, license));
const notices = await readdir(path.join(unpacked, 'resources/licenses'));
for (const name of ['Compositor-LICENSE.txt', 'pentrado-LICENSE', 'Typr-LICENSE.txt', 'DEPENDENCIES.json', 'THIRD_PARTY_NOTICES.md']) {
  if (!notices.includes(name)) throw new Error(`Missing notice: ${name}`);
}
const artifacts = (await readdir(directory)).filter(p => /^Compositor-Windows-.*\.(?:exe|zip)$/.test(p));
if (artifacts.length !== 2) throw new Error('Expected NSIS installer and ZIP');
const checksums = [];
for (const name of artifacts) checksums.push(`${createHash('sha256').update(await readFile(path.join(directory, name))).digest('hex')}  ${name}`);
await writeFile(path.join(directory, 'SHA256SUMS.txt'), checksums.join('\n') + '\n');
await writeFile(path.join(directory, 'PACKAGE-REVIEW.json'), JSON.stringify({ platform: 'Windows x64', sourceCommit: process.env.GITHUB_SHA ?? 'manual build', readOnly: true, packagedEntries: entries.length, sourceMaps: false, privatePatternMatches: 0, bundledNotices: notices.sort(), artifacts, realWindows10And11Acceptance: 'pending', localTests: 'not run; cloud checks only' }, null, 2) + '\n');
console.log('Packaged source and license review passed. SHA256SUMS.txt written.');
