import{test,expect,_electron}from'@playwright/test';
import{mkdtemp,readFile,rm,mkdir,writeFile}from'node:fs/promises';
import path from'node:path';import os from'node:os';
import{fileURLToPath}from'node:url';
import{fixture}from'../fixtures.mjs';
import{smokeExecutable,smokeArgs,smokeEnv}from'./electron-launch.mjs';
const output=fileURLToPath(new URL('../../test-results/',import.meta.url));
async function report(info,name,data){await mkdir(output,{recursive:true});await writeFile(path.join(output,name+'-performance.json'),JSON.stringify({platform:process.platform,...data},null,2)+'\n');await info.attach(name+'-performance.json',{body:JSON.stringify(data,null,2),contentType:'application/json'});}

test('a full-HD selection does not stall pointer gestures or change the document when canceled',async({},info)=>{
 test.setTimeout(180000);const temp=await mkdtemp(path.join(os.tmpdir(),'comp-pointer-performance-')),source=path.join(temp,'large.comp');let app;
 try{
  await fixture(source,m=>({...m,width:1920,height:1080,layers:m.layers.map(row=>({...row,transform:{...row.transform,size:[1920,1080]}}))}));const original=await readFile(path.join(source,'manifest.json'));const start=performance.now();
  app=await _electron.launch({timeout:30000,executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});const page=await app.firstWindow();const errors=[];page.on('pageerror',e=>errors.push(e.message));await app.evaluate(({dialog,BrowserWindow},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});BrowserWindow.getAllWindows()[0].setContentSize(1280,800);},source);
  await expect(page.getByTestId('open-project')).toBeEnabled();await page.getByTestId('language').selectOption('en');await page.getByTestId('open-project').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await expect(page.getByTestId('save-project')).toBeEnabled();const startupMS=performance.now()-start;
  await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].webContents.send('editor:selectAll'));await expect.poll(()=>page.locator('.paint-overlay').evaluate(c=>c.getContext('2d').getImageData(0,0,1,1).data[3])).toBeGreaterThan(0);await expect(page.getByTestId('save-project')).toBeEnabled();await page.getByRole('button',{name:'Marquee',exact:true}).click();
  const selectionPixels=()=>page.locator('.paint-overlay').evaluate(c=>{const context=c.getContext('2d');return [[0,0],[100,100],[1919,1079]].map(([x,y])=>Array.from(context.getImageData(x,y,1,1).data));});const originalSelection=await selectionPixels();
  await page.evaluate(()=>{window.pointerTimes={pointerdown:[],pointermove:[]};for(const type of Object.keys(window.pointerTimes)){let started;document.addEventListener(type,event=>{started=document.querySelector('.artboard')?.contains(event.target)||event.target===document.querySelector('.stage')?performance.now():undefined;},true);window.addEventListener(type,()=>{if(started!==undefined)window.pointerTimes[type].push(performance.now()-started);});}});
  const box=await page.locator('.artboard').boundingBox();await page.mouse.move(box.x+box.width*.2,box.y+box.height*.2);await page.mouse.down();await page.mouse.move(box.x+box.width*.7,box.y+box.height*.7,{steps:16});await page.keyboard.press('Escape');await page.mouse.up();
  const metrics=await page.evaluate(()=>({pointer:window.pointerTimes}));const sorted=metrics.pointer.pointermove.slice(1).sort((a,b)=>a-b);const result={canvas:[1920,1080],startupMS,pointerDownMS:metrics.pointer.pointerdown,pointerMoveP95MS:sorted[Math.ceil(sorted.length*.95)-1]??0,pointerMoveMaxMS:Math.max(...sorted)};console.log('POINTER_PERFORMANCE '+JSON.stringify(result));await report(info,'pointer',result);
  expect(await selectionPixels()).toEqual(originalSelection);await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].webContents.send('editor:deselect'));await expect.poll(()=>page.locator('.paint-overlay').evaluate(c=>c.getContext('2d').getImageData(100,100,1,1).data[3])).toBe(0);
  expect(metrics.pointer.pointerdown.length).toBeGreaterThan(0);expect(Math.max(...result.pointerDownMS)).toBeLessThan(350);expect(result.pointerMoveP95MS).toBeLessThan(120);await expect(page.locator('[role=alert]')).toHaveCount(0);expect(errors).toEqual([]);expect(await readFile(path.join(source,'manifest.json'))).toEqual(original);
 }finally{await app?.close();await rm(temp,{recursive:true,force:true});}
});

test('repeated open and close releases preview workers and records process memory without retaining project edits',async({},info)=>{
 test.setTimeout(180000);const temp=await mkdtemp(path.join(os.tmpdir(),'comp-resource-performance-')),source=path.join(temp,'cycles.comp');let app;
 try{
  await fixture(source,m=>({...m,width:1280,height:720,layers:m.layers.map(row=>({...row,transform:{...row.transform,size:[1280,720]}}))}));const original=await readFile(path.join(source,'manifest.json'));
  app=await _electron.launch({timeout:30000,executablePath:smokeExecutable(),args:smokeArgs(),env:smokeEnv(temp)});const page=await app.firstWindow();const errors=[];page.on('pageerror',e=>errors.push(e.message));await app.evaluate(({dialog},source)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[source]});dialog.showMessageBox=async()=>({response:1});},source);await expect(page.getByTestId('open-project')).toBeEnabled();await page.getByTestId('language').selectOption('en');const samples=[];
  for(let cycle=0;cycle<3;cycle++){
   const started=performance.now();await page.getByTestId('open-project').click();await expect(page.getByTestId('rendered-canvas')).toBeVisible();await expect(page.getByTestId('save-project')).toBeEnabled();await expect.poll(()=>page.workers().length).toBe(1);
   await app.evaluate(({BrowserWindow})=>BrowserWindow.getAllWindows()[0].webContents.send('editor:selectAll'));await expect.poll(()=>page.locator('.paint-overlay').evaluate(c=>c.getContext('2d').getImageData(10,10,1,1).data[3])).toBeGreaterThan(0);
   const workingSetKiB=await app.evaluate(({app})=>app.getAppMetrics().reduce((sum,p)=>sum+p.memory.workingSetSize,0));samples.push({cycle:cycle+1,openMS:performance.now()-started,workingSetMiB:workingSetKiB/1024,workersOpen:page.workers().length});
   await page.getByTestId('close-project').click();await expect(page.getByTestId('rendered-canvas')).toHaveCount(0);await expect.poll(()=>page.workers().length).toBe(0);samples.at(-1).workersClosed=page.workers().length;await expect(page.getByTestId('open-project')).toBeEnabled();
  }
  const result={canvas:[1280,720],cycles:samples,peakSampledWorkingSetMiB:Math.max(...samples.map(p=>p.workingSetMiB))};console.log('RESOURCE_PERFORMANCE '+JSON.stringify(result));await report(info,'resources',result);expect(errors).toEqual([]);expect(await readFile(path.join(source,'manifest.json'))).toEqual(original);
 }finally{await app?.close();await rm(temp,{recursive:true,force:true});}
});
