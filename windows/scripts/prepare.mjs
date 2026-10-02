import { readFile, writeFile, mkdir, readdir, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
const root = fileURLToPath(new URL('../', import.meta.url));
const icon = await readFile(path.join(root, '../Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-256.png'));
await mkdir(path.join(root, 'assets'), { recursive: true });
// An ICO container around the existing, unmodified 256 px PNG.
const header = Buffer.alloc(22); header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4);
header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12);
header.writeUInt32LE(icon.length, 14); header.writeUInt32LE(22, 18);
await writeFile(path.join(root, 'assets/app.ico'), Buffer.concat([header, icon]));
await mkdir(path.join(root, 'apps/desktop/renderer/public'), { recursive: true });
await writeFile(path.join(root, 'apps/desktop/renderer/public/icon.png'), icon);
const destination = path.join(root, 'out/licenses');
await mkdir(destination, { recursive: true });
await copyFile(path.join(root, 'licenses/Typr-LICENSE.txt'), path.join(destination, 'Typr-LICENSE.txt'));
const visited = new Set(), index = [];
async function license(name) {
  if (visited.has(name)) return;
  visited.add(name);
  const directory = path.join(root, 'node_modules', name);
  const metadata = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
  const candidates = (await readdir(directory)).filter(n => /^licen[sc]e(?:\.|$)/i.test(n));
  if (!candidates.length) throw new Error(`Missing license: ${name}`);
  const safeName = name.replaceAll('/', '-').replace('@', '');
  for (const entry of candidates) await copyFile(path.join(directory, entry), path.join(destination, `${safeName}-${entry}`));
  index.push({ name, version: metadata.version, license: metadata.license });
  for (const dependency of Object.keys(metadata.dependencies ?? {})) await license(dependency);
}
// Runtime libraries are compiled into the renderer; record their dependency notices.
await license('pentrado'); await license('vue');
await license('ag-psd'); await license('pngjs');
await writeFile(path.join(destination, 'DEPENDENCIES.json'), JSON.stringify(index.sort((a, b) => a.name.localeCompare(b.name)), null, 2) + '\n');
await build({ entryPoints: [path.join(root, 'packages/comp-bridge/codecs.mjs')], outfile: path.join(root, 'out/codecs/index.cjs'), platform: 'node', format: 'cjs', bundle: true, sourcemap: false, minify: true, target: 'node24' });
