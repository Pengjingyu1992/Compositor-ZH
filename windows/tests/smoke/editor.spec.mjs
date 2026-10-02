import {test,expect,_electron} from '@playwright/test';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {fixture} from '../fixtures.mjs';
import {BLEND_MODES} from '../../packages/comp-bridge/project.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
let temp,source,instance,page;
test.beforeEach(async()=>{
  temp=await mkdtemp(path.join(os.tmpdir(),'comp-edit-smoke-'));source=path.join(temp,'source.comp');await fixture(source);
  instance=await _electron.launch({timeout:30000,executablePath:path.join(root,'release/win-unpacked/Compositor.exe'),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader'],env:{...process.env,APPDATA:temp}});page=await instance.firstWindow();
  await instance.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});},source);
  await page.locator('.toolbar .primary').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();
});
test.afterEach(async()=>{await instance?.close();await rm(temp,{recursive:true,force:true});});
async function selectMint(){await page.getByRole('button',{name:/Mint \/ 薄荷/}).click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();}
test('edit undo redo save-as and overwrite protect the opened source',async()=>{
  const before=await readFile(path.join(source,'manifest.json'));await selectMint();
  await page.getByTestId('layer-opacity').fill('80');await page.getByTestId('layer-opacity').press('Tab');await expect(page.getByTestId('undo')).toBeEnabled();
  await page.getByTestId('undo').click();await expect(page.getByTestId('layer-opacity')).toHaveValue('50');await page.getByTestId('redo').click();await expect(page.getByTestId('layer-opacity')).toHaveValue('80');
  const copy=path.join(temp,'copy.comp');await instance.evaluate(({dialog},copy)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:copy});},copy);
  await page.getByTestId('save-as').click();await expect(page.locator('.badge')).toContainText(/已保存|Saved/);await expect(page.getByTestId('layer-opacity')).toBeEnabled();
  expect(await readFile(path.join(source,'manifest.json'))).toEqual(before);expect(JSON.parse(await readFile(path.join(copy,'manifest.json'))).layers[1].opacity).toBe(.8);
  await page.getByTestId('layer-name').fill('中文图层 / Edited');await page.getByTestId('layer-name').press('Tab');await expect(page.getByTestId('layer-opacity')).toBeEnabled();
  await page.getByTestId('save-project').click();await expect(page.locator('.statusbar [role=status]')).toContainText(/备份|backup/);
  expect(JSON.parse(await readFile(path.join(copy,'manifest.json'))).layers[1].name).toBe('中文图层 / Edited');
  await page.screenshot({path:path.join(root,'test-results/editor-preview.png')});
});
test('all 24 candidate blend modes render; adjustment and effects use the worker',async()=>{
  await selectMint();for(const mode of BLEND_MODES){await expect(page.getByTestId('blend-mode')).toBeEnabled();await page.getByTestId('blend-mode').selectOption(mode);await expect(page.getByTestId('blend-mode')).toBeEnabled();expect(await page.getByTestId('rendered-canvas').evaluate(c=>c.getContext('2d').getImageData(32,24,1,1).data[3])).toBe(255);}
  await page.getByLabel('添加调整层',{exact:true}).selectOption('Invert');await expect(page.locator('.layer-row')).toHaveCount(3);await expect(page.getByTestId('layer-opacity')).toBeEnabled();
  await page.getByTestId('delete-layer').click();await selectMint();await page.getByLabel('添加效果',{exact:true}).selectOption('colorOverlay');await expect(page.getByTestId('layer-opacity')).toBeEnabled();
  expect(await page.getByTestId('rendered-canvas').evaluate(c=>c.getContext('2d').getImageData(32,24,1,1).data[3])).toBe(255);
});
test('mask edits and PNG/PSD exports work through the shipped executable',async()=>{
  await selectMint();await page.getByTestId('invert-mask').click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();
  for(const type of ['png','psd']){const destination=path.join(temp,`export.${type}`);await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},destination);await page.getByTestId(`export-${type}`).click();if(type==='psd')await page.getByRole('button',{name:'分层导出',exact:true}).click();await expect(page.locator('.statusbar [role=status]')).toContainText('已导出');await expect(page.getByTestId('layer-opacity')).toBeEnabled();const bytes=await readFile(destination);expect(bytes.length).toBeGreaterThan(26);if(type==='psd')expect(bytes.toString('ascii',0,4)).toBe('8BPS');}
});
test('painting is one undo step and new canvas has a width-height swap',async()=>{
  await selectMint();await page.getByRole('button',{name:'画笔',exact:true}).click();const board=await page.locator('.artboard').boundingBox();await page.mouse.move(board.x+20,board.y+20);await page.mouse.down();await page.waitForTimeout(300);await page.mouse.move(board.x+35,board.y+25,{steps:6});await page.mouse.up();await expect(page.getByTestId('undo')).toBeEnabled();await page.getByTestId('undo').click();await expect(page.getByTestId('redo')).toBeEnabled();
  await page.getByTestId('new-canvas').click();await page.getByRole('button',{name:'互换宽高'}).click();const numbers=page.locator('.new-dimensions input');await expect(numbers.nth(0)).toHaveValue('1080');await expect(numbers.nth(1)).toHaveValue('1920');await numbers.nth(0).fill('64');await numbers.nth(1).fill('48');await page.getByRole('button',{name:'创建',exact:true}).click();await expect(page.locator('.layer-row')).toHaveCount(0);await page.getByTestId('add-pixels').click();await expect(page.locator('.layer-row')).toHaveCount(1);
});
