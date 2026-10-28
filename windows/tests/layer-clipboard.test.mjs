import{test}from'node:test';
import assert from'node:assert/strict';
import{mkdtemp,rm}from'node:fs/promises';
import path from'node:path';
import os from'node:os';
import{captureLayers,pasteLayers}from'../packages/platform/layer-clipboard.mjs';
import{newProject,editProject,projectData}from'../packages/comp-bridge/edit.mjs';
import{readProject}from'../packages/comp-bridge/project.mjs';
import{defaultFilterNode,readFilterNodes}from'../packages/comp-bridge/editable-filters.mjs';
import{defaultFillStyle}from'../packages/comp-bridge/layer-styles.mjs';
import{shapeMask,maskBounds}from'../packages/comp-bridge/editor-math.mjs';
import{ProjectSession}from'../packages/platform/project-session.mjs';
import{saveProject,RecoveryStore}from'../packages/platform/save-project.mjs';
import*as codecs from'../packages/comp-bridge/codecs.mjs';
const edit=(data,op)=>editProject(data,op,codecs);
function source(){
  let data=edit(newProject(12,8),{kind:'add',type:'group',name:'Folder'}),group=data.manifest.activeLayerID;
  data=edit(data,{kind:'add',type:'pixels',name:'Noise',parentID:group});const pixels=data.manifest.activeLayerID;
  data=edit(data,{kind:'fill',id:pixels,settings:{color:[160,80,20]}});data=edit(data,{kind:'mask',id:pixels,action:'add'});data=edit(data,{kind:'filterStack',id:pixels,nodes:[defaultFilterNode('Add Noise')]});data=edit(data,{kind:'effect',id:pixels,effect:'shadow'});
  data=edit(data,{kind:'fillLayer',parentID:group,name:'Fill',style:defaultFillStyle()});
  const style={content:'中文😀',fontName:'ArialMT',fontSize:12,red:1,green:0,blue:0,alignment:'Left',tracking:0,leading:0,boxSize:[16,16],colorRuns:[],fontRuns:[]};
  data=edit(data,{kind:'styled',type:'text',parentID:group,style,png:codecs.blankPNG(12,8,false).bytes,origin:[3,4],name:'Text'});
  const manifest=structuredClone(data.manifest);for(const row of manifest.layers)if(row.parentID)row.parentID=row.parentID.toLowerCase();const resources=new Map(data.resources);resources.set('future/private.bin',{bytes:Buffer.from('unrelated'),mime:'application/octet-stream'});return{data:projectData(manifest,resources),group,pixels};
}
test('whole-layer clipboard retains groups, editable recipes, masks, effects and text through cross-project save and recovery',async t=>{
  const temp=await mkdtemp(path.join(os.tmpdir(),'comp-layer-clipboard-'));t.after(()=>rm(temp,{recursive:true,force:true}));
  const{data,group,pixels}=source(),bundle=captureLayers(data,[group,pixels]);assert.equal(bundle.layers.length,4);assert.equal(bundle.resources.has('future/private.bin'),false);
  const destination=newProject(24,16),result=pasteLayers(destination,bundle);assert.equal(result.manifest.layers.length,4);assert.equal(result.manifest.version,14);assert.deepEqual(result.analysis.issues,[]);
  const copyGroup=result.manifest.layers.find(row=>row.isGroup);assert.notEqual(copyGroup.id,group);assert.equal(copyGroup.name,'Folder (copy)');for(const child of result.manifest.layers.filter(row=>!row.isGroup))assert.equal(child.parentID,copyGroup.id);
  const copy=result.manifest.layers.find(row=>row.name==='Noise');assert.deepEqual(copy.effects,data.manifest.layers.find(row=>row.id===pixels).effects);assert.deepEqual(readFilterNodes(copy,result.resources),readFilterNodes(data.manifest.layers.find(row=>row.id===pixels),data.resources));
  for(const field of ['imageFile','maskFile'])assert.equal(result.resources.get('images/'+copy[field]),data.resources.get('images/'+data.manifest.layers.find(row=>row.id===pixels)[field]));
  assert.deepEqual(result.manifest.layers.find(row=>row.text).text,data.manifest.layers.find(row=>row.text).text);assert.equal(result.manifest.layers.find(row=>row.fill).fill.kind,'Solid Color');
  const file=path.join(temp,'pasted.comp');await saveProject(result,file);const reopened=await readProject(file);assert.deepEqual(reopened.manifest,result.manifest);assert.deepEqual(readFilterNodes(reopened.manifest.layers.find(row=>row.name==='Noise'),reopened.resources),readFilterNodes(copy,result.resources));
  const recovery=new RecoveryStore(path.join(temp,'recovery'));await recovery.write(result,crypto.randomUUID());assert.deepEqual((await recovery.restore((await recovery.list())[0].key)).manifest,result.manifest);assert.equal(data.manifest.layers.length,4);
});
test('paste is one revision-bound undo step, inserts inside the target folder and respects ancestor locks and retained budgets',()=>{
  const{data,group}=source(),bundle=captureLayers(data,[group]);let destination=edit(newProject(24,16),{kind:'add',type:'group',name:'Target'}),targetID=destination.manifest.activeLayerID;
  destination=edit(destination,{kind:'selection',action:'all'});const session=new ProjectSession(undefined,{codecs});session.install(destination,null,true);const old=session.current.data,revision=session.revision;
  assert.ok(session.pasteLayers(session.current.id,revision,bundle,{targetID}).project);assert.equal(session.undoStack.length,1);assert.equal(session.current.data.selection,null);assert.equal(session.current.data.manifest.layers[1].parentID,targetID);assert.equal(session.pasteLayers(session.current.id,revision,bundle).error,'stale');
  session.history(session.current.id,session.revision,'undo');assert.equal(session.current.data,old);assert.equal(session.isDirty(),false);session.history(session.current.id,session.revision,'redo');assert.equal(session.current.data.manifest.layers.length,5);
  const locked=edit(destination,{kind:'lock',id:targetID,field:'content',value:true});assert.throws(()=>pasteLayers(locked,bundle,{targetID}),error=>error.code==='locked');assert.throws(()=>pasteLayers(destination,bundle,{targetID:crypto.randomUUID()}),error=>error.code==='stale');
  const guarded=new ProjectSession(undefined,{codecs,validateRetained:(candidate,owner,replacing)=>{if(!replacing)throw Object.assign(new Error('limit'),{code:'limit'});}});guarded.install(destination);assert.equal(guarded.pasteLayers(guarded.current.id,guarded.revision,bundle,{targetID}).error,'limit');assert.equal(guarded.undoStack.length,0);assert.equal(guarded.current.data,destination);guarded.close();session.close();
});
test('clipped layers bring their mask source, remap links and keep immutable original PNG resources',()=>{
  let data=edit(newProject(4,3),{kind:'add',type:'pixels',name:'Base'}),base=data.manifest.activeLayerID;data=edit(data,{kind:'add',type:'pixels',name:'Clip'});const clip=data.manifest.activeLayerID;data=edit(data,{kind:'clip',id:clip,sourceID:base});
  const above=pasteLayers(data,captureLayers(data,[base]),{targetID:base});assert.deepEqual(above.manifest.layers.slice(0,2),data.manifest.layers);assert.deepEqual(above.analysis.issues,[]);
  const result=pasteLayers(newProject(4,3),captureLayers(data,[clip]));assert.equal(result.manifest.layers.length,2);assert.equal(result.manifest.layers[1].maskSourceID,result.manifest.layers[0].id);assert.deepEqual(result.analysis.issues,[]);
  const resources=new Map(data.resources),original=resources.get('images/'+base+'.png'),resource={...original,originalPNG:true,proxyBytes:Buffer.from(original.bytes)};resources.set('images/'+base+'.png',resource);const manifest={...data.manifest,version:17},preserved=pasteLayers(newProject(4,3),captureLayers(projectData(manifest,resources),[base]));assert.equal(preserved.resources.get('images/'+preserved.manifest.layers[0].imageFile),resource);assert.equal(preserved.manifest.version,17);
  const huge={...resource,bytes:{byteLength:129*1024**2}};resources.set('images/'+base+'.png',huge);assert.throws(()=>captureLayers({...data,resources},[base]),error=>error.code==='limit');
});
test('pixel paste placement and insertion retain soft selection ownership through undo',()=>{
  let data=edit(newProject(24,16),{kind:'add',type:'group',name:'Folder'}),parentID=data.manifest.activeLayerID;data=edit(data,{kind:'selection',action:'rectangle',start:[2,3],end:[7,9]});
  const original=data,result=edit(data,{kind:'importPixels',name:'Paste',png:codecs.blankPNG(5,6,false).bytes,origin:[2,3],parentID,aboveID:parentID,dropsSelection:true}),row=result.manifest.layers.at(-1);assert.deepEqual(row.transform.origin,[2,3]);assert.deepEqual(row.transform.size,[5,6]);assert.equal(row.parentID,parentID);assert.equal(result.selection,null);assert.ok(original.selection);assert.equal(original.manifest.layers.length,1);
  assert.throws(()=>edit(data,{kind:'importPixels',name:'Bad',png:codecs.blankPNG(1,1,false).bytes,origin:[Infinity,0]}),error=>error.code==='invalid');
});

test('subpixel view conversion noise does not add opaque pixels beside a pixel-aligned marquee',()=>{
  const mask=shapeMask(64,48,'rectangle',[7.999998,12.000001],[24.000002,35.999999]);assert.deepEqual(maskBounds(mask,64,48),{x:8,y:12,w:16,h:24});assert.equal(mask[14*64+7],0);assert.equal(mask[14*64+8],255);assert.equal(mask[36*64+10],0);
  assert.deepEqual(maskBounds(shapeMask(64,48,'rectangle',[8.2,12.2],[24.2,36.2]),64,48),{x:8,y:12,w:17,h:25});
});
