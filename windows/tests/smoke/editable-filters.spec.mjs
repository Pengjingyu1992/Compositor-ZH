import { test, expect, _electron } from '@playwright/test';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fixture, IDS } from '../fixtures.mjs';
import { smokeExecutable, smokeArgs, smokeEnv } from './electron-launch.mjs';

test('editable filter and Liquify workspaces retain recipes and re-edit saved deformation without changing the original package',async()=>{
  test.setTimeout(120000);const directory=await mkdtemp(path.join(os.tmpdir(),'comp-stack-ui-')),source=path.join(directory,'source.comp'),saved=path.join(directory,'saved.comp');
  await fixture(source);const original=await readFile(path.join(source,'manifest.json'));let instance;const errors=[];
  try{
    instance=await _electron.launch({executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(directory)});const page=await instance.firstWindow();page.on('pageerror',error=>errors.push(error.message));
    const menu=async id=>instance.evaluate(({Menu},id)=>Menu.getApplicationMenu().getMenuItemById(id).click(),id);
    await page.getByTestId('language').selectOption('en');await instance.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});},source);
    await page.getByTestId('open-project').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await page.locator('.layer-select').filter({hasText:'Coral / 珊瑚'}).click();
    await menu('filter-filterStack');await expect(page.getByTestId('apply-filter-stack')).toBeEnabled();await page.getByTestId('stack-add-kind').selectOption('Add Noise');await page.getByTestId('stack-add').click();
    await page.getByLabel('Amount',{exact:true}).fill('70');await page.getByTestId('stack-preview-refresh').click();await expect(page.getByTestId('apply-filter-stack')).toBeEnabled();
    await page.getByTestId('stack-add-kind').selectOption('Advanced Liquify');await page.getByTestId('stack-add').click();
    const workspace=page.getByRole('dialog',{name:'Advanced Liquify',exact:true});await expect(workspace).toBeVisible();await expect(page.getByTestId('apply-liquify')).toBeEnabled();
    await workspace.getByLabel('Diameter',{exact:true}).fill('24');await workspace.getByLabel('Fix edges',{exact:true}).uncheck();
    const canvas=page.getByTestId('liquify-canvas'),bounds=await canvas.boundingBox();
    await page.mouse.move(bounds.x+bounds.width*.35,bounds.y+bounds.height*.5);await page.mouse.down();await page.mouse.move(bounds.x+bounds.width*.65,bounds.y+bounds.height*.5,{steps:4});await page.mouse.up();
    await expect(workspace.getByRole('button',{name:'Undo stroke',exact:true})).toBeEnabled();await workspace.getByRole('button',{name:'Undo stroke',exact:true}).click();await workspace.getByRole('button',{name:'Redo stroke',exact:true}).click();
    await page.getByTestId('apply-liquify').click();await expect(workspace).toHaveCount(0);await expect(page.getByTestId('apply-filter-stack')).toBeEnabled();
    await page.getByTestId('apply-filter-stack').click();await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByTestId('undo')).toBeEnabled();
    await instance.evaluate(({dialog},saved)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:saved});},saved);await menu('file-save-as');await expect(page.locator('.badge')).toContainText('Saved');
    const manifest=JSON.parse(await readFile(path.join(saved,'manifest.json'),'utf8')),recipe=manifest.layers.find(layer=>layer.id===IDS[0]).editableFilters;
    expect(manifest.version).toBe(14);expect(recipe.nodeFiles).toHaveLength(2);const node=JSON.parse(await readFile(path.join(saved,'edits',recipe.nodeFiles[1]),'utf8'));expect(node.kind).toBe('Advanced Liquify');expect(node.liquify.diameter).toBe(24);
    const field=Buffer.from(node.liquify.field,'base64');expect([...new Float32Array(field.buffer,field.byteOffset,field.length/4)].some((value,index)=>index%3!==2&&value!==0)).toBe(true);
    await instance.evaluate(({dialog},saved)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[saved]});},saved);await page.getByTestId('open-project').click();await expect(page.getByTestId('save-project')).toBeEnabled();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await page.locator('.layer-select').filter({hasText:'Coral / 珊瑚'}).click();await menu('filter-filterStack');
    await expect(page.getByTestId('apply-filter-stack')).toBeEnabled();await page.getByRole('button',{name:'2. Advanced Liquify',exact:true}).click();await page.getByTestId('edit-saved-liquify').click();await expect(page.getByTestId('apply-liquify')).toBeEnabled();await expect(workspace.getByLabel('Diameter',{exact:true})).toHaveValue('24');
    await page.keyboard.press('Escape');await expect(workspace).toHaveCount(0);await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByTestId('undo')).toBeDisabled();
    expect(await readFile(path.join(source,'manifest.json'))).toEqual(original);expect(errors).toEqual([]);
  }finally{await instance?.close();await rm(directory,{recursive:true,force:true});}
});
