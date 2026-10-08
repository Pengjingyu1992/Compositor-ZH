import {test,expect,_electron} from '@playwright/test';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {PNG} from 'pngjs';
const root=fileURLToPath(new URL('../../',import.meta.url));let instance,page,temp;
test.beforeEach(async()=>{
 temp=await mkdtemp(path.join(os.tmpdir(),'comp-full-editor-'));
 instance=await _electron.launch({timeout:30000,executablePath:path.join(root,'release/win-unpacked/Compositor.exe'),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader'],env:{...process.env,APPDATA:temp}});page=await instance.firstWindow();await instance.evaluate(({dialog})=>{dialog.showMessageBox=async()=>({response:1});});
 page.on('pageerror',error=>console.error('Full editor:',error.message));
 await page.getByTestId('language').selectOption('zh-Hans');await page.getByTestId('new-canvas').click();const dialog=page.getByRole('dialog');await dialog.locator('.new-dimensions input').nth(0).fill('320');await dialog.locator('.new-dimensions input').nth(1).fill('240');await dialog.getByRole('button',{name:'创建',exact:true}).click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await page.getByTestId('add-pixels').click();await ready();
});
test.afterEach(async()=>{await instance?.close();await rm(temp,{recursive:true,force:true});});
async function ready(){await expect(page.getByTestId('layer-opacity')).toBeEnabled();await expect(page.locator('[role=alert]')).toHaveCount(0);}
async function command(name){await instance.evaluate(({BrowserWindow},name)=>BrowserWindow.getAllWindows()[0].webContents.send('editor:'+name),name);}
async function draw(tool,from=[.2,.2],to=[.65,.6],alt=false){await page.locator('.toolrail').getByRole('button',{name:tool,exact:true}).click();const b=await page.locator('.artboard').boundingBox();if(alt)await page.keyboard.down('Alt');await page.mouse.move(b.x+b.width*from[0],b.y+b.height*from[1]);await page.mouse.down();await page.mouse.move(b.x+b.width*to[0],b.y+b.height*to[1],{steps:8});await page.mouse.up();if(alt)await page.keyboard.up('Alt');await ready();}
async function save(name='saved.comp'){const file=path.join(temp,name);await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},file);await page.getByTestId('save-project').click();await expect(page.locator('.badge')).toContainText('已保存');return file;}
test('all 17 tools and native selection/image/filter menus are reachable',async()=>{
 const labels=['移动','选框','套索','魔棒','裁剪','画笔','橡皮擦','污点修复','仿制图章','涂抹','渐变','油漆桶','形状','文字','取色','抓手','缩放'];for(const label of labels){const button=page.getByRole('button',{name:label,exact:true});await button.click();await expect(button).toHaveAttribute('aria-pressed','true');}
 const menus=await instance.evaluate(({Menu})=>Menu.getApplicationMenu().items.map(i=>i.label));expect(menus).toEqual(['文件','编辑','显示','选择','图像','图层','滤镜','帮助']);await page.screenshot({path:path.join(root,'test-results/full-tools-preview.png')});
});
test('selection fill/clear undo and bucket keep the selected region',async()=>{
 await draw('选框');await command('fill');await ready();const alpha=await page.getByTestId('rendered-canvas').evaluate(c=>{const d=c.getContext('2d');return [d.getImageData(1,1,1,1).data[3],d.getImageData(100,80,1,1).data[3]];});expect(alpha).toEqual([0,255]);
 await command('clear');await ready();await page.getByTestId('undo').click();await ready();await command('deselect');await ready();await draw('油漆桶',[.05,.05],[.05,.05]);const file=await save();expect(JSON.parse(await readFile(path.join(file,'manifest.json'))).layers).toHaveLength(1);
});
test('crop cancel/apply and canvas/image resizing persist dimensions',async()=>{
 await draw('裁剪');await page.keyboard.press('Escape');await expect(page.getByTestId('apply-crop')).toBeDisabled();await draw('裁剪',[.1,.1],[.8,.8]);await page.getByTestId('apply-crop').click();await ready();
 await command('canvasSize');const d=page.getByRole('dialog');await d.locator('.new-dimensions input').nth(0).fill('200');await d.locator('.new-dimensions input').nth(1).fill('150');await page.getByTestId('apply-editor').click();await ready();await command('imageSize');await d.locator('.new-dimensions input').nth(0).fill('160');await d.locator('.new-dimensions input').nth(1).fill('120');await page.getByTestId('apply-editor').click();await ready();const file=await save();const m=JSON.parse(await readFile(path.join(file,'manifest.json')));expect([m.width,m.height]).toEqual([160,120]);
});
test('Chinese text and parametric shape remain editable after save and reopen',async()=>{
 await draw('形状');await command('text');await expect(page.getByTestId('text-content')).toBeVisible();await page.getByTestId('text-content').fill('叠绘 中文😀\nCompositor');await page.getByTestId('update-preview').click();await expect(page.getByTestId('apply-editor')).toBeEnabled();await page.getByTestId('apply-editor').click();await ready();const file=await save();let m=JSON.parse(await readFile(path.join(file,'manifest.json')));expect(m.layers.some(l=>l.shape?.kind==='Rectangle')).toBe(true);expect(m.layers.some(l=>l.text?.content.includes('中文😀'))).toBe(true);
 await instance.evaluate(({dialog},file)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[file]});},file);await page.getByTestId('open-project').click();await expect(page.locator('.layer-row')).toHaveCount(3);await page.locator('.layer-select').filter({hasText:'叠绘 中文😀'}).click();await command('text');await expect(page.getByTestId('text-content')).toHaveValue(/中文😀/);await page.keyboard.press('Escape');
 await page.screenshot({path:path.join(root,'test-results/text-shape-preview.png')});
});
test('gradient, symmetric painting, clone, healing, smear and filter cancel/apply',async()=>{
 await draw('渐变');await page.getByRole('button',{name:'画笔',exact:true}).click();await page.getByRole('combobox',{name:'对称',exact:true}).selectOption('both');await draw('画笔');await page.getByRole('button',{name:'仿制图章',exact:true}).click();const b=await page.locator('.artboard').boundingBox();await page.keyboard.down('Alt');await page.mouse.click(b.x+b.width*.3,b.y+b.height*.3);await page.keyboard.up('Alt');await draw('仿制图章',[.5,.5],[.7,.6]);for(const tool of ['污点修复','涂抹','橡皮擦'])await draw(tool,[.3,.3],[.4,.4]);
 await command('filter');await page.getByTestId('filter-kind').selectOption('Mosaic');await page.getByTestId('update-preview').click();await expect(page.getByTestId('apply-editor')).toBeEnabled();await page.keyboard.press('Escape');await ready();await command('filter');await page.getByTestId('filter-kind').selectOption('Mosaic');await page.getByTestId('apply-editor').click();await ready();await page.getByTestId('undo').click();await ready();await save();
});
test('multiple layers arrange/group/duplicate/ungroup and clipboard paste',async()=>{
 await draw('形状',[.1,.1],[.3,.3]);await draw('形状',[.5,.5],[.8,.8]);const rows=page.locator('.layer-select');await rows.nth(1).click();await rows.nth(2).click({modifiers:['Control']});await page.getByRole('button',{name:'右对齐',exact:true}).last().click();await ready();await command('group');await ready();await command('duplicate');await ready();await command('ungroup');await ready();await expect(page.locator('.layer-row')).toHaveCount(6);
 await rows.last().click();await command('copy');await command('paste');await ready();await expect(page.locator('.layer-row')).toHaveCount(7);await save();
});
test('lasso and wand create a feathered mask; content lock blocks menu edits',async()=>{
 await page.getByRole('button',{name:'套索',exact:true}).click();const b=await page.locator('.artboard').boundingBox();const point=(x,y)=>[b.x+b.width*x,b.y+b.height*y];await page.mouse.move(...point(.15,.15));await page.mouse.down();await page.mouse.move(...point(.85,.15),{steps:6});await page.mouse.move(...point(.5,.85),{steps:6});await page.mouse.up();await ready();await command('fill');await ready();
 const alpha=await page.getByTestId('rendered-canvas').evaluate(c=>[...c.getContext('2d').getImageData(160,100,1,1).data]);expect(alpha[3]).toBe(255);await command('deselect');await ready();await draw('魔棒',[.5,.4],[.5,.4]);await command('featherSelection');await ready();await command('selectionMask');await ready();const file=await save();const m=JSON.parse(await readFile(path.join(file,'manifest.json'))),mask=PNG.sync.read(await readFile(path.join(file,'images',m.layers[0].maskFile)));expect([mask.width,mask.height]).toEqual([320,240]);expect(mask.data[0]).toBe(0);expect(mask.data[(100*320+160)*4]).toBe(255);
 await page.getByText('锁定仅在本次打开中有效',{exact:true}).click();await page.getByLabel('锁定内容',{exact:true}).check();await ready();await command('fill');await expect(page.locator('[role=alert]')).toContainText('图层已锁定');await page.locator('[role=alert]').getByRole('button',{name:'取消'}).click();await page.getByLabel('锁定内容',{exact:true}).uncheck();await ready();await save();const saved=JSON.parse(await readFile(path.join(file,'manifest.json')));expect(saved).not.toHaveProperty('locks');
});
