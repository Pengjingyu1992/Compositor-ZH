import { mkdtemp, rm, readFile, stat, mkdir, readdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export async function inspectLinuxArtifacts(directory, artifacts) {
  const staging = await mkdtemp(path.join(directory, '.audit-'));
  const expected = digest(await readFile(path.join(directory, 'linux-unpacked/resources/app.asar')));
  async function inventory(directory, relative = '') {
    const files = [];
    let entries;
    try { entries = await readdir(path.join(directory, relative), { withFileTypes: true }); }
    catch (error) { if (error.code === 'ENOENT' && !relative) return files; throw error; }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const name = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isSymbolicLink()) throw new Error('Unexpected symlink in native application resources');
      if (entry.isDirectory()) files.push(...await inventory(directory, name));
      else files.push([name, digest(await readFile(path.join(directory, name)))]);
    }
    return files;
  }
  const nativeFiles = JSON.stringify(await inventory(path.join(directory, 'linux-unpacked/resources/app.asar.unpacked')));
  const licenseFiles = JSON.stringify(await inventory(path.join(directory, 'linux-unpacked/resources/licenses')));
  async function checkApplication(application) {
    if (digest(await readFile(path.join(application, 'resources/app.asar'))) !== expected) throw new Error('Installer application differs from the tested unpacked application');
    if (JSON.stringify(await inventory(path.join(application, 'resources/app.asar.unpacked'))) !== nativeFiles) throw new Error('Installer native libraries differ from the tested unpacked application');
    if (JSON.stringify(await inventory(path.join(application, 'resources/licenses'))) !== licenseFiles) throw new Error('Installer notices differ from the tested unpacked application');
    if (!((await stat(path.join(application, 'compositor-linux'))).mode & 0o111)) throw new Error('Linux executable lost its execute permission');
    for (const license of ['LICENSE.electron.txt', 'LICENSES.chromium.html', 'resources/licenses/THIRD_PARTY_NOTICES.md']) await readFile(path.join(application, license));
  }
  async function checkDesktop(file) {
    execFileSync('desktop-file-validate', [file], { stdio: 'inherit' });
    const desktop = await readFile(file, 'utf8');
    if (!desktop.includes('StartupWMClass=org.compositorzh.linux') || desktop.includes('--no-sandbox')) throw new Error('Incorrect desktop identity or sandbox override');
  }
  try {
    const appImage = artifacts.find(name => name.endsWith('.AppImage'));
    execFileSync(path.join(directory, appImage), ['--appimage-extract'], { cwd: staging, stdio: 'ignore' });
    const appDir = path.join(staging, 'squashfs-root');
    await checkApplication(appDir);
    await checkDesktop(path.join(appDir, 'org.compositorzh.linux.desktop'));
    if ((await readFile(path.join(appDir, 'AppRun'), 'utf8')) !== (await readFile(path.join(root, 'AppRun'), 'utf8'))) throw new Error('AppImage launcher does not match the sandbox-preserving source');
    const deb = artifacts.find(name => name.endsWith('.deb'));
    const debRoot = path.join(staging, 'deb');
    execFileSync('dpkg-deb', ['--extract', path.join(directory, deb), debRoot]);
    const identity = execFileSync('dpkg-deb', ['--field', path.join(directory, deb), 'Package', 'Architecture'], { encoding: 'utf8' });
    if (!identity.includes('compositor-linux') || !identity.includes('amd64')) throw new Error('Incorrect Debian package identity');
    const dependencies = execFileSync('dpkg-deb', ['--field', path.join(directory, deb), 'Depends'], { encoding: 'utf8' });
    // Electron links libgbm.so.1 directly; GTK's dependencies do not supply it.
    if (!dependencies.split(',').some(entry => /^libgbm1(?:\s*\([^)]*\))?$/.test(entry.trim()))) throw new Error('Debian package must require libgbm1 for the Electron runtime');
    await checkApplication(path.join(debRoot, 'opt/Compositor Linux'));
    await checkDesktop(path.join(debRoot, 'usr/share/applications/org.compositorzh.linux.desktop'));
    const tar = artifacts.find(name => name.endsWith('.tar.gz'));
    const entries = execFileSync('tar', ['-tzf', path.join(directory, tar)], { encoding: 'utf8' }).trim().split('\n');
    if (entries.some(entry => path.isAbsolute(entry) || entry.split('/').includes('..'))) throw new Error('Unsafe portable archive paths');
    const appEntry = entries.find(entry => entry.endsWith('/resources/app.asar'));
    if (!appEntry) throw new Error('Portable archive has no application');
    const tarRoot = path.join(staging, 'portable');
    await mkdir(tarRoot);
    execFileSync('tar', ['-xzf', path.join(directory, tar), '-C', tarRoot]);
    await checkApplication(path.join(tarRoot, path.dirname(path.dirname(appEntry))));
    return { appImage: 'passed', deb: 'passed', portableArchive: 'passed', applicationBytesMatch: true, desktopIntegration: 'passed', sandboxPreservingLauncher: true };
  } finally { await rm(staging, { recursive: true, force: true }); }
}
