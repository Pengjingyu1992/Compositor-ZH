import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { PNG } from 'pngjs';
import { fixture, png, IDS } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

let temp, source, app, page, original, errors, saveIndex;
const placements = [ [[10,20],[40,30]], [[90,80],[20,60]], [[200,160],[60,20]] ];
test.describe.configure({ timeout: 240000 });
test.beforeEach(async () => {
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-control-matrix-'));
  source = path.join(temp, 'controls.comp'); saveIndex = 0; errors = [];
  await fixture(source, m => {
    m.width = 320; m.height = 240;
    m.layers.push({ ...structuredClone(m.layers[0]), id: IDS[2], name: 'Amber', imageFile: IDS[2]+'.png' });
    m.layers.forEach((row,i) => { row.transform.origin = placements[i][0]; row.transform.size = placements[i][1]; });
    return m;
  });
  await writeFile(path.join(source, 'images', IDS[2]+'.png'), png(64,48,[220,180,80,255]));
  original = await readFile(path.join(source, 'manifest.json'));
  app = await _electron.launch({ timeout:30000, executablePath:smokeExecutable(), args:smokeArgs(), env:smokeEnv(temp) });
  page = await app.firstWindow(); page.on('pageerror', e => errors.push(e.message));
  await app.evaluate(({ dialog, BrowserWindow }, source) => {
    dialog.showOpenDialog = async () => ({ canceled:false, filePaths:[source] });
    dialog.showMessageBox = async () => ({ response:1 });
    BrowserWindow.getAllWindows()[0].setContentSize(1280,800);
  }, source);
  await expect(page.getByTestId('open-project')).toBeEnabled();
  await page.getByTestId('language').selectOption('en'); await page.getByTestId('open-project').click();
  await ready(); await expect(page.getByTestId('rendered-canvas')).toBeVisible();
});
test.afterEach(async () => {
  await app?.close(); expect(errors).toEqual([]);
  expect(await readFile(path.join(source, 'manifest.json'))).toEqual(original);
  await rm(temp, { recursive:true, force:true });
});
async function ready() {
  await expect(page.getByTestId('save-project')).toBeEnabled();
  await expect(page.locator('[role=alert]')).toHaveCount(0);
}
async function command(name) {
  await app.evaluate(({ BrowserWindow }, name) => BrowserWindow.getAllWindows()[0].webContents.send('editor:'+name), name);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await ready();
}
async function save() {
  const folder = path.join(temp, 'snapshot-'+(++saveIndex)+'.comp');
  await app.evaluate(({ dialog }, folder) => { dialog.showSaveDialog = async () => ({ canceled:false, filePath:folder }); }, folder);
  await command('saveAs');
  await expect.poll(async () => { try { return JSON.parse(await readFile(path.join(folder,'manifest.json'),'utf8')).format; } catch { return ''; } }, {timeout:30000}).toBe('com.compositor.project');
  await ready(); return { folder, manifest:JSON.parse(await readFile(path.join(folder,'manifest.json'),'utf8')) };
}
async function undo(count=1) { for(let i=0;i<count;i++) { await page.getByTestId('undo').click(); await ready(); } }
const row = name => page.locator('.layer-select').filter({ hasText:name });

test('every alignment and distribution button uses the selected, canvas and key-layer references and undoes cleanly', async () => {
  await row('Coral / 珊瑚').click(); await row('Mint / 薄荷').click({modifiers:['Control']}); await row('Amber').click({modifiers:['Control']});
  const panel = page.locator('.complete-panel');
  // Expected positions are independent, hand-calculated rectangle references.
  const cases = [
    ['Align left', [[10,20],[10,80],[10,160]]], ['Align horizontal centers', [[115,20],[125,80],[105,160]]],
    ['Align right', [[220,20],[240,80],[200,160]]], ['Align top', [[10,20],[90,20],[200,20]]],
    ['Align vertical centers', [[10,85],[90,70],[200,90]]], ['Align bottom', [[10,150],[90,120],[200,160]]],
    ['Distribute horizontal centers', [[10,20],[120,80],[200,160]]], ['Distribute vertical centers', [[10,20],[90,72.5],[200,160]]],
    ['Distribute horizontal gaps', [[10,20],[115,80],[200,160]]], ['Distribute vertical gaps', [[10,20],[90,75],[200,160]]]
  ];
  for (const [name, expected] of cases) await test.step(name, async () => {
    await panel.getByRole('button',{name,exact:true}).click(); await ready();
    expect((await save()).manifest.layers.map(l=>l.transform.origin)).toEqual(expected); await undo();
  });
  await panel.getByLabel(/^Reference/).selectOption('canvas');
  await panel.getByRole('button',{name:'Align left',exact:true}).click(); await ready();
  expect((await save()).manifest.layers.map(l=>l.transform.origin[0])).toEqual([0,0,0]); await undo();
  await panel.getByLabel(/^Reference/).selectOption('keyObject');
  await panel.getByRole('button',{name:'Align top',exact:true}).click(); await ready();
  expect((await save()).manifest.layers.map(l=>l.transform.origin[1])).toEqual([160,160,160]); await undo();
  expect((await save()).manifest.layers.map(l=>l.transform.origin)).toEqual(placements.map(v=>v[0]));
});

test('selection panel buttons invalidate their overlay and crop, trim and both canvas flips preserve undo', async () => {
  await row('Coral / 珊瑚').click(); await page.getByRole('button',{name:'Marquee',exact:true}).click();
  const panel = page.locator('.complete-panel'); await panel.getByText('Selection',{exact:true}).click();
  const alpha = (x,y) => page.locator('.paint-overlay').evaluate((c,[x,y])=>c.getContext('2d').getImageData(x,y,1,1).data[3],[x,y]);
  const box = await page.locator('.artboard').boundingBox();
  await page.mouse.move(box.x+box.width*.2,box.y+box.height*.25); await page.mouse.down();
  await page.mouse.move(box.x+box.width*.6,box.y+box.height*.7,{steps:6}); await page.mouse.up(); await ready();
  await expect.poll(()=>alpha(100,100)).toBeGreaterThan(0); expect(await alpha(62,100)).toBe(0);
  for (const [name,point,covered] of [['Expand',[62,100],true],['Contract',[62,100],false],['Feather',[64,100],true],['Invert selection',[100,100],false],['Deselect',[5,5],false],['Select all',[5,5],true]]) {
    await panel.getByRole('button',{name,exact:true}).click(); await ready();
    if(covered) await expect.poll(()=>alpha(...point)).toBeGreaterThan(0); else await expect.poll(()=>alpha(...point)).toBe(0);
  }
  await panel.getByRole('button',{name:'Deselect',exact:true}).click(); await ready();
  await command('selectAll'); await command('cropSelection'); expect([(await save()).manifest.width,(await save()).manifest.height]).toEqual([320,240]);
  await command('deselect');
  for (const [name,axis,expected] of [['flipCanvasH',0,[270,210,60]],['flipCanvasV',1,[190,100,60]]]) {
    await command(name); const m=(await save()).manifest;
    expect(m.layers.map(l=>l.transform.origin[axis])).toEqual(expected); expect(m.layers.every(l=>l.transform[axis?'flipY':'flipX'])).toBe(true); await undo();
  }
  await panel.getByText('Image size',{exact:true}).first().click();
  await panel.getByRole('button',{name:'Trim transparent edges',exact:true}).click(); await ready();
  const trimmed=(await save()).manifest; expect([trimmed.width,trimmed.height]).toEqual([250,160]); await undo();
  const restored=(await save()).manifest; expect([restored.width,restored.height]).toEqual([320,240]); expect(restored.layers.map(l=>l.transform.origin)).toEqual(placements.map(v=>v[0]));
});

test('mask enable, link, invert, remove and apply buttons plus effect disable and remove preserve independent history', async () => {
  await row('Mint / 薄荷').click(); const mask=page.locator('.inspector details').filter({has:page.getByText('Mask',{exact:true})});
  await mask.getByRole('checkbox').nth(0).uncheck(); await ready(); expect((await save()).manifest.layers[1].maskEnabled).toBe(false); await undo();
  await mask.getByRole('checkbox').nth(1).uncheck(); await ready(); const unlinked=(await save()).manifest.layers[1]; expect(unlinked.maskLinked).toBe(false); expect(unlinked.maskPlacement.origin).toEqual([90,80]); await undo();
  await page.getByTestId('invert-mask').click(); await ready(); const inverted=await save();
  expect(PNG.sync.read(await readFile(path.join(inverted.folder,'images',inverted.manifest.layers[1].maskFile))).data[0]).toBe(127); await undo();
  await mask.getByRole('button',{name:'Remove mask',exact:true}).click(); await ready(); expect((await save()).manifest.layers[1].maskFile).toBeUndefined(); await undo();
  await page.locator('.complete-panel').getByRole('button',{name:'Apply mask',exact:true}).click(); await ready(); const applied=await save();
  expect(applied.manifest.layers[1].maskFile).toBeUndefined(); expect(PNG.sync.read(await readFile(path.join(applied.folder,'images',applied.manifest.layers[1].imageFile))).data[3]).toBe(128); await undo();
  await page.getByRole('tab',{name:'Effects',exact:true}).click(); await page.getByLabel('Add effect',{exact:true}).selectOption('colorOverlay'); await ready();
  await page.locator('.inspector').getByRole('checkbox',{name:'Enabled',exact:true}).uncheck(); await ready(); expect((await save()).manifest.layers[1].effects.colorOverlay.enabled).toBe(false);
  await page.locator('.inspector').getByRole('button',{name:'Remove',exact:true}).click(); await ready(); expect((await save()).manifest.layers[1].effects?.colorOverlay).toBeUndefined(); await undo(3);
  const restored=(await save()).manifest.layers[1]; expect(restored.maskFile).toBe(IDS[1]+'.mask.png'); expect(restored.effects?.colorOverlay).toBeUndefined();
});

test('color panel add and remove, invalid Hex rollback and canceled settings leave the document untouched', async () => {
  await command('palette'); const panel=page.getByRole('region',{name:'Color panel',exact:true});
  await page.getByTestId('palette-hex').fill('#123456'); await page.getByTestId('palette-hex').press('Tab');
  await panel.getByRole('button',{name:'Add swatch',exact:true}).click(); await panel.getByRole('button',{name:'#123456',exact:true}).click();
  await panel.getByRole('button',{name:'Remove',exact:true}).click(); await expect(panel.getByRole('button',{name:'#123456',exact:true})).toHaveCount(0);
  await page.getByTestId('palette-hex').fill('#zzzzzz'); await page.getByTestId('palette-hex').press('Tab'); await expect(page.getByTestId('palette-hex')).toHaveValue('#123456');
  await panel.getByRole('button',{name:'Add swatch',exact:true}).click(); await panel.getByRole('button',{name:'#123456',exact:true}).focus(); await page.keyboard.press('Delete'); await expect(panel.getByRole('button',{name:'#123456',exact:true})).toHaveCount(0);
  await panel.getByRole('button',{name:'Close',exact:true}).click(); await expect(panel).toHaveCount(0);
  const before=await page.evaluate(()=>window.viewer.viewSettings()); await command('viewSettings'); await page.getByTestId('grid-spacing').fill('99');
  await page.getByRole('dialog').getByRole('button',{name:'Cancel',exact:true}).click(); expect((await page.evaluate(()=>window.viewer.viewSettings())).settings.gridSpacing).toBe(before.settings.gridSpacing);
  await expect(page.getByTestId('undo')).toBeDisabled();
});

test('filter presets, channel reset, curve reset and the LUT chooser update drafts and cancel without editing pixels', async () => {
  await row('Coral / 珊瑚').click(); await command('filter'); const dialog=page.getByRole('dialog');
  await page.getByTestId('filter-kind').selectOption('Color Halftone');
  await dialog.getByRole('button',{name:/Newsprint/}).click(); await expect(dialog.locator('.style-fields input[type=number]').first()).toHaveValue('5');
  await dialog.getByRole('button',{name:/Pop art/i}).click(); await expect(dialog.locator('.style-fields input[type=number]').first()).toHaveValue('18'); await expect(dialog.locator('.style-fields select').nth(1)).toHaveValue('Square');
  await dialog.getByRole('button',{name:/Default/}).click(); await expect(dialog.locator('.style-fields input[type=number]').first()).toHaveValue('8'); await expect(dialog.locator('.style-fields select').nth(1)).toHaveValue('Round');
  await page.getByTestId('filter-kind').selectOption('Channel Mixer'); await dialog.locator('fieldset input[type=number]').first().fill('20');
  await dialog.getByRole('button',{name:/Default/}).click(); expect(await dialog.locator('fieldset input[type=number]').evaluateAll(inputs=>inputs.map(el=>Number(el.value)))).toEqual([100,0,0,0,0,100,0,0,0,0,100,0]);
  await page.getByTestId('filter-kind').selectOption('Curves'); await dialog.locator('.curve-editor').click({position:{x:60,y:70}}); await expect(dialog.locator('.curve-editor circle')).toHaveCount(3);
  await dialog.getByRole('button',{name:'Reset curve',exact:true}).click(); await expect(dialog.locator('.curve-editor circle')).toHaveCount(2);
  await page.getByTestId('filter-kind').selectOption('Color Lookup');
  const [chooser]=await Promise.all([page.waitForEvent('filechooser'),dialog.getByRole('button',{name:/Choose.*LUT/}).click()]);
  await chooser.setFiles({name:'identity.cube',mimeType:'text/plain',buffer:Buffer.from('LUT_1D_SIZE 2\n0 0 0\n1 1 1')});
  await expect(dialog).toContainText('identity.cube'); await page.getByTestId('update-preview').click(); await expect(page.getByTestId('apply-editor')).toBeEnabled(); await expect(dialog.locator('.editor-preview img')).toBeVisible();
  await dialog.getByRole('button',{name:'Cancel',exact:true}).click(); await expect(dialog).toHaveCount(0); await expect(page.getByTestId('undo')).toBeDisabled();
});

test('mask thumbnails cannot change the paint target while animation locks layer controls', async () => {
  await page.getByRole('button',{name:'Create animation',exact:true}).click(); await ready();
  await row('Mint / 薄荷').click(); await page.getByRole('button',{name:'Brush',exact:true}).click();
  const target=page.getByRole('combobox',{name:'Paint target',exact:true}),mask=page.locator('.mask-thumbnail').first();
  await expect(target).toHaveValue('content'); await page.getByRole('button',{name:'Play',exact:true}).click();
  await expect(page.getByRole('button',{name:'Pause',exact:true})).toBeVisible(); await expect(page.locator('.layer-select').first()).toBeDisabled();
  await mask.evaluate(button=>button.click()); await expect(target).toHaveValue('content'); await expect(mask).toBeDisabled();
  await page.getByRole('button',{name:'Pause',exact:true}).click(); await ready(); await expect(mask).toBeEnabled();
  await mask.click(); await expect(target).toHaveValue('mask');
});
