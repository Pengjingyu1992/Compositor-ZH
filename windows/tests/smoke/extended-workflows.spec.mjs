import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { PNG } from 'pngjs';
import { fixture, png } from '../fixtures.mjs';
import { exportGIF, importGIF, importRasterEPS } from '../../packages/comp-bridge/codecs.mjs';
import * as codecs from '../../packages/comp-bridge/codecs.mjs';
import { editProject } from '../../packages/comp-bridge/edit.mjs';
import { saveProject, RecoveryStore } from '../../packages/platform/save-project.mjs';
import { ADJUSTMENT_KINDS, EFFECT_KINDS } from '../../packages/comp-bridge/capabilities.mjs';
import { FILTERS } from '../../packages/comp-bridge/raster-tools.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

let temp, instance, page, source, saved = 0, runtimeErrors;
test.beforeEach(async () => {
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-all-features-'));
  source = path.join(temp, 'source.comp');
  await fixture(source);
  instance = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(temp), timeout: 30000 });
  page = await instance.firstWindow();
  runtimeErrors=[];page.on('pageerror',error=>runtimeErrors.push(error.message));
  await expect(page.locator('.welcome')).toBeVisible();
  await page.getByTestId('language').selectOption('en');
  await instance.evaluate(({ dialog }) => { dialog.showMessageBox = async () => ({ response: 1 }); });
});
test.afterEach(async () => { await instance?.close(); await rm(temp, { recursive: true, force: true }); expect(runtimeErrors).toEqual([]); });
async function menu(id) { await instance.evaluate(({ Menu }, id) => { const item = Menu.getApplicationMenu().getMenuItemById(id); if (!item?.enabled) throw new Error(`Disabled menu: ${id}`); item.click(); }, id); }
async function command(name) { await instance.evaluate(({ BrowserWindow }, name) => BrowserWindow.getAllWindows()[0].webContents.send(`editor:${name}`), name); }
async function chooseOpen(file) { await instance.evaluate(({ dialog }, file) => { dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [file] }); }, file); }
async function ready() { await expect(page.getByTestId('layer-opacity')).toBeEnabled(); await expect(page.locator('[role=alert]')).toHaveCount(0); }
async function openFixture() { await chooseOpen(source); await page.getByTestId('open-project').click(); await expect(page.getByTestId('rendered-canvas')).toBeVisible(); await page.locator('.layer-select').filter({ hasText: 'Mint / 薄荷' }).click(); await ready(); }
async function save() {
  const file = path.join(temp, `saved-${++saved}.comp`);
  await instance.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, file);
  await menu('file-save-as');
  await expect.poll(async () => { try { return JSON.parse(await readFile(path.join(file, 'manifest.json'), 'utf8')); } catch { return null; } }).not.toBeNull();
  await expect(page.locator('.badge')).toContainText('Saved');
  await ready();
  return { file, manifest: JSON.parse(await readFile(path.join(file, 'manifest.json'), 'utf8')) };
}
async function animation(durations = [1000, 3000]) {
  const file = path.join(temp, 'synthetic.gif');
  await writeFile(file, exportGIF({ frames: [[255,0,0,255], [0,255,0,255]].map((color, i) => ({ png: png(32,24,color), durationMS: durations[i] })), loopCount: 0 }));
  await chooseOpen(file); await menu('file-image'); await expect(page.locator('.animation-frames button')).toHaveCount(2); await ready();
  return file;
}
test('pausing animation selects the displayed frame before subsequent editing', async () => {
  await animation();
  await page.getByRole('button', { name: 'Play', exact: true }).click();
  await expect(page.locator('.animation-frames button').nth(1)).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: 'Pause', exact: true }).click();
  await ready();
  await expect(page.locator('.layer-select[aria-pressed=true]')).toContainText('Frame 2');
  await page.getByTestId('layer-name').fill('Edited displayed frame'); await page.getByTestId('layer-name').press('Tab'); await ready();
  const { manifest } = await save();
  const changed = manifest.layers.find(layer => layer.name === 'Edited displayed frame');
  expect(changed.parentID).toBe(manifest.animation.frames[1].groupID);
});
test('Space activates a dialog button without starting background animation playback',async()=>{
  await animation();await page.evaluate(()=>window.dispatchEvent(new KeyboardEvent('keydown',{key:' ',isComposing:true,bubbles:true})));await expect(page.getByRole('button',{name:'Play',exact:true})).toBeVisible();await menu('file-export-psd');
  const dialog=page.getByRole('dialog');await expect(dialog).toBeVisible();
  await dialog.getByRole('button',{name:'Cancel',exact:true}).focus();await page.keyboard.press('Space');
  await expect(dialog).toBeHidden();await expect(page.getByRole('button',{name:'Play',exact:true})).toBeVisible();
  await expect(page.locator('.animation-frames button').first()).toHaveAttribute('aria-pressed','true');
});
test('seeking a frame with nested groups selects its drawable descendant',async()=>{
  let data=importGIF(exportGIF({frames:[{png:png(32,24,[255,0,0,255]),durationMS:100},{png:png(32,24,[0,255,0,255]),durationMS:100}],loopCount:0}));
  const frame=data.manifest.animation.frames[1].groupID, child=data.manifest.layers.find(l=>l.parentID===frame).id;
  data=editProject(data,{kind:'add',type:'group',name:'Nested'},codecs);const group=data.manifest.layers.at(-1).id;
  data=editProject(data,{kind:'parent',id:group,parentID:frame},codecs);data=editProject(data,{kind:'parent',id:child,parentID:group},codecs);
  const file=path.join(temp,'nested.comp');await saveProject(data,file);await chooseOpen(file);await page.getByTestId('open-project').click();
  await expect(page.locator('.animation-frames button')).toHaveCount(2);await page.locator('.animation-frames button').nth(1).click();await ready();
  await expect(page.locator('.layer-select[aria-pressed=true]')).toContainText('Frame 2');
});
test('animation frame operations, timings and looping persist and export all frames', async () => {
  test.setTimeout(120000);
  await animation([50, 120]);
  await page.getByRole('button', { name: 'Duplicate frame', exact: true }).click(); await ready();
  await expect(page.locator('.animation-frames button')).toHaveCount(3);
  await page.getByLabel('Duration (ms)', { exact: true }).fill('340'); await page.getByLabel('Duration (ms)', { exact: true }).press('Tab'); await ready();
  await page.getByLabel('Repeats (−1 once, 0 forever)', { exact: true }).fill('2'); await page.getByLabel('Repeats (−1 once, 0 forever)', { exact: true }).press('Tab'); await ready();
  await page.getByRole('button', { name: 'Later', exact: true }).click(); await ready();
  const saved = await save(); expect(saved.manifest.version).toBe(16); expect(saved.manifest.animation.frames.map(f => f.durationMS)).toEqual([50,120,340]);
  await chooseOpen(saved.file); await page.getByTestId('open-project').click(); await expect(page.locator('.animation-frames button')).toHaveCount(3);
  await page.locator('.animation-frames button').first().click(); await ready();
  const file = path.join(temp, 'exported.gif');
  await instance.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, file);
  await menu('file-export-gif');
  await expect.poll(async () => { try { return (await readFile(file)).length; } catch { return 0; } }).toBeGreaterThan(20);
  const exported = importGIF(await readFile(file));
  expect(exported.manifest.animation.frames.map(f => f.durationMS)).toEqual([50,120,340]); expect(exported.manifest.animation.loopCount).toBe(2);
  await ready(); await page.getByRole('button', { name: 'New frame', exact: true }).click(); await ready();
  await expect(page.locator('.animation-frames button')).toHaveCount(4);
  await page.getByRole('button', { name: 'Delete frame', exact: true }).click();
  await expect(page.locator('.animation-frames button')).toHaveCount(3);
});
test('creating animation from a static project preserves every original layer and resource',async()=>{
  await openFixture();const original=JSON.parse(await readFile(path.join(source,'manifest.json'),'utf8'));
  await page.getByRole('button',{name:'Create animation',exact:true}).click();await expect(page.locator('.animation-frames button')).toHaveCount(1);await ready();
  const saved=await save(),group=saved.manifest.animation.frames[0].groupID;
  expect(saved.manifest.version).toBe(16);expect(saved.manifest.layers).toHaveLength(3);
  for(const layer of original.layers){const copy=saved.manifest.layers.find(l=>l.id===layer.id);expect(copy).toEqual({...layer,parentID:group});for(const field of ['imageFile','maskFile'])if(layer[field])expect(await readFile(path.join(saved.file,'images',layer[field]))).toEqual(await readFile(path.join(source,'images',layer[field])));}
  await page.getByTestId('undo').click();await expect(page.getByRole('button',{name:'Create animation',exact:true})).toBeVisible();await expect(page.locator('.layer-row')).toHaveCount(2);
});
test('static PNG and raster EPS export the selected animation frame', async () => {
  await animation(); await page.locator('.animation-frames button').nth(1).click(); await ready();
  const pngFile = path.join(temp, 'frame.png');
  await instance.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, pngFile);
  await menu('file-export-png');
  await expect.poll(async () => { try { return (await readFile(pngFile)).length; } catch { return 0; } }).toBeGreaterThan(50);
  const bitmap = await instance.evaluate(({ nativeImage }, bytes) => {const image=nativeImage.createFromBuffer(Buffer.from(bytes));return {size:image.getSize(),pixel:Array.from(image.toBitmap().subarray(0,4))};}, Array.from(await readFile(pngFile)));
  expect(bitmap).toEqual({size:{width:32,height:24},pixel:[0,255,0,255]});
  await ready();
  const file = path.join(temp, 'frame.eps');
  await instance.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, file);
  await menu('file-export-eps');
  await expect.poll(async () => { try { return (await readFile(file)).length; } catch { return 0; } }).toBeGreaterThan(100);
  const image = importRasterEPS(await readFile(file)); expect([image.width, image.height]).toEqual([32,24]);
  const decoded = await instance.evaluate(({ nativeImage }, bytes) => Array.from(nativeImage.createFromBuffer(Buffer.from(bytes)).toBitmap().subarray(0,4)), Array.from(image.bytes));
  expect(decoded).toEqual([0,255,0,255]);
  await ready();
});
test('PNG JPEG and layered PSD imports produce editable layers', async () => {
  test.setTimeout(120000);
  const pngFile = path.join(temp, 'image.png'); await writeFile(pngFile, png(20,12,[120,220,180,255]));
  await chooseOpen(pngFile); await menu('file-image'); await expect(page.locator('.layer-row')).toHaveCount(1); await ready();
  const jpegFile=path.join(temp,'image.jpg');
  const jpeg=await instance.evaluate(({nativeImage}, bytes)=>nativeImage.createFromBuffer(Buffer.from(bytes)).toJPEG(95).toString('base64'),Array.from(await readFile(pngFile)));
  await writeFile(jpegFile,Buffer.from(jpeg,'base64'));await chooseOpen(jpegFile);await menu('file-image');await expect(page.locator('.layer-row')).toHaveCount(2);await ready();
  const psd=path.join(temp,'layers.psd');await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},psd);
  await menu('file-export-psd');await page.getByRole('button',{name:'Export layers',exact:true}).click();
  await expect.poll(async()=>{try{return (await readFile(psd)).length;}catch{return 0;}}).toBeGreaterThan(26);
  await ready();await chooseOpen(psd);await menu('file-import-psd');await expect(page.locator('.layer-row')).toHaveCount(2);await expect(page.getByTestId('rendered-canvas')).toBeVisible();
  await page.locator('.layer-select').first().click();await ready();const saved=await save();expect(saved.manifest.layers.filter(l=>l.imageFile)).toHaveLength(2);
});
test('all 12 adjustment layers and all six effects render and save', async () => {
  test.setTimeout(180000); await openFixture();
  for (const kind of ADJUSTMENT_KINDS) {
    await page.getByLabel('Add adjustment', { exact: true }).selectOption(kind); await ready();
    await expect(page.locator('.layer-row')).toHaveCount(3);
    await page.getByTestId('delete-layer').click(); await page.locator('.layer-select').filter({hasText:'Mint / 薄荷'}).click(); await ready();
  }
  await page.getByRole('tab',{name:'Effects',exact:true}).click();
  for(const kind of EFFECT_KINDS){await page.getByLabel('Add effect',{exact:true}).selectOption(kind);await ready();}
  const saved=await save(); expect(Object.keys(saved.manifest.layers[1].effects).sort()).toEqual([...EFFECT_KINDS].sort());
});
test('eyedropper, zoom, grid and guides work and guide history survives saving',async()=>{
  await openFixture();await page.getByRole('button',{name:'Eyedropper',exact:true}).click();await page.getByLabel('Sample all layers',{exact:true}).uncheck();
  let box=await page.locator('.artboard').boundingBox();await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
  await expect(page.getByLabel('Color',{exact:true})).toHaveValue('#78dcb4');await ready();await expect(page.locator('.badge')).toContainText('Saved');
  await page.locator('.zoom-value').click();await expect(page.locator('.zoom-value')).toHaveText('100%');
  await page.getByRole('button',{name:'Zoom',exact:true}).click();box=await page.locator('.artboard').boundingBox();await page.mouse.click(box.x+box.width/2,box.y+box.height/2);await expect(page.locator('.zoom-value')).toHaveText('125%');
  await page.getByRole('button',{name:'Fit to window',exact:true}).click();
  await page.getByText('Guide',{exact:true}).click();await page.getByLabel('Grid',{exact:true}).check();await page.getByLabel('Snap',{exact:true}).check();
  await page.getByLabel('Position',{exact:true}).fill('24');await page.getByRole('button',{name:'Add guide',exact:true}).click();await ready();
  await page.getByRole('combobox',{name:/^Direction/}).selectOption('horizontal');await page.getByLabel('Position',{exact:true}).fill('18');await page.getByRole('button',{name:'Add guide',exact:true}).click();await ready();
  await page.getByRole('button',{name:'Clear guides',exact:true}).click();await ready();await page.getByTestId('undo').click();await ready();
  const saved=await save();expect(saved.manifest.guides.map(({axis,position})=>({axis,position}))).toEqual([{axis:'vertical',position:24},{axis:'horizontal',position:18}]);expect(saved.manifest).not.toHaveProperty('grid');
});
test('numeric transforms and independent mask placement survive save and undo',async()=>{
  await openFixture();await page.getByRole('button',{name:'Move',exact:true}).click();
  const options=page.getByTestId('tool-options');
  await options.getByLabel('X',{exact:true}).fill('9');await options.getByLabel('X',{exact:true}).press('Tab');await ready();
  await options.getByRole('spinbutton',{name:/^Rotation/}).fill('30');await options.getByRole('spinbutton',{name:/^Rotation/}).press('Tab');await ready();
  await options.getByRole('button',{name:'Flip horizontal',exact:true}).click();await ready();
  await page.getByLabel('Link mask',{exact:true}).uncheck();await ready();
  const mask=page.locator('.mask-flags').locator('..');await mask.getByLabel('Y',{exact:true}).fill('7');await mask.getByLabel('Y',{exact:true}).press('Tab');await ready();
  await page.getByTestId('undo').click();await ready();await page.getByTestId('redo').click();await ready();
  const {manifest}=await save(),layer=manifest.layers.find(l=>l.name==='Mint / 薄荷');
  expect(layer.transform.origin).toEqual([9,0]);expect(layer.transform.rotation).toBe(30);expect(layer.transform.flipX).toBe(true);expect(layer.maskLinked).toBe(false);expect(layer.maskPlacement.origin).toEqual([9,7]);
});
test('merging and flattening preserve the composite and undo restores editable source layers',async()=>{
  await openFixture();const sample=()=>page.getByTestId('rendered-canvas').evaluate(c=>Array.from(c.getContext('2d').getImageData(32,24,1,1).data));
  const before=await sample(),rows=page.locator('.layer-select');await rows.filter({hasText:'Coral / 珊瑚'}).click({modifiers:['Control']});
  await command('merge');await expect(page.locator('.layer-row')).toHaveCount(1);await ready();
  (await sample()).forEach((v,i)=>expect(Math.abs(v-before[i])).toBeLessThanOrEqual(3));
  await page.getByTestId('undo').click();await expect(page.locator('.layer-row')).toHaveCount(2);await rows.filter({hasText:'Mint / 薄荷'}).click();await ready();
  await command('flatten');await expect(page.locator('.layer-row')).toHaveCount(1);await ready();
  (await sample()).forEach((v,i)=>expect(Math.abs(v-before[i])).toBeLessThanOrEqual(3));
  const saved=await save();expect(saved.manifest.layers).toHaveLength(1);expect(saved.manifest.layers[0]).not.toHaveProperty('maskFile');
  await page.getByTestId('undo').click();await expect(page.locator('.layer-row')).toHaveCount(2);await rows.filter({hasText:'Mint / 薄荷'}).click();await ready();
});
test('merged clipboard copy, cut and native image paste retain the expected pixels',async()=>{
  await openFixture();const expected=await page.getByTestId('rendered-canvas').evaluate(c=>Array.from(c.getContext('2d').getImageData(32,24,1,1).data));
  const clipboardReady=async()=>{await expect.poll(()=>instance.evaluate(async({clipboard})=>(await clipboard.read()).some(item=>item.types.includes('image/png')))).toBe(true);await ready();};
  await instance.evaluate(({clipboard})=>clipboard.clear());await command('copyMerged');await clipboardReady();await command('paste');await expect(page.locator('.layer-row')).toHaveCount(3);await ready();
  const pasted=await save(),layer=pasted.manifest.layers.at(-1),image=PNG.sync.read(await readFile(path.join(pasted.file,'images',layer.imageFile)));
  Array.from(image.data.subarray((24*64+32)*4,(24*64+32)*4+4)).forEach((v,i)=>expect(Math.abs(v-expected[i])).toBeLessThanOrEqual(3));
  await instance.evaluate(({clipboard})=>clipboard.clear());await command('cut');await clipboardReady();
  const cut=await save(),cleared=PNG.sync.read(await readFile(path.join(cut.file,'images',layer.imageFile)));expect(Array.from(cleared.data).filter((_,i)=>i%4===3).every(a=>a===0)).toBe(true);
  await command('paste');await expect(page.locator('.layer-row')).toHaveCount(4);await ready();
  const restored=await save(),copy=restored.manifest.layers.at(-1);expect(PNG.sync.read(await readFile(path.join(restored.file,'images',copy.imageFile))).data).toEqual(image.data);
});
test('all supported filter previews and applications retain a valid document', async () => {
  test.setTimeout(300000); await openFixture();
  for(const kind of FILTERS)await test.step(kind,async()=>{
    await command('selectAll');await expect.poll(()=>page.locator('.paint-overlay').evaluate(c=>c.getContext('2d').getImageData(0,0,1,1).data[3])).toBeGreaterThan(0);await ready();
    if(kind==='Content-Aware Fill'){
      await command('deselect');await expect.poll(()=>page.locator('.paint-overlay').evaluate(c=>c.getContext('2d').getImageData(0,0,1,1).data[3])).toBe(0);await ready();await page.getByRole('button',{name:'Marquee',exact:true}).click();const box=await page.locator('.artboard').boundingBox();
      await page.mouse.move(box.x+box.width*.4,box.y+box.height*.4);await page.mouse.down();await page.mouse.move(box.x+box.width*.6,box.y+box.height*.6,{steps:4});await page.mouse.up();await ready();
    }
    await command('filter');await page.getByTestId('filter-kind').selectOption(kind);if(kind==='Color Lookup')await page.getByTestId('lut-file').setInputFiles({name:'identity.cube',mimeType:'text/plain',buffer:Buffer.from('LUT_1D_SIZE 2\n0 0 0\n1 1 1')});await page.getByTestId('update-preview').click();await expect(page.getByTestId('apply-editor')).toBeEnabled();
    await expect(page.locator('.editor-preview img')).toBeVisible();await page.getByTestId('apply-editor').click();await ready();
    await expect(page.getByTestId('rendered-canvas')).toBeVisible();
    await chooseOpen(source);await page.getByTestId('open-project').click();await expect(page.getByTestId('open-project')).toBeEnabled();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await page.locator('.layer-select').filter({hasText:'Mint / 薄荷'}).click();await ready();
  });
});
test('canceled file dialogs and malformed GIF imports preserve the current document', async () => {
  await openFixture();const before=await readFile(path.join(source,'manifest.json'));
  await instance.evaluate(({dialog})=>{dialog.showSaveDialog=async()=>({canceled:true});});await menu('file-save-as');await ready();
  await instance.evaluate(({dialog})=>{dialog.showOpenDialog=async()=>({canceled:true,filePaths:[]});});await page.getByTestId('open-project').click();await ready();await expect(page.locator('.layer-row')).toHaveCount(2);
  const corrupt=path.join(temp,'broken.gif');await writeFile(corrupt,Buffer.from('GIF89a'));await chooseOpen(corrupt);await menu('file-image');await expect(page.locator('[role=alert]')).toBeVisible();
  await expect(page.locator('.layer-row')).toHaveCount(2);expect(await readFile(path.join(source,'manifest.json'))).toEqual(before);
});
test('the native recovery command restores a current-format animation without overwriting its source',async()=>{
  const before=await readFile(path.join(source,'manifest.json'));
  let data=importGIF(exportGIF({frames:[{png:png(32,24,[255,0,0,255]),durationMS:80},{png:png(32,24,[0,255,0,255]),durationMS:120}],loopCount:2}));
  data=editProject(data,{kind:'rename',id:data.manifest.activeLayerID,name:'Recover this edit'},codecs);
  const store=new RecoveryStore(path.join(temp,'user-data/recovery'));await store.write(data,crypto.randomUUID());
  await menu('file-recover');await expect(page.locator('.animation-frames button')).toHaveCount(2);await ready();
  await expect(page.getByTestId('layer-name')).toHaveValue('Recover this edit');await expect(page.locator('.badge')).toContainText('Unsaved');
  const saved=await save();expect(saved.manifest.animation).toEqual(data.manifest.animation);expect(saved.manifest.layers).toEqual(data.manifest.layers);
  expect(await readFile(path.join(source,'manifest.json'))).toEqual(before);
});
test('Escape and exporting stop animation with the displayed frame selected for subsequent editing',async()=>{
  await animation([200,6000]);await page.getByRole('button',{name:'Play',exact:true}).click();
  await expect(page.locator('.animation-frames button').nth(1)).toHaveAttribute('aria-pressed','true');await page.keyboard.press('Escape');await ready();
  await expect(page.getByRole('button',{name:'Play',exact:true})).toBeVisible();await expect(page.locator('.layer-select[aria-pressed=true]')).toContainText('Frame 2');
  await page.getByTestId('layer-name').fill('Escaped displayed frame');await page.getByTestId('layer-name').press('Tab');await ready();
  const {manifest}=await save();expect(manifest.layers.find(l=>l.name==='Escaped displayed frame').parentID).toBe(manifest.animation.frames[1].groupID);
  await page.getByRole('button',{name:'Play',exact:true}).click();await expect(page.getByRole('button',{name:'Pause',exact:true})).toBeVisible();await expect(page.locator('.animation-frames button').nth(1)).toHaveAttribute('aria-pressed','true');
  const exported=path.join(temp,'playing-frame.png');await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},exported);
  await menu('file-export-png');await expect.poll(async()=>{try{return (await readFile(exported)).length;}catch{return 0;}}).toBeGreaterThan(50);await ready();
  await expect(page.getByRole('button',{name:'Play',exact:true})).toBeVisible();await expect(page.locator('.layer-select[aria-pressed=true]')).toContainText('Escaped displayed frame');
  expect(Array.from(PNG.sync.read(await readFile(exported)).data.subarray(0,4))).toEqual([0,255,0,255]);
});
