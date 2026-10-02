import {test,expect,_electron} from '@playwright/test';
import {mkdtemp,rm,writeFile,readFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {PNG} from 'pngjs';
import {fixture,IDS} from '../fixtures.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
let temp,project,instance,page,before;
test.beforeEach(async()=>{
  temp=await mkdtemp(path.join(os.tmpdir(),'comp-workspace-'));project=path.join(temp,'workspace.comp');
  await fixture(project,m=>{m.width=640;m.height=420;m.layers[0].name='背景 / Background';m.layers[1].name='色彩 / Color';for(const l of m.layers)l.transform.size=[640,420];return m;});
  // Public synthetic artwork, without photographs, fonts or private project data.
  const base=new PNG({width:640,height:420}),paint=new PNG({width:640,height:420});
  for(let y=0;y<420;y++)for(let x=0;x<640;x++){
    const i=(y*640+x)*4;
    base.data.set([228-Math.round(y/15),226-Math.round(x/30),214+Math.round(y/25),255],i);
    const wave=245+Math.sin(x/115)*45,ball=Math.hypot(x-420,y-155)<88;
    paint.data.set(ball?[218,145,119,255]:y>wave?[110+Math.round(x/15),171,154,255]:[180,187,212,255],i);
  }
  await writeFile(path.join(project,'images',IDS[0]+'.png'),PNG.sync.write(base));await writeFile(path.join(project,'images',IDS[1]+'.png'),PNG.sync.write(paint));
  before=await readFile(path.join(project,'manifest.json'));
  instance=await _electron.launch({timeout:30000,executablePath:path.join(root,'release/win-unpacked/Compositor.exe'),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader'],env:{...process.env,APPDATA:temp}});
  page=await instance.firstWindow();
  await instance.evaluate(({dialog,BrowserWindow},p)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[p]});BrowserWindow.getAllWindows()[0].setContentSize(1280,800);},project);
  await page.getByTestId('language').selectOption('zh-Hans');await expect(page.getByTestId('language')).toHaveValue('zh-Hans');
  await page.getByTestId('open-project').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();
  await page.locator('.layer-select').filter({hasText:'色彩 / Color'}).click();await expect(page.getByTestId('layer-opacity')).toBeEnabled();
});
test.afterEach(async()=>{await instance?.close();await rm(temp,{recursive:true,force:true});});
test('workspace separates tool settings, layers and inspectors at two window sizes',async()=>{
  await page.getByRole('button',{name:'移动',exact:true}).click();await expect(page.getByTestId('tool-options')).toContainText('宽度');
  await page.getByRole('button',{name:'画笔',exact:true}).click();await expect(page.getByTestId('brush-size')).toBeVisible();
  await expect(page.locator('.layer-select .thumbnail img').first()).toBeVisible();await expect(page.locator('.raw-properties')).toHaveCount(0);
  await page.getByRole('tab',{name:'效果',exact:true}).click();await expect(page.getByLabel('添加效果',{exact:true})).toBeVisible();
  await page.getByRole('tab',{name:'属性',exact:true}).click();await expect(page.getByTestId('layer-name')).toBeVisible();
  await page.getByRole('button',{name:'移动',exact:true}).click();
  await page.screenshot({path:path.join(root,'test-results/workspace-preview.png')});
  await instance.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].setContentSize(880,540));
  await expect.poll(()=>page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await expect(page.getByTestId('layer-name')).toBeVisible();await expect(page.getByTestId('save-project')).toBeVisible();
  await page.screenshot({path:path.join(root,'test-results/compact-preview.png')});
  expect(await readFile(path.join(project,'manifest.json'))).toEqual(before);
});
test('inspector tabs support keyboard navigation and details contain the report',async()=>{
  const properties=page.getByRole('tab',{name:'属性',exact:true});await properties.focus();await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab',{name:'调整',exact:true})).toHaveAttribute('aria-selected','true');await page.keyboard.press('End');
  await expect(page.getByRole('tab',{name:'效果',exact:true})).toBeFocused();
  const details=page.getByTestId('project-details');await details.click();const dialog=page.getByRole('dialog',{name:'项目详情',exact:true});await expect(dialog).toBeVisible();
  await expect(page.getByTestId('copy-report')).toBeEnabled();await page.locator('.raw-properties summary').click();await expect(page.locator('.raw-properties pre')).toContainText('色彩 / Color');
  await page.keyboard.press('Escape');await expect(dialog).toHaveCount(0);await expect(details).toBeFocused();
  expect(await readFile(path.join(project,'manifest.json'))).toEqual(before);
});
