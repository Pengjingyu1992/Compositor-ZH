import {test,expect,_electron} from '@playwright/test';
import {mkdtemp,rm,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {fixture,png} from '../fixtures.mjs';
import {exportGIF} from '../../packages/comp-bridge/codecs.mjs';
import {smokeExecutable,smokeArgs,smokeEnv} from './electron-launch.mjs';

const output=fileURLToPath(new URL('../../test-results/',import.meta.url));
test.describe.configure({timeout:120000});
let temp,source,instance,page,original;
test.beforeEach(async()=>{
  temp=await mkdtemp(path.join(os.tmpdir(),'comp-desktop-boundaries-'));source=path.join(temp,'synthetic.comp');await fixture(source);original=await readFile(path.join(source,'manifest.json'));
  instance=await _electron.launch({timeout:30000,executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});page=await instance.firstWindow();
  await instance.evaluate(({dialog,BrowserWindow},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});BrowserWindow.getAllWindows()[0].setContentSize(1280,800);},source);
  await page.getByTestId('language').selectOption('en');await page.getByTestId('open-project').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await page.locator('.layer-select').filter({hasText:'Mint / 薄荷'}).click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();
});
test.afterEach(async()=>{await instance?.close();expect(await readFile(path.join(source,'manifest.json'))).toEqual(original);await rm(temp,{recursive:true,force:true});});
async function command(channel){await instance.evaluate(({BrowserWindow},channel)=>BrowserWindow.getAllWindows()[0].webContents.send(channel),channel);await page.evaluate(()=>window.viewer.settings());}
async function ready(){await expect(page.getByTestId('save-project')).toBeEnabled();}

test('AI settings contain keyboard edits, trap focus, and return focus on Escape',async()=>{
  const trigger=page.getByTestId('ai-settings');await trigger.click();const dialog=page.getByRole('dialog',{name:'AI settings',exact:true});await expect(dialog).toBeVisible();
  await page.getByTestId('ai-save-settings').focus();await page.keyboard.press('Delete');await ready();await expect(page.locator('.layer-row')).toHaveCount(2);await expect(page.getByTestId('undo')).toBeDisabled();
  await page.getByTestId('ai-save-settings').focus();await page.keyboard.press('Tab');expect(await dialog.evaluate(el=>el.contains(document.activeElement))).toBe(true);
  await page.screenshot({animations:'disabled',path:path.join(output,'desktop-boundaries-modal-preview.png')});await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);await expect(trigger).toBeFocused();
});

for(const kind of ['AI','workspace'])test(`${kind} settings prevent native project edits, file commands, and nested dialogs`,async()=>{
  await page.getByTestId(kind==='AI'?'ai-settings':'interface-settings').click();const dialog=page.getByRole('dialog');await expect(dialog).toHaveCount(1);await dialog.getByRole('button',{name:kind==='AI'?'Save':'Apply',exact:true}).focus();
  await command('editor:delete');await ready();await expect(page.locator('.layer-row')).toHaveCount(2);await expect(page.getByTestId('undo')).toBeDisabled();
  await command('editor:new');await expect(page.getByRole('dialog')).toHaveCount(1);await command('viewer:close');await expect(page.getByTestId('rendered-canvas')).toBeVisible();await expect(page.locator('.document-tabs [role=tab]')).toHaveCount(1);
  await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);
});

test('text dialog keeps its first textarea inside the keyboard focus loop',async()=>{
  await command('editor:text');const dialog=page.getByRole('dialog');const field=page.getByTestId('text-content');await expect(field).toBeVisible();await field.fill('Draft text');await expect(page.getByTestId('apply-editor')).toBeEnabled();await field.focus();await page.keyboard.press('Shift+Tab');await expect(page.getByTestId('apply-editor')).toBeFocused();await page.keyboard.press('Tab');await expect(field).toBeFocused();await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);await expect(page.getByTestId('undo')).toBeDisabled();
});

test('expanded assistant stays usable after resize and a tall saved panel cannot hide editor controls',async()=>{
  await page.getByTestId('ai-fold').click();const grip=page.locator('.assistant-grip');let bounds=await grip.boundingBox();await page.mouse.move(bounds.x+bounds.width/2,bounds.y+3);await page.mouse.down();await page.mouse.move(bounds.x+bounds.width/2,150,{steps:6});await page.mouse.up();
  await instance.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setContentSize(880,540));await expect(page.getByTestId('ai-prompt')).toBeInViewport({ratio:1});await expect(page.locator('.toolrail-footer').getByRole('button',{name:'Default black and white',exact:true})).toBeInViewport({ratio:1});expect(await page.locator('.stage').evaluate(el=>el.clientHeight)).toBeGreaterThanOrEqual(200);
  await page.screenshot({animations:'disabled',path:path.join(output,'desktop-boundaries-ai-compact-preview.png')});expect(await page.locator('.inspector-panel').evaluate(el=>el.clientHeight)).toBeGreaterThanOrEqual(100);await page.getByTestId('layer-name').scrollIntoViewIfNeeded();await expect(page.getByTestId('layer-name')).toBeInViewport({ratio:1});await expect(page.getByTestId('undo')).toBeDisabled();
  await instance.close();instance=await _electron.launch({timeout:30000,executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});page=await instance.firstWindow();await instance.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setContentSize(880,540));await expect(page.getByTestId('ai-fold')).toHaveAttribute('aria-expanded','true');await expect(page.getByTestId('ai-prompt')).toBeInViewport({ratio:1});await expect(page.locator('.toolrail-footer').getByRole('button',{name:'Default black and white',exact:true})).toBeInViewport({ratio:1});
});

test('Space activates a focused editor button without starting animation',async()=>{
  const gif=path.join(temp,'synthetic.gif');await writeFile(gif,exportGIF({frames:[{png:png(24,20,[255,0,0,255]),durationMS:1000},{png:png(24,20,[0,255,0,255]),durationMS:1000}],loopCount:0}));
  await instance.evaluate(({dialog},gif)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[gif]});dialog.showSaveDialog=async()=>({canceled:true});},gif);await command('editor:image');await expect(page.locator('.animation-frames button')).toHaveCount(2);await ready();const fit=page.getByRole('button',{name:'Fit to window',exact:true});await fit.focus();await page.keyboard.press('Space');await expect(page.locator('.animation-actions').getByRole('button',{name:'Play',exact:true})).toBeVisible();
});

test('dropping an external image on AI settings cannot edit the covered project',async()=>{
  await page.getByTestId('ai-settings').click();const dialog=page.getByRole('dialog',{name:'AI settings',exact:true});await expect(dialog).toBeVisible();await page.evaluate(bytes=>{const transfer=new DataTransfer();transfer.items.add(new File([new Uint8Array(bytes)],'synthetic-drop.png',{type:'image/png'}));document.querySelector('.modal-shade').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));},[...png(24,20,[255,0,0,255])]);
  await ready();await expect(page.locator('.layer-row')).toHaveCount(2);await expect(page.getByTestId('undo')).toBeDisabled();await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);
});
