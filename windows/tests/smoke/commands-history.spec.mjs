import{test,expect,_electron}from'@playwright/test';
import{mkdtemp,readFile,rm}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{PNG}from'pngjs';
import{fixture,IDS}from'../fixtures.mjs';
import{smokeExecutable,smokeArgs,smokeEnv}from'./electron-launch.mjs';

test('bilingual command search, repeated filters and history jumping preserve undo branches and source files',async()=>{
  test.setTimeout(120000);const temp=await mkdtemp(path.join(os.tmpdir(),'comp-command-ui-')),source=path.join(temp,'source.comp');await fixture(source);const original=await readFile(path.join(source,'manifest.json'));let instance;const errors=[];
  try{
    instance=await _electron.launch({executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});const page=await instance.firstWindow();page.on('pageerror',error=>errors.push(error.message));
    const command=async name=>instance.evaluate(({BrowserWindow},name)=>BrowserWindow.getAllWindows()[0].webContents.send('editor:'+name),name);
    const finder=async query=>{await page.keyboard.press('Control+Shift+P');await expect(page.getByTestId('command-search')).toBeVisible();await page.getByTestId('command-search').fill(query);};
    const ready=async()=>{await expect(page.getByTestId('layer-opacity')).toBeEnabled();await expect(page.locator('[role=alert]')).toHaveCount(0);};
    const save=async name=>{const destination=path.join(temp,name+'.comp');await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},destination);await command('saveAs');await expect(page.locator('.badge')).toContainText('Saved');await ready();return destination;};
    await page.getByTestId('language').selectOption('en');await instance.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});},source);
    await page.getByTestId('open-project').click();await expect(page.getByTestId('save-project')).toBeEnabled();await page.locator('.layer-select').filter({hasText:'Coral / 珊瑚'}).click();await ready();
    await finder('编辑填充');await expect(page.locator('[data-command=editFill]')).toBeDisabled();await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByTestId('undo')).toBeDisabled();
    await finder('滤镜图库');await page.keyboard.press('Enter');await expect(page.getByTestId('filter-kind')).toBeVisible();await page.getByTestId('filter-kind').selectOption('Invert');await page.getByTestId('apply-editor').click();await ready();
    await command('filter');await page.getByTestId('filter-kind').selectOption('Gaussian Blur');await page.keyboard.press('Escape');await page.locator('.layer-select').filter({hasText:'Mint / 薄荷'}).click();await ready();
    await finder('Repeat last');await expect(page.locator('[data-command=repeatFilter]')).toBeEnabled();await page.keyboard.press('Enter');await ready();
    const inverted=await save('inverted');expect([...PNG.sync.read(await readFile(path.join(inverted,'images',IDS[0]+'.png'))).data.subarray(0,4)]).toEqual([15,95,111,255]);expect([...PNG.sync.read(await readFile(path.join(inverted,'images',IDS[1]+'.png'))).data.subarray(0,4)]).toEqual([135,35,75,255]);
    await finder('历史');await page.keyboard.press('ArrowDown');await page.keyboard.press('Home');await page.keyboard.press('Enter');const history=page.getByRole('dialog',{name:'History',exact:true});await expect(history).toBeVisible();await expect(history.locator('[data-history-index]')).toHaveCount(3);await history.locator('[data-history-index="0"]').click();await ready();await expect(page.getByTestId('undo')).toBeDisabled();await expect(page.getByTestId('redo')).toBeEnabled();
    const restored=await save('restored');expect([...PNG.sync.read(await readFile(path.join(restored,'images',IDS[0]+'.png'))).data.subarray(0,4)]).toEqual([240,160,144,255]);
    await command('historyPanel');await history.locator('[data-history-index="2"]').click();await ready();await expect(page.getByTestId('redo')).toBeDisabled();
    await finder('zzzz-no-match');await expect(page.getByText('No matching commands',{exact:true})).toBeVisible();await page.keyboard.press('Escape');
    expect(await readFile(path.join(source,'manifest.json'))).toEqual(original);expect(errors).toEqual([]);
  }finally{await instance?.close();await rm(temp,{recursive:true,force:true});}
});
