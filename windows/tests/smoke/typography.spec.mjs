import{test,expect,_electron}from'@playwright/test';
import{mkdtemp,rm,readFile}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{fixture,IDS}from'../fixtures.mjs';
import{defaultVectorPath}from'../../packages/comp-bridge/layer-styles.mjs';
import{smokeExecutable,smokeArgs,smokeEnv}from'./electron-launch.mjs';

test('vertical, justified, arc and path text remain editable; text outlines preserve geometry and undo',async()=>{
  test.setTimeout(180000);const temp=await mkdtemp(path.join(os.tmpdir(),'comp-type-ui-')),source=path.join(temp,'source.comp');let instance;
  const vector=defaultVectorPath();vector.contours[0].anchors=[{point:[.1,.5]},{point:[.9,.5]}];
  await fixture(source,m=>{m.width=640;m.height=480;m.version=13;m.layers[0].shape={kind:'Path',red:1,green:0,blue:0,cornerRadius:0,vector};m.layers[0].transform.size=[640,480];return m;});
  try{
    instance=await _electron.launch({executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});const page=await instance.firstWindow(),errors=[];page.on('pageerror',error=>errors.push(error.message));
    const command=async name=>instance.evaluate(({BrowserWindow},name)=>BrowserWindow.getAllWindows()[0].webContents.send('editor:'+name),name);
    const save=async name=>{const destination=path.join(temp,name+'.comp');await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},destination);await command('saveAs');await expect(page.locator('.badge')).toContainText('Saved');await expect(page.getByTestId('save-project')).toBeEnabled();return JSON.parse(await readFile(path.join(destination,'manifest.json'),'utf8'));};
    await page.getByTestId('language').selectOption('en');await instance.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});},source);
    await page.getByTestId('open-project').click();await expect(page.getByTestId('save-project')).toBeEnabled();await page.locator('.layer-select').filter({hasText:'Mint / 薄荷'}).click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();
    await command('text');let dialog=page.getByRole('dialog');await page.getByTestId('text-content').fill('Vector O');await dialog.getByLabel('Font size',{exact:true}).fill('24');await dialog.getByLabel('Width',{exact:true}).fill('320');await dialog.getByLabel('Height',{exact:true}).fill('160');
    await dialog.getByLabel('Vertical text',{exact:true}).check();await dialog.getByLabel('Alignment',{exact:true}).selectOption('Justified');await page.getByTestId('update-preview').click();await expect(page.locator('.editor-preview img')).toBeVisible();await page.getByTestId('apply-editor').click();await expect(dialog).toHaveCount(0);await expect(page.getByTestId('layer-opacity')).toBeEnabled();
    let manifest=await save('vertical');expect(manifest.layers.at(-1).text.vertical).toBe(true);expect(manifest.layers.at(-1).text.alignment).toBe('Justified');
    await command('text');await expect(dialog.getByLabel('Vertical text',{exact:true})).toBeChecked();await dialog.getByLabel('Vertical text',{exact:true}).uncheck();await page.getByTestId('text-layout').selectOption('arc');await dialog.getByLabel('Bend',{exact:true}).fill('.15');await page.getByTestId('update-preview').click();await expect(page.getByTestId('apply-editor')).toBeEnabled();await expect(page.locator('.editor-preview img')).toBeVisible();await page.getByTestId('apply-editor').click();await expect(dialog).toHaveCount(0);await expect(page.getByTestId('layer-opacity')).toBeEnabled();
    manifest=await save('arc');expect(manifest.layers.at(-1).text.warp.bend).toBe(.15);expect(manifest.layers.at(-1).text.fontRuns).toBeUndefined();
    await command('text');await expect(page.getByTestId('text-layout')).toHaveValue('arc');await page.getByTestId('text-layout').selectOption('path');await page.getByTestId('text-path').selectOption(IDS[0]);expect(errors).toEqual([]);await expect(dialog.getByLabel('Width',{exact:true})).toHaveValue('640');await expect(dialog.getByLabel('Height',{exact:true})).toHaveValue('480');await page.getByTestId('update-preview').click();await expect(page.getByTestId('apply-editor')).toBeEnabled();await expect(page.locator('.editor-preview img')).toBeVisible();await page.getByTestId('apply-editor').click();await expect(dialog).toHaveCount(0);await expect(page.getByTestId('layer-opacity')).toBeEnabled();
    manifest=await save('path');const text=manifest.layers.at(-1);expect(text.text.pathLayout.path.contours[0].anchors).toHaveLength(2);expect(text.text.warp).toBeUndefined();expect(text.transform.origin).toEqual([0,0]);expect(text.transform.size).toEqual([640,480]);
    await instance.evaluate(({Menu})=>Menu.getApplicationMenu().getMenuItemById('layer-textOutlines').click());await expect(page.getByTestId('layer-opacity')).toBeEnabled();manifest=await save('outlines');expect(manifest.layers.at(-1).text).toBeUndefined();expect(manifest.layers.at(-1).shape.vector.contours.length).toBeGreaterThan(8);
    await page.getByTestId('undo').click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();await command('text');await expect(page.getByTestId('text-layout')).toHaveValue('path');await page.keyboard.press('Escape');expect(errors).toEqual([]);
  }finally{await instance?.close();await rm(temp,{recursive:true,force:true});}
});
