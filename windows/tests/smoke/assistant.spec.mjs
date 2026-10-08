import {test,expect,_electron} from '@playwright/test';
import {mkdtemp,rm,readFile,mkdir,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {fixture,IDS} from '../fixtures.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
let temp,project,instance,page,stub,received,answer,settingsDirectory,answerDelay,releaseAnswer;
// A loopback stub stands in for the model service. It keeps the whole path -
// settings, IPC, prompt assembly, parsing, checking, applying - under test
// without a network, a real key, or a vendor.
async function startStub(){
  received=[];
  return new Promise(resolve=>{
    const server=createServer(async(req,res)=>{
      let body='';for await(const chunk of req)body+=chunk;
      received.push({url:req.url,authorization:req.headers.authorization,body:JSON.parse(body)});
      if(answerDelay)await answerDelay;
      res.writeHead(200,{'content-type':'application/json'});
      res.end(JSON.stringify({choices:[{message:{content:JSON.stringify(answer)}}]}));
    });
    server.listen(0,'127.0.0.1',()=>resolve({server,port:server.address().port}));
  });
}
// APPDATA in the environment does not move Electron's user-data directory, so
// the settings are pointed at a temporary folder explicitly. Otherwise these
// checks would overwrite the real API key of the machine running them.
function cleanEnv(){
  const env={...process.env,APPDATA:temp,COMPOSITOR_AI_DIRECTORY:settingsDirectory};
  delete env.ELECTRON_RUN_AS_NODE;delete env.NODE_OPTIONS;
  return env;
}
test.beforeEach(async()=>{
  temp=await mkdtemp(path.join(os.tmpdir(),'comp-assistant-'));
  settingsDirectory=path.join(temp,'ai-settings');
  project=path.join(temp,'assistant.comp');
  await fixture(project,m=>{m.width=640;m.height=420;m.layers[0].name='背景 / Background';m.layers[1].name='色彩 / Color';return m;});
  answer={reply:'好的',ops:[]};
  answerDelay=undefined;releaseAnswer=undefined;
  const started=await startStub();stub=started.server;
  instance=await _electron.launch({timeout:30000,executablePath:path.join(root,'release/win-unpacked/Compositor.exe'),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader'],env:cleanEnv()});
  page=await instance.firstWindow();
  await instance.evaluate(({dialog,BrowserWindow},p)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[p]});BrowserWindow.getAllWindows()[0].setContentSize(1280,800);},project);
  await page.getByTestId('language').selectOption('zh-Hans');
  await page.getByTestId('open-project').click();
  await expect(page.getByTestId('rendered-canvas')).toBeVisible();
});
test.afterEach(async()=>{releaseAnswer?.();await instance?.close();if(stub)await new Promise(r=>stub.close(r));await rm(temp,{recursive:true,force:true});});

async function configure(){
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();
}
async function send(ops){
  answer={reply:'好的',ops};
  await page.getByTestId('ai-prompt').fill('执行这些编辑');
  await page.getByTestId('ai-send').click();
  await expect(page.getByTestId('ai-prompt')).toBeEnabled();
}
async function savedManifest(){
  const file=path.join(temp,'saved.comp');
  await instance.evaluate(({dialog},file)=>{dialog.showSaveDialog=async()=>({canceled:false,filePath:file});},file);
  await page.getByTestId('save-project').click();
  await expect(page.locator('.badge')).toContainText('已保存');
  return JSON.parse(await readFile(path.join(file,'manifest.json'),'utf8'));
}

test('test connection uses the unsaved settings without storing a key',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/draft`);
  await dialog.getByLabel('模型').fill('draft-model');
  await dialog.getByLabel('API 密钥').fill('draft-key');
  await dialog.getByTestId('ai-test').click();
  await expect(page.locator('.assistant-log')).toContainText('draft-model');
  expect(received).toHaveLength(1);
  expect(received[0].url).toBe('/draft/chat/completions');
  expect(received[0].authorization).toBe('Bearer draft-key');
  expect(received[0].body.model).toBe('draft-model');
  const stored=await page.evaluate(()=>window.ai.settings());
  expect(stored.endpoint).toBe('https://api.deepseek.com/v1');
  expect(stored.hasKey).toBe(false);
  await expect(readFile(path.join(settingsDirectory,'ai-settings.json'))).rejects.toThrow();
});

test('a delayed answer cannot resize the next project',async()=>{
  await configure();
  answer={reply:'好的',ops:[{kind:'canvas',width:12,height:12}]};
  answerDelay=new Promise(resolve=>{releaseAnswer=resolve;});
  await page.getByTestId('ai-prompt').fill('改变画布大小');
  await page.getByTestId('ai-send').click();
  await expect.poll(()=>received.length).toBe(1);
  await page.getByTestId('new-canvas').click();
  const dialog=page.getByRole('dialog');
  await dialog.locator('.new-dimensions input').nth(0).fill('300');
  await dialog.locator('.new-dimensions input').nth(1).fill('200');
  await dialog.getByRole('button',{name:'创建',exact:true}).click();
  await expect(page.getByTestId('ai-layer')).toHaveCount(0);
  releaseAnswer();
  await expect(page.locator('.assistant-log')).toContainText('项目已切换');
  const m=await savedManifest();
  expect([m.width,m.height]).toEqual([300,200]);
});

test('a single target stays single under multiselection and failures stay failures',async()=>{
  await configure();
  await page.locator('.layer-select').filter({hasText:'背景 / Background'}).click();
  await page.locator('.layer-select').filter({hasText:'色彩 / Color'}).click({modifiers:['Control']});
  await send([
    {kind:'transform',id:IDS[0],field:'origin',value:[10,20]},
    {kind:'lock',id:IDS[0],field:'content',value:true},
    {kind:'filter',id:IDS[0],filter:'Invert'},
    {kind:'filter',id:IDS[0],filter:'Invert'}
  ]);
  await expect(page.locator('.assistant-log .line-bad')).toHaveCount(2);
  await expect(page.locator('.assistant-log')).not.toContainText('本来就是此状态');
  const m=await savedManifest();
  expect(m.layers[0].transform.origin).toEqual([10,20]);
  expect(m.layers[1].transform.origin).toEqual([0,0]);
});

test('losing the GPU blocks assistant visual edits and retains the saved preview',async()=>{
  await configure();
  const preview=Buffer.from(await page.getByTestId('rendered-canvas').evaluate(c=>c.toDataURL('image/jpeg').split(',')[1]),'base64');
  await mkdir(path.join(project,'QuickLook'));
  await writeFile(path.join(project,'QuickLook/Preview.jpg'),preview);
  // Capture the engine's real WebGL surface when the fixture is reopened.
  await page.evaluate(()=>{
    const original=HTMLCanvasElement.prototype.getContext;
    window.testGl=[];
    HTMLCanvasElement.prototype.getContext=function(type,...args){
      const value=original.call(this,type,...args);
      if(type==='webgl2'&&value&&!window.testGl.includes(value))window.testGl.push(value);
      return value;
    };
  });
  await page.getByTestId('open-project').click();
  await expect(page.getByTestId('rendered-canvas')).toBeVisible();
  await page.evaluate(()=>{
    if(!window.testGl.length)throw new Error('No engine WebGL context');
    for(const gl of window.testGl)gl.getExtension('WEBGL_lose_context')?.loseContext();
  });
  await expect(page.getByTestId('rendered-canvas')).toBeHidden();
  await expect(page.getByTestId('saved-preview')).toBeVisible();
  await send([{kind:'appearance',id:IDS[0],field:'opacity',value:.1}]);
  await expect(page.locator('.assistant-log .line-bad')).toContainText('编辑器拒绝了');
  await expect(page.locator('.badge')).toContainText('已保存');
  await expect(page.getByTestId('saved-preview')).toBeVisible();
  expect(await readFile(path.join(project,'QuickLook/Preview.jpg'))).toEqual(preview);
  const m=await savedManifest();
  expect(m.layers[0].opacity??1).toBe(1);
});

test('restyling text keeps its placement, font, and box',async()=>{
  await configure();
  await send([{kind:'styled',type:'text',origin:[20,30],style:{content:'标题',fontName:'ArialMT',fontSize:90,boxSize:[400,150],alignment:'Right',tracking:2,leading:110}}]);
  const original=(await savedManifest()).layers.at(-1);
  await send([{kind:'styled',type:'text',id:original.id,style:{content:'标题 AB'}}]);
  const changed=(await savedManifest()).layers.at(-1);
  expect(changed.transform).toEqual(original.transform);
  for(const field of ['fontName','fontSize','boxSize','alignment','tracking','leading'])expect(changed.text[field]).toEqual(original.text[field]);
  expect(changed.text.content).toBe('标题 AB');
});

test('the panel docks without covering the canvas and folds back to a title bar',async()=>{
  const prompt=page.getByTestId('ai-prompt');
  await expect(prompt).toBeVisible();
  // Hidden layers are struck through and every layer is offered.
  await expect(page.getByTestId('ai-layer')).toHaveCount(2);
  await expect(page.getByTestId('ai-layer').filter({hasText:'背景 / Background'})).toBeVisible();

  const docked=async()=>page.evaluate(()=>{
    const panel=document.querySelector('.assistant').getBoundingClientRect();
    const stage=document.querySelector('.stage').getBoundingClientRect();
    return {panelTop:panel.top,panelHeight:panel.height,stageBottom:stage.bottom,inner:window.innerHeight};
  });
  const open=await docked();
  // The canvas ends before the panel starts: an overlay would overlap here.
  expect(open.stageBottom).toBeLessThanOrEqual(open.panelTop+1);
  expect(open.panelHeight).toBeGreaterThan(100);

  await page.getByTestId('ai-fold').click();
  await expect(prompt).toBeHidden();
  const folded=await docked();
  expect(folded.panelHeight).toBeLessThan(50);
  expect(folded.stageBottom).toBeGreaterThan(open.stageBottom);
  expect(folded.stageBottom).toBeLessThanOrEqual(folded.panelTop+1);

  await page.getByTestId('ai-fold').click();
  await expect(prompt).toBeVisible();
});

test('settings stay on this machine and the key is never returned to the page',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await expect(dialog).toBeVisible();
  await expect(dialog.getByLabel('接口地址')).toHaveValue('https://api.deepseek.com/v1');

  // A remote plain-http endpoint is refused: the key would be readable in transit.
  await dialog.getByLabel('接口地址').fill('http://example.com/v1');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog.getByRole('status')).toBeVisible();
  await expect(dialog).toBeVisible();

  const started=stub.address().port;
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${started}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();
  await expect(page.locator('.assistant-head')).toContainText('已配置密钥');

  const stored=await page.evaluate(()=>window.ai.settings());
  expect(stored.endpoint).toBe(`http://127.0.0.1:${started}/v1`);
  expect(stored.model).toBe('stub-model');
  // A key is only kept when the platform can encrypt it, and it is never
  // handed back to the page either way.
  expect(stored.hasKey).toBe(stored.encryption);
  expect(JSON.stringify(stored)).not.toContain('test-key');
  // On disk the key is ciphertext rather than the value that was typed.
  const file=await readFile(path.join(settingsDirectory,'ai-settings.json'),'utf8');
  expect(file).not.toContain('test-key');
  if(stored.encryption)expect(JSON.parse(file).key.length).toBeGreaterThan(0);
});

test('a request reaches the model and the operations it returns change the project',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();

  answer={reply:'已隐藏背景',ops:[
    {kind:'appearance',id:IDS[1],field:'isVisible',value:false},
    {kind:'rename',id:IDS[0],name:'已重命名'}
  ]};
  await page.getByTestId('ai-prompt').fill('隐藏色彩层并把背景改名');
  await page.getByTestId('ai-send').click();

  await expect(page.locator('.assistant-log')).toContainText('已隐藏背景');
  await expect(page.locator('.assistant-log')).toContainText('已应用');
  // Both operations really ran: the layer list reflects them, and only the
  // layer the model hid carries the struck-through marker.
  await expect(page.getByTestId('ai-layer').filter({hasText:'已重命名'})).toBeVisible();
  await expect(page.locator('.assistant-chip.off')).toHaveCount(1);
  const marked=await page.evaluate(()=>document.querySelector('.assistant-chip.off')?.textContent?.trim());
  expect(marked).toBe('色彩 / Color');

  // The prompt carried the exact enumerations and the real layer ids.
  expect(received).toHaveLength(1);
  expect(received[0].url).toBe('/v1/chat/completions');
  expect(received[0].authorization).toBe('Bearer test-key');
  expect(received[0].body.model).toBe('stub-model');
  expect(received[0].body.temperature).toBe(0);
  const system=received[0].body.messages[0].content;
  for(const id of [IDS[0],IDS[1]])expect(system).toContain(id);
  // IDS[2] is the document id in the fixture, not a layer, so the prompt must
  // not offer it as one.
  expect(system).not.toContain(IDS[2]);
  expect(system).toContain('Content-Aware Fill');
  expect(system).toContain('Linear Dodge (Add)');
  expect(received[0].body.messages[1].content).toBe('隐藏色彩层并把背景改名');

  // Undo is the editor's own, so it takes both operations back.
  await page.getByTestId('ai-undo').click();
  await page.getByTestId('ai-undo').click();
  await expect(page.getByTestId('ai-layer').filter({hasText:'背景 / Background'})).toBeVisible();
  await expect(page.locator('.assistant-chip.off')).toHaveCount(0);
});

test('an operation the editor would reject is reported instead of run',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();

  answer={reply:'好的',ops:[
    {kind:'appearance',id:'00000000-0000-4000-8000-0000000000ff',field:'isVisible',value:false},
    {kind:'appearance',id:IDS[0],field:'blendMode',value:'multiply'},
    {kind:'open'}
  ]};
  await page.getByTestId('ai-prompt').fill('做点不该做的事');
  await page.getByTestId('ai-send').click();
  const log=page.locator('.assistant-log');
  await expect(log).toContainText('项目中找不到这个图层');
  await expect(log).toContainText('参数值无效');
  await expect(log).toContainText('不支持的操作类型');
  // Nothing was applied, so both layers are still visible.
  await expect(page.locator('.assistant-chip.off')).toHaveCount(0);
});

test('the assistant can add a text layer and a shape layer',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();

  // The model supplies parameters only; the panel renders them to an image and
  // the editor stores that image together with the parameters it came from.
  answer={reply:'加好了',ops:[
    {kind:'styled',type:'text',origin:[20,30],style:{content:'标题',fontSize:48,red:1,green:1,blue:1,alignment:'Center'}},
    {kind:'styled',type:'shape',origin:[120,140],style:{kind:'Ellipse',red:.9,green:.3,blue:.3,boxSize:[80,80]}}
  ]};
  await page.getByTestId('ai-prompt').fill('加一行标题和一个圆形');
  await page.getByTestId('ai-send').click();

  const log=page.locator('.assistant-log');
  await expect(log).toContainText('已应用');
  await expect(log).toContainText('styled text');
  await expect(log).toContainText('styled shape Ellipse');
  // Two layers were added on top of the fixture's two. Neither replaced the
  // selected layer, which is what happens if the operation carries no id.
  await expect(page.getByTestId('ai-layer')).toHaveCount(4);
  await expect(page.getByTestId('ai-layer').filter({hasText:'标题'})).toBeVisible();
  await expect(page.getByTestId('ai-layer').filter({hasText:'背景 / Background'})).toBeVisible();
  await expect(page.getByTestId('ai-layer').filter({hasText:'色彩 / Color'})).toBeVisible();
  await page.screenshot({path:path.join(root,'test-results/assistant-styled-preview.png')});

  // Undo takes both back, so they went through the editor's own history.
  await page.getByTestId('ai-undo').click();
  await page.getByTestId('ai-undo').click();
  await expect(page.getByTestId('ai-layer')).toHaveCount(2);
});

test('a set operation and a canvas operation reach the editor',async()=>{
  await page.getByTestId('ai-settings').click();
  const dialog=page.getByRole('dialog',{name:'AI 设置'});
  await dialog.getByLabel('接口地址').fill(`http://127.0.0.1:${stub.address().port}/v1`);
  await dialog.getByLabel('模型').fill('stub-model');
  await dialog.getByLabel('API 密钥').fill('test-key');
  await dialog.getByTestId('ai-save-settings').click();
  await expect(dialog).toBeHidden();

  // The ids are deliberately re-cased: the editor matches them exactly, so the
  // panel has to put them back to the spelling the project uses.
  answer={reply:'做好了',ops:[
    {kind:'group',ids:[IDS[0].toLowerCase(),IDS[1].toLowerCase()],name:'新组'},
    {kind:'flipCanvas',axis:'horizontal'}
  ]};
  await page.getByTestId('ai-prompt').fill('把这两层建个组然后水平翻转');
  await page.getByTestId('ai-send').click();

  const log=page.locator('.assistant-log');
  await expect(log).toContainText('group');
  await expect(log).toContainText('flipCanvas');
  // Neither is refused, which is what a stale id would have produced.
  await expect(log).not.toContainText('项目中找不到这个图层');
  await expect(log).not.toContainText('编辑器拒绝了');
  // The two fixture layers now sit inside a new group, so three rows are listed.
  await expect(page.getByTestId('ai-layer')).toHaveCount(3);
  await expect(page.getByTestId('ai-layer').filter({hasText:'新组'})).toBeVisible();

  await page.screenshot({path:path.join(root,'test-results/assistant-group-preview.png')});
  await page.getByTestId('ai-undo').click();
  await page.getByTestId('ai-undo').click();
  await expect(page.getByTestId('ai-layer')).toHaveCount(2);
});

test('without a key the panel says so and never reaches the network',async()=>{
  await page.getByTestId('ai-prompt').fill('隐藏背景');
  await page.getByTestId('ai-send').click();
  await expect(page.locator('.assistant-log')).toContainText('尚未设置 API 密钥');
  expect(received).toHaveLength(0);
});
