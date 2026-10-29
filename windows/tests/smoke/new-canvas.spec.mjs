import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';
import { png } from '../fixtures.mjs';
import { PNG } from 'pngjs';
import { waitForSaved } from './save-check.mjs';

const output = process.env.COMPOSITOR_CANVAS_REVIEW_OUTPUT ?? fileURLToPath(new URL('../../test-results/', import.meta.url));
let app, page, temp;
test.beforeEach(async () => {
  await mkdir(output, { recursive: true });
  temp = await mkdtemp(path.join(os.tmpdir(), 'comp-new-canvas-'));
  app = await _electron.launch({ executablePath: smokeExecutable(), args: smokeArgs(), env: smokeEnv(temp) });
  page = await app.firstWindow();
  await app.evaluate(({ BrowserWindow, clipboard, dialog }) => { clipboard.clear(); dialog.showMessageBox=async()=>({response:1}); BrowserWindow.getAllWindows()[0].setContentSize(1280, 800); });
  await expect(page.locator('.welcome')).toBeVisible();
  await page.getByTestId('language').selectOption('en');
});
test.afterEach(async () => {
  if (app) { await app.evaluate(({dialog})=>{dialog.showMessageBox=async()=>({response:1});}); await app.close(); }
  await rm(temp, { recursive: true, force: true });
});
async function capture(name) { await page.screenshot({ animations: 'disabled', path: path.join(output, `new-canvas-${name}-preview.png`) }); }
async function appearance(value) {
  await page.getByTestId('interface-settings').click();
  await page.getByTestId('interface-appearance').selectOption(value);
  await page.getByTestId('apply-view-settings').click();
}

test('new canvas matches the macOS card in the welcome view and dialog at both desktop sizes', async () => {
  await appearance('light'); await capture('welcome-light');
  await appearance('dark'); await page.getByTestId('new-canvas').click(); await capture('dialog-dark');
  await page.keyboard.press('Escape');
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setContentSize(880, 540));
  await page.getByTestId('language').selectOption('zh-Hans'); await capture('welcome-compact');
  await page.locator('.stage').hover(); await page.mouse.wheel(0,800);
  await expect(page.getByTestId('create-canvas')).toBeInViewport({ratio:1}); await capture('welcome-compact-actions');
  await page.getByTestId('new-canvas').click(); await capture('dialog-compact');
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('1920 × 1080 px');
  await expect(page.getByTestId('canvas-unit')).toHaveValue('px');
  await expect(page.getByTestId('canvas-resolution')).toHaveValue('72');
  await expect(page.getByTestId('canvas-background')).toHaveValue('transparent');
  await page.getByTestId('create-canvas').scrollIntoViewIfNeeded();
  await expect(page.getByTestId('create-canvas')).toBeInViewport({ ratio: 1 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('presets, print units, resolution and backgrounds create and save actual document settings', async () => {
  await page.getByRole('button', { name: '4K', exact: true }).click();
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('3840 × 2160 px');
  await page.getByTestId('canvas-preset').selectOption('studio');
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('5120 × 2880 px');
  await expect(page.getByTestId('canvas-custom')).toHaveAttribute('aria-pressed','true');
  for (const unit of ['cm', 'mm', 'in', 'px']) {
    await page.getByTestId('canvas-unit').selectOption(unit);
    await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('5120 × 2880 px');
  }
  await page.getByTestId('canvas-width').fill('30000'); await page.getByTestId('canvas-height').fill('30000');
  await expect(page.getByTestId('create-canvas')).toBeDisabled();
  await expect(page.getByRole('alert')).toContainText('16 megapixels');
  await page.getByTestId('canvas-unit').selectOption('in');
  await page.getByTestId('canvas-width').fill('1'); await page.getByTestId('canvas-height').fill('2');
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('72 × 144 px');
  await page.getByTestId('canvas-resolution').selectOption('300');
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('300 × 600 px');
  await page.getByTestId('canvas-background').selectOption('white'); await capture('white-print');
  await page.getByTestId('canvas-height').press('Enter');
  await expect(page.getByTestId('save-project')).toBeEnabled();
  await expect(page.locator('.layer-row')).toHaveCount(1); await expect(page.getByTestId('undo')).toBeDisabled();
  const pixel = () => page.getByTestId('rendered-canvas').evaluate(canvas => [...canvas.getContext('2d').getImageData(20,20,1,1).data]);
  expect(await pixel()).toEqual([255,255,255,255]);
  const destination=path.join(temp,'white.comp');
  await app.evaluate(({dialog},destination)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:destination});},destination);
  await page.getByTestId('save-project').click();
  await waitForSaved(page,async()=>{try{return JSON.parse(await readFile(path.join(destination,'manifest.json'),'utf8')).resolution===300;}catch{return false;}});
  const manifest=JSON.parse(await readFile(path.join(destination,'manifest.json'),'utf8'));expect([manifest.width,manifest.height]).toEqual([300,600]);
  const image=PNG.sync.read(await readFile(path.join(destination,'images',manifest.layers[0].imageFile)));expect([image.width,image.height]).toEqual([300,600]);expect([...image.data.subarray(0,4)]).toEqual([255,255,255,255]);
  await page.getByTestId('new-tab').click();
  await expect(page.getByTestId('canvas-unit')).toHaveValue('px'); await expect(page.getByTestId('canvas-resolution')).toHaveValue('72'); await expect(page.getByTestId('canvas-background')).toHaveValue('transparent');
  await page.getByTestId('canvas-width').fill('64'); await page.getByTestId('canvas-height').fill('48'); await page.getByTestId('canvas-background').selectOption('black');
  await page.getByTestId('create-canvas').click(); await expect(page.getByTestId('save-project')).toBeEnabled();
  await expect(page.locator('.document-tabs [role=tab]')).toHaveCount(2); await expect(page.getByTestId('undo')).toBeDisabled();
  expect(await pixel()).toEqual([0,0,0,255]);
  await page.locator('.document-tabs [role=tab]').first().click(); await expect(page.getByTestId('save-project')).toBeEnabled();expect(await pixel()).toEqual([255,255,255,255]);
});

test('canceling replacement preserves the draft and invalid creation cannot discard the active project', async () => {
  await page.getByTestId('canvas-width').fill('64');await page.getByTestId('canvas-height').fill('48');await page.getByTestId('create-canvas').click();
  await expect(page.getByTestId('save-project')).toBeEnabled();
  const before=await page.evaluate(()=>window.editor.workspace('list'));
  await app.evaluate(({dialog})=>{dialog.showMessageBox=async()=>({response:0});});
  await page.getByTestId('new-canvas').click();await page.getByTestId('canvas-width').fill('45');await page.getByTestId('canvas-height').fill('33');
  await page.getByTestId('create-canvas').click();await expect(page.getByTestId('create-canvas')).toBeEnabled();
  await expect(page.getByRole('dialog')).toBeVisible();await expect(page.getByTestId('canvas-width')).toHaveValue('45');await expect(page.getByTestId('canvas-height')).toHaveValue('33');
  await page.keyboard.press('Escape');
  const invalid=await page.evaluate(()=>window.editor.create(5000,5000,{background:'white',resolution:300}));expect(invalid.error).toBe('limit');
  expect((await page.evaluate(()=>window.editor.workspace('list'))).workspace.activeID).toBe(before.workspace.activeID);
  expect(await page.getByTestId('rendered-canvas').evaluate(canvas=>[canvas.width,canvas.height])).toEqual([64,48]);
  await expect(page.getByTestId('undo')).toBeDisabled();
});

test('clipboard suggestions expose only dimensions and a delayed response cannot replace typed values', async () => {
  await app.evaluate(async({clipboard,ClipboardItem},bytes)=>{
    await clipboard.write([new ClipboardItem({'image/png':new Blob([new Uint8Array(bytes)],{type:'image/png'}),'text/plain':new Blob(['synthetic clipboard text'],{type:'text/plain'})})]);
    globalThis.canvasTextReads=0;const read=clipboard.read.bind(clipboard);
    clipboard.read=async()=> (await read()).map(item=>({types:item.types,getType(type){if(type==='text/plain')globalThis.canvasTextReads++;return item.getType(type);}}));
  },[...png(17,29,[0,128,255,255])]);
  await page.getByTestId('new-canvas').click();await expect(page.getByTestId('canvas-width')).toHaveValue('17');await expect(page.getByTestId('canvas-height')).toHaveValue('29');
  const size=await page.evaluate(()=>window.editor.canvasClipboardSize());expect(size).toEqual({width:17,height:29});expect(await app.evaluate(()=>globalThis.canvasTextReads)).toBe(0);
  await page.keyboard.press('Escape');
  await app.evaluate(({ipcMain})=>{ipcMain.removeHandler('editor:canvasClipboardSize');ipcMain.handle('editor:canvasClipboardSize',async()=>{await new Promise(resolve=>setTimeout(resolve,300));return {width:99,height:77};});});
  await page.getByTestId('new-canvas').click();await page.getByTestId('canvas-width').fill('55');await page.getByTestId('canvas-height').fill('44');
  await page.evaluate(()=>window.editor.canvasClipboardSize());
  await expect(page.getByTestId('canvas-width')).toHaveValue('55');await expect(page.getByTestId('canvas-height')).toHaveValue('44');
  await expect(page.getByTestId('canvas-preview-dimensions')).toHaveText('55 × 44 px');
  expect(await page.locator('body').innerText()).not.toContain('synthetic clipboard text');
});
