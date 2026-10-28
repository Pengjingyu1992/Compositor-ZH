import { readFile, writeFile, mkdir, readdir, copyFile, cp } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import{verifyPortableColor}from'./verify-portable-color.mjs';
await verifyPortableColor();
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
  if (!candidates.length && name === 'omggif') {
    // The pinned package embeds its MIT notice in omggif.js rather than a LICENSE file.
    const source = await readFile(path.join(directory, 'omggif.js'), 'utf8');
    const notice = source.split('\n').slice(0, 21).map(line => line.replace(/^\/\/ ?/, '')).join('\n');
    if (!notice.includes('Dean McNamee') || !notice.includes('Permission is hereby granted') || !notice.includes('IN THE SOFTWARE.')) throw new Error('Missing omggif MIT notice');
    await writeFile(path.join(destination, 'omggif-LICENSE'), notice + '\n');
  } else if(!candidates.length&&name==='fontkit'){
    const readme=await readFile(path.join(directory,'README.md'),'utf8');if(metadata.version!=='2.0.4'||metadata.license!=='MIT'||!readme.includes('## License\n\nMIT'))throw new Error('Unexpected fontkit license declaration');
    await copyFile(path.join(root,'licenses/fontkit-MIT.txt'),path.join(destination,'fontkit-LICENSE'));
  } else if(!candidates.length&&name==='brotli'){
    const source=await readFile(path.join(directory,'dec/decode.js'),'utf8'),header=source.slice(0,source.indexOf('*/')+2);
    if(metadata.version!=='1.3.3'||metadata.license!=='MIT'||!header.includes('Copyright 2013 Google Inc.')||!header.includes('Apache License, Version 2.0'))throw new Error('Unexpected brotli notices');
    const mit=(await readFile(path.join(root,'licenses/fontkit-MIT.txt'),'utf8')).split('MIT License\n')[1];
    await writeFile(path.join(destination,'brotli-LICENSE'),'brotli 1.3.3, port author Devon Govett. Upstream package declares MIT.\nhttps://github.com/devongovett/brotli.js/tree/e36051345f6d27a56e5f39ea70d2f789b8574046\n\nMIT License\n'+mit+'\nDecoder source notice (retained verbatim):\n'+header+'\n');
    await copyFile(path.join(root,'licenses/brotli-Apache-2.0.txt'),path.join(destination,'brotli-Apache-2.0.txt'));
  } else if(!candidates.length&&name==='dfa'){
    if(metadata.version!=='1.2.0'||metadata.license!=='MIT'||!(await readFile(path.join(directory,'README.md'),'utf8')).includes('## License\n\nMIT'))throw new Error('Unexpected dfa license declaration');
    const mit=(await readFile(path.join(root,'licenses/fontkit-MIT.txt'),'utf8')).split('MIT License\n')[1];
    await writeFile(path.join(destination,'dfa-LICENSE'),'dfa 1.2.0, author Devon Govett. Package metadata and README declare MIT; no dedicated license file is shipped.\nhttps://github.com/devongovett/dfa/tree/3f5e603e5082caedabefefdf53e8a6ca3111e966\n\nMIT License\n'+mit);
  } else if (!candidates.length) throw new Error(`Missing license: ${name}`);
  const safeName = name.replaceAll('/', '-').replace('@', '');
  for (const entry of candidates) await copyFile(path.join(directory, entry), path.join(destination, `${safeName}-${entry}`));
  index.push({ name, version: metadata.version, license: name==='brotli'?'MIT AND Apache-2.0':metadata.license });
  for (const dependency of Object.keys(metadata.dependencies ?? {})) await license(dependency);
}
// Runtime libraries are compiled into the renderer; record their dependency notices.
await license('pentrado'); await license('vue');
await license('ag-psd'); await license('pngjs');
await license('gifenc'); await license('omggif');
await license('sharp'); await license('fontkit');
await cp(path.join(root, 'licenses/sharp-libvips'), path.join(destination, 'sharp-libvips'), { recursive: true });
await cp(path.join(root,'licenses/portable-color'),path.join(destination,'portable-color'),{recursive:true});
index.push({name:'portable-color/wasi-libc',version:'0.0~git20241209.574b88d-2',license:'SEE LICENSE IN portable-color/wasi-libc-copyright.txt',notices:'portable-color/wasi-libc-copyright.txt'});
index.push({name:'portable-color/compiler-rt',version:'19.1.7',license:'Apache-2.0 WITH LLVM-exception',notices:'portable-color/compiler-rt-copyright.txt'});
const nativePlatform = `${process.platform}-${process.arch}`;
const sharpMetadata = JSON.parse(await readFile(path.join(root, 'node_modules/sharp/package.json')));
for (const name of [`@img/sharp-${nativePlatform}`, `@img/sharp-libvips-${nativePlatform}`].filter(name => sharpMetadata.optionalDependencies[name])) {
  const directory = path.join(root, 'node_modules', name), metadata = JSON.parse(await readFile(path.join(directory, 'package.json')));
  index.push({ name, version: metadata.version, license: metadata.license });
  const safe = name.replaceAll('/', '-').replace('@', '');
  for (const file of ['LICENSE', 'README.md', 'versions.json']) {
    try { await copyFile(path.join(directory, file), path.join(destination, `${safe}-${file}`)); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
await writeFile(path.join(destination, 'DEPENDENCIES.json'), JSON.stringify(index.sort((a, b) => a.name.localeCompare(b.name)), null, 2) + '\n');
await build({ entryPoints: [path.join(root, 'packages/comp-bridge/codecs.mjs')], outfile: path.join(root, 'out/codecs/index.cjs'), platform: 'node', format: 'cjs', bundle: true, external: ['sharp'], sourcemap: false, minify: true, target: 'node24' });

await build({entryPoints:[path.join(root,'packages/platform/typography.mjs')],outfile:path.join(root,'out/typography/index.cjs'),platform:'node',format:'cjs',bundle:true,external:['sharp'],sourcemap:false,minify:true,target:'node24'});
