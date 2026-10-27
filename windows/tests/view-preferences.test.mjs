import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm,readFile,writeFile,symlink,mkdir}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{ViewPreferences}from'../packages/platform/view-preferences.mjs';
import{DEFAULT_VIEW_SETTINGS,validateViewSettings,hexToRGB,rgbToHex,rgbToHSV,hsvToRGB,rulerTicks}from'../packages/comp-bridge/view-settings.mjs';

test('view preferences persist only validated local view/color settings and serialize concurrent writes',async()=>{
  const directory=await mkdtemp(path.join(os.tmpdir(),'comp-view-settings-'));
  try{const store=new ViewPreferences(directory);assert.deepEqual(await store.read(),DEFAULT_VIEW_SETTINGS);
    const first={...structuredClone(DEFAULT_VIEW_SETTINGS),gridSpacing:32,gridSubdivisions:4,rulerUnit:'cm',foreground:'#123456',swatches:['#123456']},last={...first,rulers:true,navigator:true,palette:true,gridOpacity:48};
    await Promise.all([store.write(first),store.write(last)]);assert.deepEqual(await new ViewPreferences(directory).read(),last);
    const bytes=await readFile(path.join(directory,'workspace.json'),'utf8');assert.equal(bytes.includes(directory),false);assert.deepEqual(Object.keys(JSON.parse(bytes)),['schema','settings']);
    for(const patch of [{gridSpacing:0},{gridSubdivisions:1.5},{gridColor:'red'},{gridOpacity:NaN},{swatches:['file:///private']},{rulerUnit:'future'},{projectPath:'private'}])assert.throws(()=>store.write({...last,...patch}),error=>error.code==='invalid');
    assert.deepEqual(await store.read(),last);await writeFile(path.join(directory,'workspace.json'),'{bad');assert.deepEqual(await store.read(),DEFAULT_VIEW_SETTINGS);
    const outside=path.join(directory,'outside'),alias=path.join(directory,'alias');await mkdir(outside);await writeFile(path.join(outside,'workspace.json'),JSON.stringify({schema:1,settings:last}));await symlink(outside,alias,'junction');assert.deepEqual(await new ViewPreferences(alias).read(),DEFAULT_VIEW_SETTINGS);await assert.rejects(()=>new ViewPreferences(alias).write(first));
  }finally{await rm(directory,{recursive:true,force:true});}
});

test('RGB and HSV color entry round-trips primaries, grays, hue wrapping and arbitrary 8-bit colors',()=>{
  for(const rgb of [[255,0,0],[0,255,0],[0,0,255],[255,255,255],[0,0,0],[128,128,128],...Array.from({length:100},(_,i)=>[i*23%256,i*67%256,i*103%256])]){
    assert.deepEqual(hexToRGB(rgbToHex(rgb)),rgb);assert.deepEqual(hsvToRGB(rgbToHSV(rgb)),rgb);
  }
  assert.deepEqual(hsvToRGB([360,100,100]),[255,0,0]);assert.deepEqual(hsvToRGB([-120,100,100]),[0,0,255]);
});

test('ruler ticks remain sparse at extreme zoom and only enumerate the visible document span',()=>{
  for(const zoom of [.01,.1,1,8]){const ticks=rulerTicks(30000,zoom,10000,1000/zoom);assert.ok(ticks.length<100);assert.ok(ticks.every(tick=>tick.position>=0&&tick.position<=30000));const major=ticks.filter(tick=>tick.major);if(major.length>1)assert.ok((major[1].position-major[0].position)*zoom>=80);}
  assert.throws(()=>validateViewSettings({...DEFAULT_VIEW_SETTINGS,swatches:new Array(65).fill('#123456')}));
});
