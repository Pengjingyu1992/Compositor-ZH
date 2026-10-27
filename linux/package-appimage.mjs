import { cp, mkdtemp, rm, readFile, chmod, open, rename, symlink, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

// Reuse the pinned builder's checksum-verified tools and static AppImage runtime.
// A small owned AppRun keeps sandbox decisions out of generated launchers.
const require = createRequire(new URL('../windows/package.json', import.meta.url));
const { getAppImageTools } = require('app-builder-lib/out/toolsets/linux.js');
const { Arch } = require('builder-util');
const { version } = require('../windows/package.json');
const root = fileURLToPath(new URL('.', import.meta.url));
const outputFlag = process.argv.indexOf('--output');
const release = outputFlag >= 0 ? path.resolve(process.argv[outputFlag + 1]) : path.join(root, 'release');
if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('AppImage packaging currently supports Linux x64');
const tools = await getAppImageTools('1.0.3', Arch.x64);
const staging = await mkdtemp(path.join(release, '.appimage-'));
const output = path.join(release, `Compositor-Linux-${version}-x86_64.AppImage`);
const temporary = path.join(staging, 'output.AppImage');
try {
  const appDir = path.join(staging, 'AppDir');
  await cp(path.join(release, 'linux-unpacked'), appDir, { recursive: true });
  await cp(path.join(root, 'AppRun'), path.join(appDir, 'AppRun'));
  await chmod(path.join(appDir, 'AppRun'), 0o755);
  await cp(path.join(root, 'compositor.desktop'), path.join(appDir, 'org.compositorzh.linux.desktop'));
  await cp(path.join(root, '../Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-512.png'), path.join(appDir, 'compositor-linux.png'));
  await symlink('compositor-linux.png', path.join(appDir, '.DirIcon'));
  await mkdir(path.join(appDir, 'usr/lib'), { recursive: true });
  await cp(tools.runtimeLibraries, path.join(appDir, 'usr/lib'), { recursive: true });
  execFileSync(tools.desktopFileValidate, [path.join(appDir, 'org.compositorzh.linux.desktop')], { stdio: 'inherit' });
  const runtime = await readFile(tools.runtime);
  execFileSync(tools.mksquashfs, [appDir, temporary, '-offset', String(runtime.length), '-all-root', '-noappend', '-no-progress', '-quiet', '-no-xattrs', '-no-fragments', '-processors', String(Math.min(4, os.availableParallelism())), '-comp', 'gzip'], { stdio: 'inherit' });
  const file = await open(temporary, 'r+');
  try { await file.write(runtime, 0, runtime.length, 0); await file.sync(); } finally { await file.close(); }
  await chmod(temporary, 0o755);
  await rename(temporary, output);
  console.log(`AppImage written: ${path.basename(output)}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
