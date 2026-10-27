import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { listPackage, extractFile } from '@electron/asar';

process.on('uncaughtException', error => {
  const message = String(error.message).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  if (process.env.GITHUB_ACTIONS) console.error(`::error title=Package review::${message}`);
  console.error(error); process.exitCode = 1;
});

const linux = process.argv.includes('--linux');
const directoryFlag = process.argv.indexOf('--directory');
const directory = path.resolve(directoryFlag >= 0 ? process.argv[directoryFlag + 1] : linux ? '../linux/release' : 'release'), unpacked = path.join(directory, linux ? 'linux-unpacked' : 'win-unpacked');
const asar = path.join(unpacked, 'resources/app.asar');
const entries = listPackage(asar).map(p => p.replaceAll('\\', '/'));
const runtimeModule = /^\/node_modules\/(?:sharp|semver|detect-libc|@img\/(?:colour|sharp-(?:libvips-)?(?:linux|win32)-x64))(?:\/|$)/;
const forbidden = entries.filter(p => /(?:\.(?:ttf|otf|ttc|woff2?)$|\.map$|\/tests\/|\.comp\/|\.env|\.git\/|\/release\/)/.test(p) || p.includes('/node_modules/') && p !== '/node_modules/@img' && !runtimeModule.test(p));
if (forbidden.length) throw new Error(`Unexpected packaged files: ${forbidden.join(', ')}`);
const privatePath = /(?:\/(?:Users|home)\/[^/\\\s]+(?:\/|$)|\/root(?:\/|$)|[A-Z]:\\Users\\[^\\\s]+(?:\\|$)|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----|(?:api[_-]?key|access[_-]?token|password)\s*[:=]\s*["'][A-Za-z0-9_\-]{20,}["'])/i;
for (const entry of entries.filter(p => /\.(?:js|mjs|cjs|json|html|css)$/.test(p))) {
  const filename = entry.replace(/^\//, '').replaceAll('/', path.sep);
  if (privatePath.test(extractFile(asar, filename).toString('utf8'))) throw new Error(`Potential private path or credential pattern in ${entry}`);
}
for (const license of ['LICENSE.electron.txt', 'LICENSES.chromium.html']) await readFile(path.join(unpacked, license));
const notices = await readdir(path.join(unpacked, 'resources/licenses'));
for (const name of ['fontkit-LICENSE','dfa-LICENSE','brotli-LICENSE','brotli-Apache-2.0.txt','sharp-LICENSE', 'detect-libc-LICENSE', 'semver-LICENSE', 'img-colour-LICENSE.md', 'sharp-libvips/LGPL-3.0.txt', 'sharp-libvips/GPL-3.0.txt', 'sharp-libvips/SOURCES.md']) {
  await readFile(path.join(unpacked, 'resources/licenses', name));
}
const nativePlatform = linux ? 'linux-x64' : 'win32-x64';
const bindings = entries.filter(name => name.startsWith(`/node_modules/@img/sharp-${nativePlatform}/`) && name.endsWith('.node'));
if (bindings.length !== 1) throw new Error('Missing platform image decoder binding');
await readFile(path.join(unpacked, 'resources/app.asar.unpacked', bindings[0].slice(1)));
for (const name of ['Compositor-LICENSE.txt', 'pentrado-LICENSE', 'ag-psd-LICENSE', 'pngjs-LICENSE', 'gifenc-LICENSE.md', 'omggif-LICENSE', 'Typr-LICENSE.txt', 'DEPENDENCIES.json', 'THIRD_PARTY_NOTICES.md']) {
  if (!notices.includes(name)) throw new Error(`Missing notice: ${name}`);
}
const artifacts = (await readdir(directory)).filter(p => (linux ? /^Compositor-Linux-.*\.(?:AppImage|deb|tar\.gz)$/ : /^Compositor-Windows-.*\.(?:exe|zip)$/).test(p)).sort();
if (artifacts.length !== (linux ? 3 : 2)) throw new Error(linux ? 'Expected AppImage, Deb and tar.gz' : 'Expected NSIS installer and ZIP');
if (linux) {
  const metadata = JSON.parse(extractFile(asar, 'package.json').toString('utf8'));
  if (metadata.name !== 'compositor-linux' || metadata.desktopName !== 'org.compositorzh.linux.desktop') throw new Error('Incorrect Linux application identity');
  for (const extension of ['.AppImage', '.deb', '.tar.gz']) if (!artifacts.some(name => name.endsWith(extension))) throw new Error(`Missing Linux artifact: ${extension}`);
}
const checksums = [];
for (const name of artifacts) checksums.push(`${createHash('sha256').update(await readFile(path.join(directory, name))).digest('hex')}  ${name}`);
await writeFile(path.join(directory, 'SHA256SUMS.txt'), checksums.join('\n') + '\n');
let guiChecks = null;
let guiRechecks = null;
let artifactChecks = null;
if (linux) {
  const { inspectLinuxArtifacts } = await import('../../linux/audit-artifacts.mjs');
  artifactChecks = await inspectLinuxArtifacts(directory, artifacts);
  try {
    const full = JSON.parse(await readFile('playwright-report/smoke-results.json', 'utf8')), { stats } = full;
    guiChecks = { passed: stats.expected, failed: stats.unexpected, skipped: stats.skipped };
    if (stats.unexpected) {
      try {
        const recheck = JSON.parse(await readFile('playwright-report/smoke-recheck-results.json', 'utf8'));
        const specs = suites => suites.flatMap(suite => [...(suite.specs ?? []), ...specs(suite.suites ?? [])]);
        const failed = specs(full.suites).filter(spec => spec.tests.some(test => test.status === 'unexpected'));
        const passed = new Set(specs(recheck.suites).filter(spec => spec.tests.every(test => test.expectedStatus === 'passed' && test.results.at(-1)?.status === 'passed')).map(spec => spec.id));
        const applicationSHA256 = createHash('sha256').update(await readFile(asar)).digest('hex');
        const testedSHA256 = (await readFile('../linux/test-results/full-gui-build.sha256', 'utf8')).split(/\s+/)[0];
        const allFailedChecksRechecked = failed.length === stats.unexpected && failed.every(spec => passed.has(spec.id));
        if (Date.parse(recheck.stats.startTime) < Date.parse(stats.startTime) + stats.duration || recheck.stats.unexpected || recheck.stats.skipped || !allFailedChecksRechecked || applicationSHA256 !== testedSHA256) throw new Error('Corrective GUI report does not validate this build');
        guiRechecks = { passed: recheck.stats.expected, failed: 0, skipped: 0, allFailedChecksRechecked, applicationSHA256, fullRunReport: 'windows/playwright-report/smoke-results.json', correctiveRunReport: 'windows/playwright-report/smoke-recheck-results.json' };
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
await writeFile(path.join(directory, 'PACKAGE-REVIEW.json'), JSON.stringify({ platform: linux ? 'Linux x64' : 'Windows x64', sourceCommit: process.env.GITHUB_SHA ?? 'manual build', readOnly: false, editing: 'revision-bound operations; staged save with backup and journal', packagedEntries: entries.length, sourceMaps: false, privatePatternMatches: 0, bundledNotices: notices.sort(), artifacts, ...(linux ? { realLinuxDesktopAcceptance: 'pending', artifactChecks, guiChecks, ...(guiRechecks ? { guiRechecks } : {}) } : { realWindows10And11Acceptance: 'pending', localTests: 'not run; cloud checks only' }) }, null, 2) + '\n');
console.log('Packaged source and license review passed. SHA256SUMS.txt written.');
