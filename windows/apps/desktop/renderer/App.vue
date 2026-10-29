<script setup lang="ts">
import ColorRangeDialog from './ColorRangeDialog.vue';
import DistortDialog from './DistortDialog.vue';
import{distortionPlan}from'../../../packages/comp-bridge/distort.mjs';
import EdgeRefinementDialog from './EdgeRefinementDialog.vue';
import BatchExportDialog from './BatchExportDialog.vue';
import RecentDialog from './RecentDialog.vue';
import NavigatorPanel from './NavigatorPanel.vue';
import Rulers from './Rulers.vue';
import PalettePanel from './PalettePanel.vue';
import{parityMessages}from'./parity-labels';
import ViewSettingsDialog from './ViewSettingsDialog.vue';
import {DEFAULT_VIEW_SETTINGS,VIEW_OPTION_KEYS,validateViewSettings}from'../../../packages/comp-bridge/view-settings.mjs';
import CommandDialog from './CommandDialog.vue';
import HistoryDialog from './HistoryDialog.vue';
import {commandCatalog}from'./command-catalog';
import AnimationTimeline from './AnimationTimeline.vue';
import OutputDialog from './OutputDialog.vue';
import FilterStackDialog from './FilterStackDialog.vue';
import FillDialog from './FillDialog.vue';
import PathDialog from './PathDialog.vue';
import { frameForLayer, projectForFrame } from '../../../packages/editor-adapter/animation';
import { computed, ref, reactive, onMounted, onUnmounted, nextTick, watch } from 'vue';
import { localizedMessages } from '../../../packages/locales';
import { createPreviewRenderer, pngBytes, exportPlaced, makeCanvas } from '../../../packages/editor-adapter/render';
import { BLEND_MODES, ADJUSTMENT_KINDS as ADJUSTMENTS, EFFECT_KINDS as EFFECTS } from '../../../packages/comp-bridge/capabilities.mjs';
import AdjustmentEditor from './AdjustmentEditor.vue';
import EffectEditor from './EffectEditor.vue';
import AiPanel from './AiPanel.vue';
import { editRejection } from '../../../packages/platform/edit-command.mjs';
import Icon from './Icon.vue';
import NewCanvas from './NewCanvas.vue';
import CompleteControls from './CompleteControls.vue';
import { useCompleteEditor, TOOL_LIST, TOOL_KEYS } from './useCompleteEditor';
import { ipcData } from './ipc-data';
import { visibleLayers } from '../../../packages/editor-adapter/layer-list';
import type { Language, ViewerProject, OpenResult, LayerRow,WorkspaceState,RecentState,NewCanvasDefinition } from './types';

const language = ref<Language>('zh-Hans'), version = ref(''), project = ref<ViewerProject>();
const edition = ref<'linux' | 'windows'>('windows');
const activeFrameID = ref<string>(), animationPlaying = ref(false), frameRendering = ref(false);
let playbackEpoch = 0;
const iconURL = 'compositor://app/icon.png';
const selected = ref<LayerRow>(), busy = ref(true), initialized=ref(false),error = ref(''), settingError = ref(false);
const importProgress=ref<{jobID:string;completed:number;total:number}>();
const query = ref(''), collapsed = ref(new Set<string>()), dropping = ref(false), reportState = ref<'idle' | 'copied' | 'error'>('idle');
const stage = ref<HTMLDivElement>(), canvas = ref<HTMLCanvasElement>(), zoom = ref(1);
const fitToViewport=ref(true);
const source = ref<'engine' | 'saved' | 'none'>('none'), extraIssues = ref<string[]>([]);
const tool=ref('pan'),color=ref('#bae9d6'),brushSize=ref(24),brushOpacity=ref(100),paintTarget=ref('content');
const newDialog=ref(false),newCanvasError=ref(''),psdDialog=ref(false),outputDialog=ref(false),status=ref(''),painting=ref(false);
watch(newDialog,()=>{newCanvasError.value='';});
const overlay=ref<HTMLCanvasElement>(),artboard=ref<HTMLDivElement>();
const appearance=ref('system'),showsInspector=ref(true),assistantSettingsOpen=ref(false);
const chrome=computed(()=>parityMessages[language.value]);
watch(appearance,value=>{document.documentElement.dataset.appearance=value;document.documentElement.style.colorScheme=value==='system'?'light dark':value;},{immediate:true});
function toggleInspector(){showsInspector.value=!showsInspector.value;void nextTick(updateNavigation);}
const inspectorTab=ref('properties'), detailsDialog=ref(false), searchOpen=ref(false);
const stackLiquify=ref(false),rangePNG=ref<Uint8Array>();let rangeOwner:Pick<ViewerProject,'id'|'revision'>|undefined;
async function openColorRange(){if(!editable.value)return;await request(async()=>{const owner=project.value!;rangePNG.value=await outputComposite();rangeOwner={id:owner.id,revision:owner.revision};structuredDialog.value='range';return {};});}
function closeColorRange(){structuredDialog.value='';rangePNG.value=undefined;rangeOwner=undefined;}
function applyColorRange(settings:Record<string,unknown>){return submitEdit({kind:'selection',action:'colorRange',settings,png:rangePNG.value},rangeOwner,true);}
function openFilterStack(liquify=false){const row=selected.value;if(!editable.value||!row?.imageFile||!liquify&&(row.text||row.shape||row.fill)||row.isGroup||row.adjustment){error.value='unsupported';return;}structuredLayer.value=row;stackLiquify.value=liquify;structuredDialog.value='stack';}
function openEdgeRefinement(){if(!editable.value||!selected.value?.imageFile)return;structuredLayer.value=selected.value;structuredDialog.value='refine';}
const distortIDs=ref<string[]>([]),distortTarget=ref<'content'|'mask'>('content');
function openDistort(){if(!editable.value||!selected.value)return;const target=paintTarget.value==='mask'?'mask':'content',ids=target==='mask'?[selected.value.id]:[...(full.ids.length?full.ids:[selected.value.id])];try{distortionPlan(project.value!.analysis.rows,ids,target);distortIDs.value=ids;distortTarget.value=target;structuredDialog.value='distort';}catch{error.value='unsupported';}}
const refineCommit=(op:Record<string,unknown>,owner:{id:string;revision:string})=>submitEdit(op,owner,true);
const workspaceState=ref<WorkspaceState>({tabs:[],activeID:''}),recentState=ref<RecentState>({enabled:false,entries:[]}),newInTab=ref(false),externalNotice=ref<{signature?:string;missing?:boolean}>();
const ignoredMissing=new Set<string>(),tabViews=new Map<string,{selectedID?:string;ids:string[];zoom:number;fit:boolean;left:number;top:number;target:string}>();
const swatches=ref<string[]>([...DEFAULT_VIEW_SETTINGS.swatches]),navigationViewport=ref({x:0,y:0,w:0,h:0});
const commandActions=ref<Record<string,()=>unknown>>({});
function canCommand(id:string){
  if(busy.value||painting.value||animationPlaying.value||frameRendering.value)return false;
  if(['new','open','newTab','openTab','recentProjects','recover','details','palette','viewSettings'].includes(id))return true;
  const p=project.value,row=selected.value;if(!p)return false;
  if(id==='undo')return p.canUndo;if(id==='redo')return p.canRedo;
  if(['save','saveAs','close','fit','actual','grid','snap','rulers','navigator','historyPanel','properties','unlockedCopy'].includes(id))return true;
  if(['exportAs','exportPSD','gif','eps','copyMerged','grayscaleCopy','batchExport'].includes(id))return source.value==='engine';
  if(!editable.value)return false;
  if(id==='distort'){try{distortionPlan(p.analysis.rows,paintTarget.value==='mask'?[row?.id]:full.ids.length?full.ids:[row?.id],paintTarget.value==='mask'?'mask':'content');return true;}catch{return false;}}
  if(id==='refineEdges')return !!row?.imageFile;
  if(id==='repeatFilter')return !!row?.imageFile&&!!full.lastFilter;
  if(['expandSelection','contractSelection','featherSelection','cropSelection'].includes(id))return !!p.selection;
  if(id==='addMask')return !!row&&!row.maskFile;if(id==='applyMask')return !!row?.maskFile&&!!row.imageFile;
  if(id==='newVectorMask')return !!row?.imageFile&&!row.maskFile;if(id==='vectorMaskFromPath')return !!row?.shape?.vector;
  if(id==='ungroup')return !!row?.isGroup;if(id==='group')return !!full.ids.length;
  if(id==='editFill')return !!row?.fill;if(id==='editPath')return !!row?.shape?.vector;
  if(id==='editVectorMask')return !!row?.vectorMask;if(id==='textOutlines')return !!row?.text;
  if(['cameraRaw','filter','filterStack','advancedLiquify','effects','rasterize','copy','cut','duplicate','delete','applyMask','newVectorMask','vectorMaskFromPath','addMask'].includes(id))return !!row?.imageFile||['duplicate','delete'].includes(id)&&!!row?.isGroup;
  return true;
}
const finderCommands=computed(()=>commandCatalog.map(([id,zh,en,...keys])=>({id,zh,en,shortcut:keys[0],enabled:canCommand(id)})));
function openCommands(){if(newDialog.value||psdDialog.value||outputDialog.value||structuredDialog.value||detailsDialog.value||full.modal)return;structuredDialog.value='commands';}
function showHistoryPanel(){if(project.value&&!busy.value)structuredDialog.value='history';}
async function runCommand(id:string){structuredDialog.value='';await nextTick();if(canCommand(id))await commandActions.value[id]?.();}
async function jumpHistory(index:number){const p=project.value;if(!p||busy.value)return;structuredDialog.value='';await request(()=>window.editor.jumpHistory(p.id,p.revision,index));}
const structuredDialog=ref(''),structuredEditing=ref(false),structuredLayer=ref<LayerRow>();
function openStructured(mode:string,editing=false){
  const row=selected.value;if(!editable.value)return;
  if(editing&&(mode==='fill'?!row?.fill:mode==='mask'?!row?.vectorMask:!row?.shape?.vector)){error.value='unsupported';return;}
  if(mode==='mask'&&(!row?.imageFile||!editing&&row.maskFile)){error.value='unsupported';return;}
  structuredEditing.value=editing;structuredLayer.value=row;structuredDialog.value=mode;
}
async function maskFromPath(){const p=project.value,row=selected.value;if(!p||!row?.shape?.vector)return;const siblings=p.manifest.layers.filter(layer=>layer.parentID===row.parentID),index=siblings.findIndex(layer=>layer.id===row.id),target=siblings[index-1];if(!target?.imageFile||target.maskFile){error.value='unsupported';return;}await submitEdit({kind:'vectorMask',id:target.id,sourcePathID:row.id},p);}
const tools=TOOL_LIST,toolKeys=TOOL_KEYS;
function toolLabel(key:string){return String(full.labels[key as keyof typeof full.labels] ?? t.value.editor[key as keyof typeof t.value.editor] ?? key);}
const ui = computed(() => t.value.workspace);
const thumbURL = (row: LayerRow, mask=false) => project.value?.urls[`images/${mask ? row.maskFile : row.imageFile}`];
function selectLayer(row: LayerRow,event?:MouseEvent,target='content') { if(animationPlaying.value||frameRendering.value||busy.value||painting.value)return; const p = project.value, frame = p && frameForLayer(p, row.id); if (frame && frame !== activeFrameID.value) { activeFrameID.value = frame; void renderAnimationFrame(); } full.select(row,event);paintTarget.value=target; inspectorTab.value=row.adjustment?'adjustments':'properties'; }
function showEffects() { if(selected.value?.imageFile){showsInspector.value=true;inspectorTab.value='effects';} }
function showDetails() { detailsDialog.value=true; }
function toggleSearch() { searchOpen.value=!searchOpen.value; if(!searchOpen.value)query.value=''; }
let returnFocus: HTMLElement | null = null;
let composing = false;
function compositionStart() { composing = true; }
function compositionEnd() { composing = false; }

function tabKey(event: KeyboardEvent) {
  if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
  event.preventDefault();
  const tabs = ['properties','adjustments','effects'], i=tabs.indexOf(inspectorTab.value);
  inspectorTab.value = tabs[event.key==='Home'?0:event.key==='End'?2:(i+(event.key==='ArrowRight'?1:2))%3];
  nextTick(() => document.getElementById('tab-'+inspectorTab.value)?.focus());
}
const editable=computed(()=>!!project.value&&!busy.value&&!painting.value&&!animationPlaying.value&&!frameRendering.value&&source.value==='engine'&&!issues.value.length);
const t = computed(() => localizedMessages(language.value, edition.value));
const issues = computed(() => [...(project.value?.analysis.issues ?? []), ...extraIssues.value]);
const rows = computed(() => visibleLayers(project.value?.analysis.rows ?? [], query.value, collapsed.value));
const previewURL = computed(() => project.value?.urls['QuickLook/Preview.jpg']);
const formattedProperties = computed(() => {
  if (!selected.value || !project.value) return '';
  const original = project.value.manifest.layers.find(l => l.id === selected.value?.id);
  return JSON.stringify(original, null, 2);
});
let rendererOwner = '';
let renderer: ReturnType<typeof createPreviewRenderer> | undefined, frameRenderTask: Promise<void> | undefined, epoch = 0, operation = 0, requests = 0, dragDepth = 0;
const subscriptions: (() => void)[] = [];
let navigationObserver:ResizeObserver|undefined,navigationResizeFrame=0;
function fit() {
  fitToViewport.value=true;
  void nextTick(updateNavigation);
  if(project.value&&stage.value){
    // Fitting removes scrollbars; their old thickness must not cause a second zoom.
    const bounds=stage.value.getBoundingClientRect();
    zoom.value=Math.min(8,Math.max(.01,Math.min((bounds.width-80)/project.value.manifest.width,(bounds.height-80)/project.value.manifest.height)));
  }
}
function setZoom(value:number){if(!Number.isFinite(value))return;fitToViewport.value=false;zoom.value=Math.max(.01,Math.min(8,value));}
function scale(factor: number) { setZoom(zoom.value * factor); }
function workspaceResized(){
  cancelAnimationFrame(navigationResizeFrame);
  navigationResizeFrame=requestAnimationFrame(()=>{navigationResizeFrame=0;if(fitToViewport.value&&!painting.value)fit();else updateNavigation();});
}
function labelIssue(key: string) { return t.value.issues[key as keyof typeof t.value.issues] ?? key; }
function labelError(key: string) { if(['locked','selection','source','limit'].includes(key))return key==='selection'?full.labels.noSelection:key==='source'?full.labels.sourceNeeded:full.labels[key as 'locked'|'limit']; return t.value.errors[key as keyof typeof t.value.errors] ?? t.value.errors.read; }
function kind(row: LayerRow) { return row.isGroup ? t.value.group : row.adjustment ? t.value.adjustment : row.text ? t.value.text : row.shape ? t.value.shape : t.value.raster; }
function fallback() { renderer?.dispose(); renderer = undefined; source.value = project.value?.preview ? 'saved' : 'none'; }
async function accept(result: OpenResult) {
  if (result.error) { error.value = result.error; return; }
  if(result.workspace)workspaceState.value=result.workspace;
  if (result.exported) status.value=t.value.editor.exported;
  if (result.warnings?.length) status.value=result.warnings.map(k=>t.value.editor[k as keyof typeof t.value.editor]??k).join(' · ');
  if (!result.project) return;
  stopPlayback();
  const same=project.value?.id===result.project.id, selectedID=selected.value?.id, previousZoom=zoom.value,oldActive=(project.value?.manifest as any)?.activeLayerID,newActive=(result.project.manifest as any).activeLayerID;
  if(project.value&&!same)tabViews.set(project.value.id,{selectedID:selected.value?.id,ids:[...full.ids],zoom:zoom.value,fit:fitToViewport.value,left:stage.value?.scrollLeft??0,top:stage.value?.scrollTop??0,target:paintTarget.value});
  const remembered=!same?tabViews.get(result.project.id):undefined;
  if(!same||result.didSave)externalNotice.value=undefined;
  const reuseRenderer=same&&source.value==='engine'&&!result.project.analysis.issues.length&&project.value?.manifest.width===result.project.manifest.width&&project.value?.manifest.height===result.project.manifest.height;
  const own = ++epoch; frameRendering.value = false;
  if(!reuseRenderer){renderer?.dispose();renderer=undefined;}
  project.value = result.project; selected.value = result.project.analysis.rows.find(l=>l.id===(remembered?.selectedID??(newActive!==oldActive?newActive:same?selectedID:undefined))); error.value = ''; extraIssues.value = [];
  const frames = result.project.manifest.animation?.frames;
  activeFrameID.value = frameForLayer(result.project, selected.value?.id) ?? (same && frames?.some(f => f.groupID === activeFrameID.value) ? activeFrameID.value : frames?.[0]?.groupID);
  if(!same){query.value = ''; searchOpen.value=false; collapsed.value = new Set(); status.value='';}
  if(newActive!==oldActive && selected.value)inspectorTab.value=selected.value.adjustment?'adjustments':'properties';reportState.value = 'idle';
  if(result.backup)status.value=t.value.editor.backup;
  source.value = project.value.analysis.issues.length ? (project.value.preview ? 'saved' : 'none') : 'engine';
  await nextTick();if(remembered)fitToViewport.value=remembered.fit;
  if((same||remembered)&&!fitToViewport.value)zoom.value=remembered?.zoom??previousZoom;else fit();
  if(!same)paintTarget.value=remembered?.target==='mask'&&selected.value?.maskFile?'mask':'content';
  if (epoch !== own || project.value?.id !== result.project.id) return;
  if (source.value === 'engine' && canvas.value) {
    try {
      const preview = renderer??createPreviewRenderer(); renderer = preview; rendererOwner = project.value.id + ':' + project.value.revision;
      await preview.render(projectForFrame(project.value, activeFrameID.value), canvas.value, () => {
        if (epoch !== own) return;
        extraIssues.value = ['gpu']; fallback();
      });
    } catch (e) {
      console.warn('Preview failed', (e as Error).name, (e as Error).message);
      if (epoch !== own) return;
      extraIssues.value = [(e as Error).message === 'asset' ? 'asset' : 'gpu']; fallback();
    }
  }
  if(remembered&&stage.value){stage.value.scrollLeft=remembered.left;stage.value.scrollTop=remembered.top;full.ids=remembered.ids.filter(id=>project.value?.analysis.rows.some(row=>row.id===id));}
}
async function request(action: () => Promise<OpenResult>): Promise<void> {
  if (busy.value || frameRendering.value) return;
  stopPlayback();
  const own = ++operation;
  requests++; busy.value = true; reportState.value = 'idle';
  try { const result = await action(); if (operation === own) await accept(result); }
  catch { if (operation === own) error.value = 'read'; }
  finally { requests--; busy.value = requests > 0;await refreshWorkspace(); }
}
async function refreshWorkspace(){try{const result=await window.editor.workspace('list');if(result.workspace)workspaceState.value=result.workspace;}catch{/* Closing the application may remove the IPC endpoint. */}}
function openNewTab(){newInTab.value=true;newDialog.value=true;}
async function workspaceAction(action:string,payload:Record<string,unknown>={}){await request(()=>window.editor.workspace(action,payload));if(['switch','open','recentOpen'].includes(action))void checkExternal();}
async function switchTab(id:string){if(id!==workspaceState.value.activeID&&!busy.value&&!painting.value&&!frameRendering.value)await workspaceAction('switch',{tabID:id});}
function closeTab(id:string){if(id===workspaceState.value.activeID)void closeProject();else void workspaceAction('close',{tabID:id});}
function cycleTab(delta:number){const tabs=workspaceState.value.tabs,index=tabs.findIndex(tab=>tab.active);if(tabs.length>1)switchTab(tabs[(index+delta+tabs.length)%tabs.length].id);}
async function workspaceTabKey(event:KeyboardEvent){if(event.ctrlKey||event.altKey||event.metaKey||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();event.stopPropagation();const tabs=workspaceState.value.tabs,index=tabs.findIndex(tab=>tab.active),next=tabs[event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowLeft'?-1:1)+tabs.length)%tabs.length];if(next){await switchTab(next.id);await nextTick();document.querySelector<HTMLButtonElement>('[data-tab-id="'+next.id+'"]')?.focus();}}
async function showRecent(){if(busy.value||painting.value)return;const result=await window.editor.workspace('recent');if(result.recent){recentState.value=result.recent;structuredDialog.value='recent';}}
function recentSettings(action:string,payload?:Record<string,unknown>){return window.editor.workspace(action,payload);}
async function openRecent(id:string){structuredDialog.value='';await workspaceAction('recentOpen',{id});}
async function copyProject(){const p=project.value;if(p)await workspaceAction('copy',{id:p.id,revision:p.revision});}
async function grayscaleCopy(){const p=project.value;if(p)await request(async()=>window.editor.workspace('grayscale',{id:p.id,revision:p.revision,png:await outputComposite()}));}
let checkingExternal=false,recheckExternal=false;
async function checkExternal(){if(checkingExternal){recheckExternal=true;return;}const p=project.value;if(!p?.hasLocation||busy.value||painting.value||frameRendering.value||animationPlaying.value||modalOpen.value)return;checkingExternal=true;try{const result=await window.editor.workspace('external',{id:p.id,revision:p.revision});if(!result.error&&!busy.value&&project.value?.id===p.id&&project.value.revision===p.revision){if(!result.missing)ignoredMissing.delete(p.id);if(result.changed&&!(result.missing&&ignoredMissing.has(p.id)))externalNotice.value={signature:result.signature,missing:result.missing};}}catch{/* An obsolete read must not interrupt the current editor action. */}finally{checkingExternal=false;if(recheckExternal){recheckExternal=false;void checkExternal();}}}

async function ignoreExternal(){const p=project.value,notice=externalNotice.value;if(!p||!notice)return;if(notice.missing)ignoredMissing.add(p.id);await window.editor.workspace('ignoreExternal',{id:p.id,revision:p.revision,signature:notice.signature});externalNotice.value=undefined;}
function open() { if(painting.value)return Promise.resolve();return request(() => window.viewer.open()); }
function reload() { if(painting.value)return;const id = project.value?.id; if (id) return request(() => window.viewer.reload(id)); }
let closeTask:Promise<void>|undefined;
function closeProject(){if(!closeTask)closeTask=closeProjectNow().finally(()=>{closeTask=undefined;});return closeTask;}
async function closeProjectNow() {
  if(painting.value)return;const owner=project.value?.id,deadline=Date.now()+30000;
  while((busy.value||frameRendering.value)&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,20));
  if(busy.value||frameRendering.value||painting.value||project.value?.id!==owner)return;
  busy.value=true;let result:OpenResult;try{result=await window.viewer.close();}finally{busy.value=false;}if(result.workspace)workspaceState.value=result.workspace;if(!result.closed){if(result.error)error.value=result.error;return;}
  if(result.project){await request(()=>Promise.resolve(result));return;}
  stopPlayback(); operation++; epoch++; renderer?.dispose(); renderer = undefined;
  drag = undefined;
  project.value = undefined; frameRendering.value=false; selected.value = undefined; source.value = 'none'; error.value = ''; extraIssues.value = [];
  structuredDialog.value='';outputDialog.value=false;full.closeModal();
  query.value = ''; collapsed.value = new Set(); reportState.value = 'idle';
}
async function submitEdit(op:Record<string,unknown>,owner:Pick<ViewerProject,'id'|'revision'>|undefined=project.value,finishingStroke=false):Promise<OpenResult>{
  if (animationPlaying.value || frameRendering.value) return {error:'busy'};
  const denied=editRejection(op,owner,project.value,{busy:busy.value,painting:painting.value,source:source.value,issues:issues.value},finishingStroke);
  if(denied){error.value=denied;return {error:denied};}
  let result:OpenResult={error:'read'};
  await request(async()=>{result=await window.editor.edit(owner!.id,owner!.revision,ipcData(op));return result;});
  return result;
}
function edit(op:Record<string,unknown>){const p=project.value;if(!p)return;if(op.kind==='transform'&&(full.ids.length>1||selected.value?.isGroup))op={...op,kind:'transformLayers',ids:full.ids};return submitEdit({id:selected.value?.id,...op},p);}
function history(direction:string){const p=project.value;if(p)return request(()=>window.editor.history(p.id,p.revision,direction));}
function save(as=false){const p=project.value;if(p)return request(()=>window.editor.save(p.id,p.revision,as));}
function cancelImageImport(){if(importProgress.value)void window.viewer.cancelImport(importProgress.value.jobID).catch(()=>{});}
async function importImage(): Promise<void> {if(busy.value||frameRendering.value)return;const p=project.value;try{await request(()=>window.editor.importImage(p?.id,p?.revision,selected.value?.id));}finally{importProgress.value=undefined;}}
function importPSD(){return request(()=>window.editor.importPSD());}
function recover(){return request(()=>window.editor.recover());}
function add(type:string,adjustment?:string){return edit({kind:'add',type,adjustment,name:type==='group'?t.value.editor.group:type==='adjustment'?t.value.adjustments[ADJUSTMENTS.indexOf(adjustment!)]:t.value.raster,parentID:selected.value?.isGroup?selected.value.id:selected.value?.parentID});}
function numberEvent(e:Event){return Number((e.target as HTMLInputElement).value);}
function transformPair(field:'origin'|'size',index:number,e:Event){if(!selected.value)return;const value=[...(full.selectionTransform??selected.value.transform)[field]];value[index]=numberEvent(e);return edit({kind:'transform',field,value});}
async function create(definition:NewCanvasDefinition){
  newCanvasError.value='';const inTab=newDialog.value&&newInTab.value;
  await request(async()=>{
    const {width,height,resolution,background}=definition;
    const result=await(inTab?window.editor.workspace('create',{width,height,resolution,background}):window.editor.create(width,height,{resolution,background}));
    if(result.error)newCanvasError.value=labelError(result.error);
    if(result.project){newDialog.value=false;newInTab.value=false;}
    return result;
  });
}
async function outputComposite(){
  const p=project.value;stopPlayback();if(frameRendering.value)await frameRenderTask;
  if(!p||!canvas.value||project.value?.id!==p.id||project.value?.revision!==p.revision||source.value!=='engine'||painting.value)throw new Error(t.value.errorTitle);
  return pngBytes(canvas.value);
}
async function exportImage(type:string,flatten=false,options:Record<string,unknown>={}):Promise<OpenResult|undefined>{
  stopPlayback();
  const p=project.value,c=canvas.value;if(!p||!c||source.value!=='engine'||painting.value)return;
  if(frameRendering.value)await frameRenderTask;
  if(project.value?.id!==p.id||project.value?.revision!==p.revision||source.value!=='engine'||frameRendering.value||painting.value)return;
  psdDialog.value=false;
  let outputResult:OpenResult|undefined;
  try { await request(async()=>{
    const composite=await pngBytes(c),layers:{id:string;image:Uint8Array;left:number;top:number}[]=[],masks:{id:string;image:Uint8Array;left:number;top:number}[]=[],frames:{png:Uint8Array}[]=[];
    if(type==='gif'){
      const track=p.manifest.animation;
      if(p.manifest.width*p.manifest.height*(track?.frames.length??1)>64_000_000)return {error:'gifLimit'};
      if(track){
        // Keep at most one frame's render surfaces alive; encoded frames have a separate budget.
        renderer?.dispose();renderer=undefined;
        let encoded=0;
        const preview=createPreviewRenderer(),surface=makeCanvas(p.manifest.width,p.manifest.height);
        try{for(const f of track.frames){
          if(project.value?.id!==p.id||project.value?.revision!==p.revision)return {error:'stale'};
          let failed=false;
          await preview.render(projectForFrame(p,f.groupID),surface,()=>{failed=true;});
          if(failed)throw new Error('gpu');
          const png=await pngBytes(surface);encoded+=png.byteLength;if(encoded>192*1024**2)return {error:'gifLimit'};frames.push({png});
        }}finally{preview.dispose();surface.width=surface.height=1;}
      }else frames.push({png:composite});
    }
    if(type==='psd'&&!flatten){
      if(p.manifest.layers.filter(l=>l.imageFile).length*p.manifest.width*p.manifest.height*8>512*1024**2)return {error:'limit'};
      for(const l of p.manifest.layers){
        if(l.imageFile)layers.push({id:l.id,...await exportPlaced(p.urls[`images/${l.imageFile}`],l.transform)});
        if(l.maskFile)masks.push({id:l.id,...await exportPlaced(p.urls[`images/${l.maskFile}`],l.maskPlacement??l.transform)});
      }
    }
    outputResult=await window.editor.export(p.id,p.revision,type,{composite,layers,masks,flatten,frames,frameID:activeFrameID.value,options});return outputResult;
  }); } finally { if(type==='gif'&&p.manifest.animation&&project.value?.id===p.id&&project.value?.revision===p.revision)await renderAnimationFrame(); }
  return outputResult;
}
function stopPlayback(){const wasPlaying=animationPlaying.value;animationPlaying.value=false;playbackEpoch++;if(wasPlaying)selectAnimationFrame(activeFrameID.value);}
function renderAnimationFrame(){return frameRenderTask=drawAnimationFrame();}
async function drawAnimationFrame(){
  const p=project.value,c=canvas.value;if(!p||!c||source.value!=='engine')return;
  const own=++epoch;frameRendering.value=true;
  const key=p.id+':'+p.revision;
  if(rendererOwner!==key){renderer?.dispose();renderer=undefined;}
  try{const preview=renderer??createPreviewRenderer();renderer=preview;rendererOwner=key;await preview.render(projectForFrame(p,activeFrameID.value),c,()=>{if(epoch===own){extraIssues.value=['gpu'];fallback();stopPlayback();}});}
  catch(e){if(epoch===own){error.value=(e as Error).message==='asset'?'asset':'gpu';fallback();stopPlayback();}}
  finally{if(epoch===own)frameRendering.value=false;}
}
async function seekFrame(id:string){
  if(!editable.value||!project.value?.manifest.animation?.frames.some(f=>f.groupID===id))return;
  activeFrameID.value=id;
  selectAnimationFrame(id);
  await renderAnimationFrame();
}
function selectAnimationFrame(id?:string){
  const p=project.value;if(!p||!id)return;
  const frame=id.toUpperCase(),belongs=(row:LayerRow)=>frameForLayer(p,row.id)?.toUpperCase()===frame;
  const row=p.analysis.rows.find(l=>!!l.imageFile&&belongs(l))??p.analysis.rows.find(l=>!l.isGroup&&belongs(l))??p.analysis.rows.find(l=>l.id.toUpperCase()===frame);
  if(row)full.select(row);
}
async function playAnimation(){
  if(animationPlaying.value){stopPlayback();return;}
  const p=project.value,track=p?.manifest.animation;if(!p||!track||!editable.value)return;
  const own=++playbackEpoch;animationPlaying.value=true;let cycle=0;
  try{do{for(const f of track.frames){
    if(own!==playbackEpoch||project.value?.id!==p.id||project.value?.revision!==p.revision)return;
    const deadline=performance.now()+f.durationMS;activeFrameID.value=f.groupID;await renderAnimationFrame();
    if(own!==playbackEpoch)return;await new Promise(resolve=>setTimeout(resolve,Math.max(0,deadline-performance.now())));
  }cycle++;}while(track.loopCount===0||track.loopCount>0&&cycle<=track.loopCount);}
  finally{if(own===playbackEpoch)stopPlayback();}
}
const layeredPSD=computed(()=>project.value&&!project.value.manifest.layers.some(l=>l.adjustment||l.effects&&Object.values(l.effects).some(e=>e.enabled!==false)));
function dragEnter(event: DragEvent) {
  if(modalOpen.value)return;
  if (event.dataTransfer?.types.includes('Files')) { dragDepth++; dropping.value = true; }
}
function dragLeave() { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) dropping.value = false; }
function dragOver(event: DragEvent) { if (event.dataTransfer) event.dataTransfer.dropEffect = busy.value||modalOpen.value ? 'none' : 'copy'; }
async function dropProject(event: DragEvent) {
  dragDepth = 0; dropping.value = false;
  if (busy.value||painting.value||frameRendering.value||modalOpen.value) return;
  const files = event.dataTransfer?.files;
  if (!files?.length) return;
  if(files.length===1&&/\.comp$/i.test(files[0].name))return request(()=>window.viewer.drop(files[0]));
  const p=project.value,board=artboard.value?.getBoundingClientRect(),area=stage.value?.getBoundingClientRect(),x=event.clientX,y=event.clientY,inside=board&&area&&x>=Math.max(board.left,area.left)&&x<=Math.min(board.right,area.right)&&y>=Math.max(board.top,area.top)&&y<=Math.min(board.bottom,area.bottom),point=p&&inside?[(x-board!.left)/zoom.value,(y-board!.top)/zoom.value]:undefined;
  try{await request(()=>window.viewer.dropFiles([...files],{id:p?.id,revision:p?.revision,targetID:selected.value?.id,point}));}finally{importProgress.value=undefined;}
}
function toggleGroup(row: LayerRow) {
  const key = row.id.toUpperCase(), next = new Set(collapsed.value);
  if (next.has(key)) next.delete(key); else next.add(key);
  collapsed.value = next;
}
async function copyReport() {
  const id = project.value?.id;
  if (!id || busy.value) return;
  try {
    const result = await window.viewer.copyReport(id, { source: source.value, issues: [...extraIssues.value] });
    if (project.value?.id === id) reportState.value = result.copied ? 'copied' : 'error';
  } catch { if (project.value?.id === id) reportState.value = 'error'; }
}
function savedPreviewFailed() { extraIssues.value = ['asset']; source.value = 'none'; }
async function changeLanguage(event: Event) {
  const value = (event.target as HTMLSelectElement).value as Language;
  try { const result = await window.viewer.language(value); language.value = result.language; document.documentElement.lang = result.language; settingError.value = false; }
  catch { settingError.value = true; }
}
function onKey(event: KeyboardEvent) {
  if(event.isComposing)return;
  if (event.key==='Tab' && modalOpen.value) {
    const modal=[...document.querySelectorAll<HTMLElement>('.modal-shade')].at(-1);
    const fields=[...(modal?.querySelectorAll<HTMLElement>('button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),summary,[tabindex]:not([tabindex="-1"])') ?? [])].filter(e=>!e.matches(':disabled')&&e.getClientRects().length);
    const first=fields[0],last=fields.at(-1);
    if(first && ((!event.shiftKey && (document.activeElement===last || !modal?.contains(document.activeElement))) || (event.shiftKey && (document.activeElement===first || !modal?.contains(document.activeElement))))) { event.preventDefault(); (event.shiftKey?last:first)?.focus(); }
  }
  if(modalOpen.value){
    if(event.key==='Escape'){full.key(event);stopPlayback();cancelStroke();newDialog.value=false;psdDialog.value=false;outputDialog.value=false;structuredDialog.value='';detailsDialog.value=false;assistantSettingsOpen.value=false;}
    return;
  }
  if(event.key===' '&&!event.repeat&&!event.ctrlKey&&!event.metaKey&&!event.altKey&&!((event.target as HTMLElement)?.closest('input,textarea,select,button,a[href],summary,[role=button],[contenteditable]'))&&project.value?.manifest.animation){event.preventDefault();void playAnimation();return;}
  if(event.key.toLowerCase()==='p'&&!event.ctrlKey&&!event.metaKey&&!event.altKey&&!(event.target as HTMLElement)?.closest('input,textarea,select,[contenteditable]')){event.preventDefault();openStructured('path');return;}
  if((event.ctrlKey||event.metaKey)&&event.shiftKey&&event.key.toLowerCase()==='p'){event.preventDefault();openCommands();return;}
  full.key(event);
  const input=(event.target as HTMLElement)?.closest('input,textarea,select,[contenteditable]');
  if(!painting.value&&!input&&!event.ctrlKey&&!event.altKey&&!event.metaKey){const k=event.key.toLowerCase();if(['b','e','v','h'].includes(k))tool.value=({b:'brush',e:'eraser',v:'move',h:'pan'} as Record<string,string>)[k];}
  if(event.key==='Escape'){stopPlayback();cancelStroke();newDialog.value=false;psdDialog.value=false;outputDialog.value=false;structuredDialog.value='';detailsDialog.value=false;}
  if (event.ctrlKey && event.key.toLowerCase() === 'r') { event.preventDefault(); reload(); }
  if (event.ctrlKey && event.key.toLowerCase() === 'w') { event.preventDefault(); closeProject(); }
  if (event.ctrlKey && event.key === '+') { event.preventDefault(); scale(1.25); }
  if (event.ctrlKey && event.key === '-') { event.preventDefault(); scale(.8); }
}
function wheel(event: WheelEvent) { if (event.ctrlKey) { event.preventDefault(); scale(event.deltaY < 0 ? 1.1 : 1 / 1.1); } }
let drag: { x: number; y: number; left: number; top: number } | undefined;
const full=reactive(useCompleteEditor({openPath:()=>openStructured('path',true),project,selected,tool,color,brushSize,brushOpacity,paintTarget,painting,editable,language,canvas,overlay,artboard,stage,zoom,error,execute:async(op,p=project.value)=>{return await submitEdit({id:selected.value?.id,...op},p,true);},receive:result=>request(()=>Promise.resolve(result)),history,scale}));
const modalOpen=computed(()=>!!(assistantSettingsOpen.value||newDialog.value||psdDialog.value||outputDialog.value||structuredDialog.value||detailsDialog.value||full.modal));
function outsideModal(action:()=>unknown){return ()=>{if(!modalOpen.value&&!composing)return action();};}
watch(modalOpen, async visible => {
  if (visible) {
    stopPlayback();
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    await nextTick();
    if (modalOpen.value) {
      const modal=[...document.querySelectorAll<HTMLElement>('.modal-shade')].at(-1);
      (modal?.querySelector<HTMLElement>('[autofocus]:not([disabled])')??modal?.querySelector<HTMLElement>('input:not([disabled]),textarea:not([disabled]),select:not([disabled]),button:not([disabled])'))?.focus();
    }
  } else if (returnFocus?.isConnected) returnFocus.focus();
});
function cancelStroke(){full.cancel();drag=undefined;}
let viewPreferencesReady=false,viewPreferencesTimer:ReturnType<typeof setTimeout>|undefined;
function viewState(){return {appearance:appearance.value,...Object.fromEntries(VIEW_OPTION_KEYS.map(key=>[key,(full.options as Record<string,any>)[key]])),foreground:color.value,background:full.background,swatches:[...swatches.value]};}
function applyViewSettings(value:Record<string,any>){const settings=validateViewSettings(value);appearance.value=settings.appearance;for(const key of VIEW_OPTION_KEYS)(full.options as Record<string,any>)[key]=settings[key];color.value=settings.foreground;full.background=settings.background;swatches.value=[...settings.swatches];}
function confirmViewSettings(value:Record<string,any>){applyViewSettings(value);structuredDialog.value='';}
watch(viewState,()=>{if(!viewPreferencesReady)return;clearTimeout(viewPreferencesTimer);viewPreferencesTimer=setTimeout(()=>{void window.viewer.viewSettings(ipcData(viewState())).then(result=>{if(result.error)settingError.value=true;}).catch(()=>{settingError.value=true;});},150);},{deep:true});
const gridStyle=computed(()=>{const spacing=Math.max(1,full.options.gridSpacing*zoom.value),minor=Math.max(.5,spacing/full.options.gridSubdivisions),rgb=[1,3,5].map(index=>parseInt(full.options.gridColor.slice(index,index+2),16)),line=(opacity:number)=>'rgba('+rgb.join(',')+','+opacity+')',major=line(full.options.gridOpacity/100),faint=line(full.options.gridOpacity/300);return {backgroundImage:`linear-gradient(to right,${major} 1px,transparent 1px),linear-gradient(to bottom,${major} 1px,transparent 1px),linear-gradient(to right,${faint} 1px,transparent 1px),linear-gradient(to bottom,${faint} 1px,transparent 1px)`,backgroundSize:`${spacing}px ${spacing}px,${spacing}px ${spacing}px,${minor}px ${minor}px,${minor}px ${minor}px`};});
function stageBounds(area:HTMLElement){const box=area.getBoundingClientRect(),left=box.left+area.clientLeft,top=box.top+area.clientTop;return{left,top,right:left+area.clientWidth,bottom:top+area.clientHeight,width:area.clientWidth,height:area.clientHeight};}
function updateNavigation(){const p=project.value,area=stage.value,board=artboard.value;if(!p||!area||!board)return;const bounds=stageBounds(area),image=board.getBoundingClientRect(),x=Math.max(0,Math.min(p.manifest.width,(bounds.left-image.left)/zoom.value)),y=Math.max(0,Math.min(p.manifest.height,(bounds.top-image.top)/zoom.value));navigationViewport.value={x,y,w:Math.max(0,Math.min(p.manifest.width-x,(bounds.right-Math.max(bounds.left,image.left))/zoom.value)),h:Math.max(0,Math.min(p.manifest.height-y,(bounds.bottom-Math.max(bounds.top,image.top))/zoom.value))};}
function navigate(point:{x:number;y:number}){const area=stage.value,board=artboard.value;if(!area||!board||busy.value||painting.value)return;const bounds=stageBounds(area),image=board.getBoundingClientRect();area.scrollLeft+=image.left-bounds.left+point.x*zoom.value-bounds.width/2;area.scrollTop+=image.top-bounds.top+point.y*zoom.value-bounds.height/2;updateNavigation();}
async function rulerGuide(guide:{axis:string;position:number;owner:{id:string;revision:string}}){const p=project.value;if(p)await submitEdit({kind:'guides',guides:[...(p.manifest.guides??[]),{id:crypto.randomUUID().toUpperCase(),axis:guide.axis,position:guide.position}]},guide.owner);}
watch(()=>[project.value?.id,project.value?.revision,zoom.value,busy.value,frameRendering.value],()=>{void nextTick(updateNavigation);},{flush:'post'});
function panStart(event:PointerEvent){if(full.start(event))return;if(!stage.value||event.button!==0||!project.value)return;drag={x:event.clientX,y:event.clientY,left:stage.value.scrollLeft,top:stage.value.scrollTop};stage.value.setPointerCapture(event.pointerId);}
function panMove(event:PointerEvent){if(full.move(event))return;if(!stage.value||!drag)return;stage.value.scrollLeft=drag.left+drag.x-event.clientX;stage.value.scrollTop=drag.top+drag.y-event.clientY;}
async function panEnd(event:PointerEvent){drag=undefined;await full.end(event);}
onMounted(async () => {
  const settings = await window.viewer.settings(); language.value = settings.language; version.value = settings.version; edition.value = settings.edition;
  document.documentElement.lang = language.value;
  try{const result=await window.viewer.viewSettings();if(result.settings)applyViewSettings(result.settings);await nextTick();}catch{settingError.value=true;}viewPreferencesReady=true;await refreshWorkspace();
  subscriptions.push(window.viewer.onOpen(outsideModal(open)), window.viewer.onReload(outsideModal(reload)), window.viewer.onClose(outsideModal(closeProject)), window.viewer.onFit(outsideModal(fit)), window.viewer.onActual(outsideModal(() => setZoom(1))));
  subscriptions.push(window.viewer.onImportProgress(value=>{importProgress.value=value;}));
  const commands: Record<string, () => unknown> = {...full.commands,distort:openDistort,refineEdges:openEdgeRefinement,colorRange:openColorRange,batchExport:()=>{if(editable.value)structuredDialog.value='batch';},newTab:openNewTab,openTab:()=>workspaceAction('open'),tabNext:()=>cycleTab(1),tabPrevious:()=>cycleTab(-1),recentProjects:showRecent,unlockedCopy:copyProject,grayscaleCopy,externalCheck:checkExternal,navigator:()=>{full.options.navigator=!full.options.navigator;},rulers:()=>{full.options.rulers=!full.options.rulers;},palette:()=>{full.options.palette=!full.options.palette;},viewSettings:()=>{structuredDialog.value='viewSettings';},commandFinder:openCommands,historyPanel:showHistoryPanel,textOutlines:()=>edit({kind:'textOutlines'}),filterStack:()=>openFilterStack(),advancedLiquify:()=>openFilterStack(true),newFill:()=>openStructured('fill'),editFill:()=>openStructured('fill',true),newPath:()=>openStructured('path'),editPath:()=>openStructured('path',true),newVectorMask:()=>openStructured('mask'),editVectorMask:()=>openStructured('mask',true),vectorMaskFromPath:maskFromPath,exportAs:()=>{outputDialog.value=true;},new:()=>{newInTab.value=false;newDialog.value=true;},image:importImage,importPSD,save:()=>save(),saveAs:()=>save(true),png:()=>exportImage('png'),gif:()=>exportImage('gif'),eps:()=>exportImage('eps'),exportPSD:()=>{psdDialog.value=true;},recover,undo:()=>history('undo'),redo:()=>history('redo'),addPixels:()=>add('pixels'),addGroup:()=>add('group'),addMask:()=>{if(selected.value)edit({kind:'mask',action:'add'});},details:showDetails,properties:()=>{showsInspector.value=true;inspectorTab.value='properties';},effects:showEffects};
  commandActions.value={...commands,open,close:closeProject,fit,actual:()=>setZoom(1)};
  for(const [name,action] of Object.entries(commands))subscriptions.push(window.editor.onCommand(name,()=>{
    if(composing)return;
    if(['copy','cut','paste','selectAll','undo','redo'].includes(name)&&document.activeElement?.closest('input,textarea,[contenteditable]')){void window.editor.textClipboard(name);return;}
    if(modalOpen.value)return;
    if(painting.value&&!(full.clipboardBusy&&['copy','copyMerged','cut','paste'].includes(name)))return;
    if(name==='undo'&&!project.value?.canUndo||name==='redo'&&!project.value?.canRedo)return;
    action();
  }));
  window.addEventListener('compositionstart', compositionStart); window.addEventListener('compositionend', compositionEnd);
  if(stage.value){navigationObserver=new ResizeObserver(workspaceResized);navigationObserver.observe(stage.value);}
  window.addEventListener('keydown', onKey); window.addEventListener('resize', workspaceResized);
  busy.value=false;initialized.value=true;await window.viewer.ready();
});
onUnmounted(() => { stopPlayback();clearTimeout(viewPreferencesTimer); operation++; epoch++; cancelStroke();renderer?.dispose(); full.closeModal();navigationObserver?.disconnect();cancelAnimationFrame(navigationResizeFrame);subscriptions.forEach(stop => stop()); window.removeEventListener('compositionstart', compositionStart); window.removeEventListener('compositionend', compositionEnd); window.removeEventListener('keydown', onKey); window.removeEventListener('resize', workspaceResized); });
</script>

<template>
  <div class="shell" @dragenter.prevent="dragEnter" @dragover.prevent="dragOver" @dragleave="dragLeave" @drop.prevent="dropProject">
    <div v-if="dropping" class="drop-target" role="status">{{ t.dropHint }}</div>
    <header class="toolbar documentbar">
      <div class="brand"><img :src="iconURL" alt=""><strong>{{ t.title }}</strong></div>
      <div class="document-actions">
        <button class="icon-button" :disabled="busy || painting" :title="t.editor.newCanvas + ' · Ctrl+N'" :aria-label="t.editor.newCanvas" data-testid="new-canvas" @click="newInTab=false;newDialog=true"><Icon name="new"/></button>
        <button class="icon-button" :disabled="busy || painting" :title="t.open + ' · Ctrl+O'" :aria-label="t.open" data-testid="open-project" @click="open"><Icon name="open"/></button>
        <button class="icon-button" :disabled="!project || busy || painting" :title="t.editor.save + ' · Ctrl+S'" :aria-label="t.editor.save" data-testid="save-project" @click="save()"><Icon name="save"/></button>
      </div>
      <button v-if="!workspaceState.tabs.length && (project || busy)" class="icon-button tab-close" :title="t.close + ' · Ctrl+W'" :aria-label="t.close" data-testid="close-project" :disabled="painting" @click="closeProject"><Icon name="close"/></button>
      <div class="history-tools">
        <button class="icon-button" :disabled="!project?.canUndo || busy || painting" :title="t.editor.undo + ' · Ctrl+Z'" :aria-label="t.editor.undo" data-testid="undo" @click="history('undo')"><Icon name="undo"/></button>
        <button class="icon-button" :disabled="!project?.canRedo || busy || painting" :title="t.editor.redo + ' · Ctrl+Shift+Z'" :aria-label="t.editor.redo" data-testid="redo" @click="history('redo')"><Icon name="redo"/></button>
      </div>
      <div v-if="project||workspaceState.tabs.length" class="document-tabs" role="tablist" :aria-label="language==='en'?'Open projects':'打开的项目'" @keydown="workspaceTabKey">
      <div v-for="tab in workspaceState.tabs" :key="tab.id" class="document-tab" :class="{active:tab.active}"><button role="tab" :title="tab.name" :aria-selected="tab.active" :tabindex="tab.active?0:-1" :disabled="busy||painting||frameRendering" :data-tab-id="tab.id" @click="switchTab(tab.id)">{{tab.name}}<span v-if="tab.dirty">•</span></button><button class="tab-close" :data-testid="tab.active?'close-project':undefined" :disabled="painting||frameRendering||(!tab.active&&busy)" :aria-label="(language==='en'?'Close tab · ':'关闭标签页 · ')+tab.name" @click="tab.active?closeProject():closeTab(tab.id)">×</button></div><button class="new-tab" data-testid="new-tab" :disabled="busy||painting||frameRendering" :aria-label="language==='en'?'New tab':'新建标签页'" @click="openNewTab">+</button>
    </div>
      <div v-if="!project&&!workspaceState.tabs.length" class="toolbar-spacer"></div>
      <div class="zoom-tools">
        <button class="icon-button" :disabled="!project" :title="t.fit + ' · Ctrl+0'" :aria-label="t.fit" @click="fit"><Icon name="fit"/></button>
        <button class="icon-button" :disabled="!project" :aria-label="ui.zoomOut" @click="scale(.8)"><Icon name="minus"/></button>
        <button class="zoom-value" :disabled="!project" title="100% · Ctrl+1" @click="setZoom(1)">{{ Math.round(zoom * 100) }}%</button>
        <button class="icon-button" :disabled="!project" :aria-label="ui.zoomIn" @click="scale(1.25)"><Icon name="plus"/></button>
      </div>
      <div class="toolbar-utilities">
        <button class="icon-button" :disabled="busy||painting" :aria-label="chrome.inspector" :title="chrome.inspector" :aria-expanded="showsInspector" aria-controls="project-inspector" data-testid="toggle-inspector" @click="toggleInspector"><Icon name="sidebar"/></button>
        <button class="icon-button" :disabled="!project||source!=='engine'||busy||painting" :aria-label="chrome.exportDocument" :title="chrome.exportDocument" data-testid="export-document" @click="outputDialog=true"><Icon name="export"/></button>
      </div>
      <select class="language-select" :aria-label="t.language" :value="language" data-testid="language" @change="changeLanguage"><option value="zh-Hans">简体中文</option><option value="en">English</option></select>
      <button class="icon-button" :disabled="busy||painting" :aria-label="chrome.appearanceSettings" :title="chrome.appearanceSettings" data-testid="interface-settings" @click="structuredDialog='viewSettings'"><Icon name="appearance"/></button>
      <button class="icon-button" :aria-label="ui.details" :title="ui.details" data-testid="project-details" @click="showDetails"><Icon name="info"/></button>
    </header>
    <div v-if="importProgress" class="notice import-progress" role="status" data-testid="import-progress"><span>{{language==='en'?'Importing images':'正在导入图像'}} · {{importProgress.completed}} / {{importProgress.total}}</span><progress :value="importProgress.completed" :max="importProgress.total" :aria-label="language==='en'?'Importing images':'正在导入图像'"></progress><button data-testid="cancel-import" @click="cancelImageImport">{{language==='en'?'Cancel':'取消'}}</button></div>
    <div v-if="externalNotice" class="notice external-notice" role="status"><span>{{language==='en'?(externalNotice.missing?'The project on disk is missing or cannot be read. Current edits are still open.':'The project changed on disk. Reload to read those changes; saving checks the original file first.'):(externalNotice.missing?'磁盘上的项目已丢失或无法读取，当前编辑仍保留。':'项目已被外部修改；可重新加载查看。保存前会检查原文件，防止覆盖外部更改。')}}</span><button :disabled="busy" @click="reload">{{language==='en'?'Reload':'重新加载'}}</button><button :disabled="busy" @click="ignoreExternal">{{language==='en'?'Dismiss':'暂不处理'}}</button></div>
    <div v-if="error || settingError" class="error" role="alert">{{ settingError ? t.settingsError : t.errorTitle + ' · ' + labelError(error) }}<button class="icon-button" :aria-label="t.editor.cancel" @click="error='';settingError=false"><Icon name="close"/></button></div>
    <div class="optionsbar" data-testid="tool-options">
      <span class="tool-heading"><Icon :name="tool"/>{{ toolLabel(tool) }}</span>
      <template v-if="tool==='move' && selected">
        <label v-for="(key,i) in ['X','Y']" :key="key">{{ key }}<input type="number" :value="(full.selectionTransform??selected.transform).origin[i]" :disabled="!editable" @change="transformPair('origin',i,$event)"></label>
        <label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="key">{{ key }}<input type="number" min="1" max="300000" :value="(full.selectionTransform??selected.transform).size[i]" :disabled="!editable" @change="transformPair('size',i,$event)"></label>
        <label>{{ t.editor.rotation }}<span class="unit-field"><input type="number" :value="(full.selectionTransform??selected.transform).rotation" :disabled="!editable" @change="edit({kind:'transform',field:'rotation',value:numberEvent($event)})"><span>°</span></span></label>
        <button class="icon-button" :disabled="!editable" :title="t.editor.flipH" :aria-label="t.editor.flipH" @click="edit({kind:'transform',field:'flipX',value:!(full.selectionTransform??selected.transform).flipX})"><Icon name="flipH"/></button>
        <button class="icon-button" :disabled="!editable" :title="t.editor.flipV" :aria-label="t.editor.flipV" @click="edit({kind:'transform',field:'flipY',value:!(full.selectionTransform??selected.transform).flipY})"><Icon name="flipV"/></button>
      </template>
      <CompleteControls :e="full" mode="options" :tool="tool" :disabled="busy || painting" :selected="selected" :color="color" :size="brushSize" :opacity="brushOpacity" :target="paintTarget" @size="brushSize=$event" @opacity="brushOpacity=$event" @target="paintTarget=$event"/>
      <span v-if="tool==='pan'" class="tool-hint">{{ tool==='pan' ? ui.panHint : ui.moveHint }}</span>
    </div>
    <main>
      <nav class="toolrail" :aria-label="ui.tools">
        <div class="toolrail-scroll">
        <button v-for="key in tools.filter(key=>!['pan','zoom'].includes(key))" :key="key" class="icon-button tool-button" :class="{active:tool===key}" :aria-pressed="tool===key" :disabled="painting || (key!=='pan' && !editable)" :title="toolLabel(key) + ' (' + toolKeys[key] + ')'" :aria-label="toolLabel(key)" @click="tool=key"><Icon :name="key"/></button>
        <button class="icon-button tool-button" :disabled="painting||!editable" :title="full.labels.pen+' (P)'" :aria-label="full.labels.pen" @click="openStructured('path')"><Icon name="pen"/></button></div>
        <div class="toolrail-footer"><div class="rail-divider"></div>
        <button v-for="key in tools.filter(key=>['pan','zoom'].includes(key))" :key="key" class="icon-button tool-button" :class="{active:tool===key}" :aria-pressed="tool===key" :disabled="painting || (key!=='pan' && !editable)" :title="toolLabel(key) + ' (' + toolKeys[key] + ')'" :aria-label="toolLabel(key)" @click="tool=key"><Icon :name="key"/></button>
        <label class="color-swatch" :title="full.labels.foreground"><span :style="{background:color}"></span><input type="color" v-model="color" :aria-label="t.editor.color" :disabled="painting"></label>
        <label class="color-swatch background-swatch" :title="full.labels.background"><span :style="{background:full.background}"></span><input type="color" v-model="full.background" :aria-label="full.labels.background" :disabled="painting"></label>
        <button class="icon-button" :title="full.labels.swap+' (X)'" :aria-label="full.labels.swap" @click="[color,full.background]=[full.background,color]"><Icon name="swap"/></button>
        <button class="icon-button" :title="full.labels.defaults+' (D)'" :aria-label="full.labels.defaults" @click="color='#000000';full.background='#ffffff'"><Icon name="defaults"/></button>
        </div>
      </nav>
      <section class="workarea navigation-workarea">
        <div v-if="issues.length" class="notice">{{ source==='saved' ? t.fallback : t.detailsOnly }} {{ issues.map(labelIssue).join(' · ') }}</div>
        <div ref="stage" class="stage" @scroll="updateNavigation" @wheel="wheel" @pointerdown="panStart" @pointermove="panMove" @pointerup="panEnd" @pointercancel="cancelStroke">
          <div v-if="!project && initialized" class="welcome">
            <div v-if="!newDialog" class="welcome-content"><NewCanvas :language="language" :disabled="busy" :error="newCanvasError" @create="create" @open="open" @image="importImage"/><div class="welcome-secondary"><button class="text-button" :disabled="busy" @click="importPSD">{{ t.editor.importPSD }}</button><button class="text-button" :disabled="busy" data-testid="recover" @click="recover">{{ t.editor.recover }}</button></div></div>
          </div>
          <div v-else-if="project && source!=='none'" class="canvas-surround" :style="{minWidth:project.manifest.width * zoom + 80 + 'px',minHeight:project.manifest.height * zoom + 80 + 'px'}">
            <div ref="artboard" class="artboard" :class="'tool-'+tool" :style="{width:project.manifest.width * zoom + 'px',height:project.manifest.height * zoom + 'px'}">
              <canvas v-if="source==='engine'" ref="canvas" data-testid="rendered-canvas"></canvas>
              <canvas v-if="source==='engine'" ref="overlay" class="paint-overlay"></canvas>
              <div v-if="source==='engine' && full.options.grid" class="grid-overlay" :style="gridStyle"></div>
              <svg v-if="source==='engine'" class="geometry-overlay" :viewBox="'0 0 '+project.manifest.width+' '+project.manifest.height" :style="{width:'100%',height:'100%'}">
                <line v-for="g in project.manifest.guides??[]" :key="g.id" :x1="g.axis==='vertical'?g.position:0" :x2="g.axis==='vertical'?g.position:project.manifest.width" :y1="g.axis==='horizontal'?g.position:0" :y2="g.axis==='horizontal'?g.position:project.manifest.height" stroke="#71dfed" :stroke-width="1/zoom"/>
                <g v-if="tool==='move' && selected && full.selectionTransform" :transform="'translate('+((full.selectionTransform??selected.transform).origin[0]+(full.selectionTransform??selected.transform).size[0]/2)+','+((full.selectionTransform??selected.transform).origin[1]+(full.selectionTransform??selected.transform).size[1]/2)+') rotate('+(full.selectionTransform??selected.transform).rotation+') translate('+(-(full.selectionTransform??selected.transform).size[0]/2)+','+(-(full.selectionTransform??selected.transform).size[1]/2)+')'">
                  <rect x="0" y="0" :width="(full.selectionTransform??selected.transform).size[0]" :height="(full.selectionTransform??selected.transform).size[1]" fill="none" stroke="#99d7ed" :stroke-width="1/zoom"/>
                  <rect data-handle="resize" :x="(full.selectionTransform??selected.transform).size[0]-5/zoom" :y="(full.selectionTransform??selected.transform).size[1]-5/zoom" :width="10/zoom" :height="10/zoom" class="transform-handle" :aria-label="full.labels.resize"/>
                  <circle data-handle="rotate" :cx="(full.selectionTransform??selected.transform).size[0]/2" :cy="-20/zoom" :r="5/zoom" class="transform-handle" :aria-label="full.labels.rotate"/>
                </g>
              </svg>
              <img v-else :key="project.id" :src="previewURL" :alt="t.saved" draggable="false" data-testid="saved-preview" @error="savedPreviewFailed">
              <Rulers v-if="source==='engine'&&full.options.rulers" :language="language" :width="project.manifest.width" :height="project.manifest.height" :zoom="zoom" :resolution="project.manifest.resolution??72" :unit="full.options.rulerUnit" :viewport="navigationViewport" :disabled="!editable" :owner="{id:project.id,revision:project.revision}" @gesture="painting=$event" @guide="rulerGuide"/>
            </div>
          </div>
          <p v-else-if="initialized" class="no-preview">{{ t.noPreview }}</p><p v-else class="no-preview" role="status">{{ui.loading}}</p>
        </div>
        <div class="floating-widgets" @pointerdown.stop @wheel.stop>
          <NavigatorPanel v-if="project&&source==='engine'&&full.options.navigator" :language="language" :source="canvas" :width="project.manifest.width" :height="project.manifest.height" :zoom="zoom" :revision="project.revision" :busy="busy||painting||frameRendering||animationPlaying" :viewport="navigationViewport" @close="full.options.navigator=false" @navigate="navigate" @zoom="setZoom"/>
          <PalettePanel v-if="full.options.palette" :language="language" :color="color" :background="full.background" :swatches="swatches" :disabled="painting||busy||animationPlaying" @color="color=$event" @background="full.background=$event" @swatches="swatches=$event" @close="full.options.palette=false"/>
        </div>
      </section>
      <aside v-show="showsInspector" id="project-inspector" :aria-label="chrome.inspector">
        <section class="layers-panel">
          <div class="panel-heading"><strong>{{ t.layers }}</strong><span class="layer-count">{{ project?.analysis.rows.length ?? 0 }}</span><button class="icon-button" :disabled="!project" :aria-label="ui.search" :title="ui.search" :aria-expanded="searchOpen" data-testid="toggle-layer-search" @click="toggleSearch"><Icon name="search"/></button></div>
          <div v-if="project" class="layer-appearance">
            <label class="blend-control"><span class="sr-only">{{ t.editor.blend }}</span><select :value="selected?.blendMode ?? 'Normal'" :disabled="!selected || !editable || selected.isGroup" data-testid="blend-mode" @change="edit({kind:'appearance',field:'blendMode',value:($event.target as HTMLSelectElement).value})"><option v-for="(mode,i) in BLEND_MODES" :key="mode" :value="mode">{{ t.blends[i] }}</option></select></label>
            <label class="opacity-control">{{ t.editor.opacity }}<span class="unit-field"><input type="number" min="0" max="100" :value="Math.round((selected?.opacity ?? 1) * 100)" :disabled="!selected || !editable" data-testid="layer-opacity" @change="edit({kind:'appearance',field:'opacity',value:numberEvent($event)/100})"><span>%</span></span></label>
            <input class="opacity-slider" type="range" min="0" max="100" :value="Math.round((selected?.opacity ?? 1) * 100)" :disabled="!selected || !editable" :aria-label="ui.opacitySlider" @change="edit({kind:'appearance',field:'opacity',value:numberEvent($event)/100})">
          </div>
          <div v-if="project && searchOpen" class="layer-search"><Icon name="search"/><input v-model="query" :placeholder="t.search" :aria-label="t.search" maxlength="256" data-testid="layer-search"><button v-if="query" class="icon-button" :aria-label="t.clearSearch" @click="query=''"><Icon name="close"/></button></div>
          <div class="layer-list">
            <div v-if="!project || !rows.length" class="layer-empty"><Icon :name="query?'search':'layer'"/><p>{{ !project ? t.empty : query ? t.noMatches : ui.noLayers }}</p></div>
            <div v-for="row in rows" :key="row.id" class="layer-row" :class="{selected:full.ids.includes(row.id),hidden:!row.effectiveVisible}" :style="{paddingLeft:6 + row.depth * 12 + 'px'}">
              <button class="icon-button visibility-toggle" :disabled="!editable" :title="(row.isVisible ? ui.hideLayer : ui.showLayer) + ' · ' + row.name" :aria-label="(row.isVisible ? ui.hideLayer : ui.showLayer) + ' · ' + row.name" @click="edit({kind:'appearance',id:row.id,field:'isVisible',value:!row.isVisible})"><Icon :name="row.isVisible?'eye':'eyeOff'"/></button>
              <button v-if="row.isGroup" class="icon-button fold" :disabled="!!query.trim()" :aria-label="collapsed.has(row.id.toUpperCase()) && !query.trim() ? t.expand : t.collapse" :aria-expanded="!!query.trim() || !collapsed.has(row.id.toUpperCase())" @click="toggleGroup(row)"><Icon name="chevron"/></button><span v-else class="fold-spacer"></span>
              <button class="layer-select" :disabled="painting||busy||frameRendering||animationPlaying" :aria-pressed="selected?.id===row.id" @click="selectLayer(row,$event)">
                <span class="thumbnail"><img v-if="row.imageFile" :src="thumbURL(row)" alt="" loading="lazy" draggable="false"><Icon v-else :name="row.isGroup?'folder':'adjustment'"/></span>
                <span class="layer-title">{{ row.name }}<small>{{ kind(row) }}<span v-if="row.maskSourceID"> · {{ t.editor.clip }}</span></small></span>
              </button>
              <button v-if="row.maskFile" class="mask-thumbnail thumbnail" :class="{active:selected?.id===row.id && paintTarget==='mask'}" :title="ui.maskThumbnail + ' · ' + row.name" :aria-label="ui.maskThumbnail + ' · ' + row.name" :disabled="painting||busy||frameRendering||animationPlaying" @click="selectLayer(row,$event,'mask')"><img :src="thumbURL(row,true)" alt="" loading="lazy" draggable="false"></button>
            </div>
          </div>
          <div class="layer-actions">
            <button class="icon-button" :disabled="!editable" :title="t.editor.addPixels" :aria-label="t.editor.addPixels" data-testid="add-pixels" @click="add('pixels')"><Icon name="layer"/></button>
            <button class="icon-button" :disabled="!editable" :title="t.editor.addGroup" :aria-label="t.editor.addGroup" @click="add('group')"><Icon name="folder"/></button>
            <button class="icon-button" :disabled="!editable || !selected || !!selected.maskFile" :title="t.editor.addMask" :aria-label="t.editor.addMask" data-testid="add-mask" @click="edit({kind:'mask',action:'add'})"><Icon name="mask"/></button>
            <label class="adjustment-picker"><Icon name="adjustment"/><select :disabled="!editable" :aria-label="t.editor.addAdjustment" value="" @change="add('adjustment',($event.target as HTMLSelectElement).value)"><option value="">{{ t.editor.addAdjustment }}</option><option v-for="(kind,i) in ADJUSTMENTS" :key="kind" :value="kind">{{ t.adjustments[i] }}</option></select></label>
            <button class="icon-button" :disabled="!editable || !selected" :title="t.editor.delete" :aria-label="t.editor.delete" data-testid="delete-layer" @click="full.remove()"><Icon name="trash"/></button>
          </div>
        </section>
        <section class="inspector-panel">
          <div class="inspector-tabs" role="tablist" @keydown="tabKey">
            <button v-for="tab in ['properties','adjustments','effects']" :key="tab" role="tab" :tabindex="inspectorTab===tab?0:-1" :aria-selected="inspectorTab===tab" :aria-controls="'panel-'+tab" :class="{active:inspectorTab===tab}" :id="'tab-'+tab" @click="inspectorTab=tab">{{ ui[tab as 'properties'|'adjustments'|'effects'] }}</button>
          </div>
          <div class="inspector" role="tabpanel" :id="'panel-'+inspectorTab" :aria-labelledby="'tab-'+inspectorTab">
            <template v-if="selected && inspectorTab==='properties'">
              <div class="parameter-form">
                <label>{{ t.editor.rename }}<input :value="selected.name" maxlength="256" :disabled="busy || painting" data-testid="layer-name" @change="edit({kind:'rename',name:($event.target as HTMLInputElement).value})"></label>
                <details class="property-section" open><summary>{{ ui.transform }}</summary><div class="transform-grid">
                  <label v-for="(key,i) in ['X','Y']" :key="key">{{ key }}<input type="number" :value="(full.selectionTransform??selected.transform).origin[i]" :disabled="!editable" @change="transformPair('origin',i,$event)"></label>
                  <label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="key">{{ key }}<input type="number" min="1" max="300000" :value="(full.selectionTransform??selected.transform).size[i]" :disabled="!editable" @change="transformPair('size',i,$event)"></label>
                  <label>{{ t.editor.rotation }}<input type="number" :value="(full.selectionTransform??selected.transform).rotation" :disabled="!editable" @change="edit({kind:'transform',field:'rotation',value:numberEvent($event)})"></label>
                  <div class="button-row"><button class="icon-button" :disabled="!editable" :title="t.editor.flipH" :aria-label="t.editor.flipH" @click="edit({kind:'transform',field:'flipX',value:!(full.selectionTransform??selected.transform).flipX})"><Icon name="flipH"/></button><button class="icon-button" :disabled="!editable" :title="t.editor.flipV" :aria-label="t.editor.flipV" @click="edit({kind:'transform',field:'flipY',value:!(full.selectionTransform??selected.transform).flipY})"><Icon name="flipV"/></button></div>
                </div></details>
                <details class="property-section"><summary>{{ ui.structure }}</summary>
                  <label>{{ t.editor.parent }}<select :disabled="!editable" :value="selected.parentID ?? ''" @change="edit({kind:'parent',parentID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.root }}</option><option v-for="g in project?.analysis.rows.filter(l=>l.isGroup && l.id!==selected?.id)" :key="g.id" :value="g.id">{{ g.name }}</option></select></label>
                  <label v-if="!selected.isGroup">{{ t.editor.clip }}<select :disabled="!editable" :value="selected.maskSourceID ?? ''" data-testid="clip-source" @change="edit({kind:'clip',sourceID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.none }}</option><option v-for="l in project?.analysis.rows.filter(l=>!l.isGroup && l.imageFile && l.id!==selected?.id && l.parentID?.toUpperCase()===selected?.parentID?.toUpperCase())" :key="l.id" :value="l.id">{{ l.name }}</option></select></label>
                  <div class="button-row"><button :disabled="!editable" @click="full.duplicate()"><Icon name="duplicate"/>{{ t.editor.duplicate }}</button><button class="icon-button" :disabled="!editable" :title="t.editor.up" :aria-label="t.editor.up" @click="edit({kind:'reorder',direction:1})"><Icon name="up"/></button><button class="icon-button" :disabled="!editable" :title="t.editor.down" :aria-label="t.editor.down" @click="edit({kind:'reorder',direction:-1})"><Icon name="down"/></button></div>
                </details>
                <details v-if="selected.maskFile" class="property-section" open><summary>{{ ui.mask }}</summary><div class="mask-flags"><label><input type="checkbox" :checked="selected.maskEnabled!==false" :disabled="!editable" @change="edit({kind:'mask',action:'toggle'})">{{ t.editor.enableMask }}</label><label><input type="checkbox" :checked="selected.maskLinked!==false" :disabled="!editable" @change="edit({kind:'mask',action:'link',value:($event.target as HTMLInputElement).checked})">{{ t.editor.linkMask }}</label></div><div class="button-row"><button :disabled="!editable" data-testid="invert-mask" @click="edit({kind:'mask',action:'invert'})">{{ t.editor.invertMask }}</button><button :disabled="!editable" @click="edit({kind:'mask',action:'remove'})">{{ t.editor.removeMask }}</button></div><div v-if="selected.maskLinked===false" class="transform-grid"><label v-for="(key,i) in ['X','Y']" :key="'mask'+key">{{ key }}<input type="number" :value="(selected.maskPlacement??selected.transform).origin[i]" :disabled="!editable" @change="edit({kind:'transformMask',field:'origin',value:(selected.maskPlacement??selected.transform).origin.map((v,n)=>n===i?numberEvent($event):v)})"></label><label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="'mask'+key">{{ key }}<input type="number" min="1" :value="(selected.maskPlacement??selected.transform).size[i]" :disabled="!editable" @change="edit({kind:'transformMask',field:'size',value:(selected.maskPlacement??selected.transform).size.map((v,n)=>n===i?numberEvent($event):v)})"></label><label>{{ t.editor.rotation }}<input type="number" :value="(selected.maskPlacement??selected.transform).rotation" :disabled="!editable" @change="edit({kind:'transformMask',field:'rotation',value:numberEvent($event)})"></label></div></details>
              </div>
              <CompleteControls :e="full" mode="panel" :tool="tool" :disabled="!editable" :selected="selected" :color="color" :size="brushSize" :opacity="brushOpacity" :target="paintTarget" @edit="edit($event)"/>
              <small v-if="selected.text || selected.shape" class="muted">{{ t.editor.rasterize }}</small>
              <p v-if="!editable && !busy" class="muted">{{ t.editor.readOnly }}</p>
            </template>
            <template v-else-if="selected?.adjustment && inspectorTab==='adjustments'"><h2>{{ t.adjustments[ADJUSTMENTS.indexOf(selected.adjustment.kind)] }}</h2><AdjustmentEditor :value="selected.adjustment" :zh="language==='zh-Hans'" :disabled="!editable" @edit="edit({kind:'adjustment',...$event})"/></template>
            <template v-else-if="selected?.imageFile && inspectorTab==='effects'"><select class="effect-picker" :disabled="!editable" value="" :aria-label="t.editor.addEffect" @change="edit({kind:'effect',effect:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.addEffect }}</option><option v-for="(effect,i) in EFFECTS" :key="effect" :value="effect">{{ t.effects[i] }}</option></select><EffectEditor :value="selected.effects ?? {}" :zh="language==='zh-Hans'" :disabled="!editable" :names="t.effects" @edit="edit({kind:'effect',...$event})"/></template>
            <p v-else class="inspector-empty"><Icon :name="inspectorTab==='effects'?'effects':inspectorTab==='adjustments'?'adjustment':'layer'"/>{{ inspectorTab==='effects'?ui.selectPixels:inspectorTab==='adjustments'?ui.selectAdjustment:ui.selectLayer }}</p>
          </div>
        </section>
      </aside>
    </main>
    <AnimationTimeline v-if="project" :language="language" :track="project.manifest.animation" :active="activeFrameID" :disabled="!editable" :playing="animationPlaying" @frame="seekFrame" @play="playAnimation" @edit="edit" @export="exportImage('gif')"/>
    <div class="statusbar">
      <span class="canvas-status">{{ busy ? ui.loading : project ? Math.round(zoom*100) + '%' : ui.transparent }}</span>
      <span v-if="project">{{ project.manifest.width.toLocaleString() }} × {{ project.manifest.height.toLocaleString() }} px · sRGB</span>
      <span class="preview-status" v-if="project">{{ source==='engine'?ui.livePreview:source==='saved'?ui.savedPreview:ui.metadataOnly }}</span>
      <span role="status">{{ status }}</span>
      <span v-if="project?.selection">{{ full.labels.selection }}</span>
      <span class="badge">{{ t.readonly }} · {{ project?.dirty?t.editor.unsaved:t.editor.saved }} · {{ version }}</span>
    </div>
    <AiPanel v-model:settings-open="assistantSettingsOpen" :language="language" :project="project" :busy="busy" :editable="editable" :edit="submitEdit" :history="history"/>
    <CompleteControls :e="full" mode="dialogs" :tool="tool" :disabled="!editable" :selected="selected" :color="color" :size="brushSize" :opacity="brushOpacity" :target="paintTarget"/>
    <ColorRangeDialog v-if="structuredDialog==='range' && rangePNG" :language="language" :png="rangePNG" :apply="applyColorRange" @running="painting=$event" @close="closeColorRange"/>
    <BatchExportDialog v-if="structuredDialog==='batch' && project" :language="language" :project="project" :selected="full.ids" @running="painting=$event" @close="structuredDialog=''"/>
    <OutputDialog v-if="outputDialog && project" :language="language" :project="project" :get-composite="outputComposite" :export-file="(type,options)=>exportImage(type,false,options)" @close="outputDialog=false"/>
    <RecentDialog v-if="structuredDialog==='recent'" :language="language" :state="recentState" :update="recentSettings" @close="structuredDialog=''" @update="recentState=$event" @open="openRecent"/>
    <ViewSettingsDialog v-if="structuredDialog==='viewSettings'" :language="language" :settings="viewState()" @close="structuredDialog=''" @apply="confirmViewSettings"/>
    <CommandDialog v-if="structuredDialog==='commands'" :language="language" :commands="finderCommands" @close="structuredDialog=''" @run="runCommand"/>
    <HistoryDialog v-if="structuredDialog==='history' && project" :language="language" :project="project" :busy="busy" @close="structuredDialog=''" @jump="jumpHistory"/>
    <DistortDialog v-if="structuredDialog==='distort' && project" :language="language" :project="project" :ids="distortIDs" :target="distortTarget" :commit="refineCommit" @running="painting=$event" @close="structuredDialog=''"/>
    <EdgeRefinementDialog v-if="structuredDialog==='refine' && project && structuredLayer" :language="language" :project="project" :layer="structuredLayer" :commit="refineCommit" @running="painting=$event" @close="structuredDialog=''"/>
    <FilterStackDialog v-if="structuredDialog==='stack' && project && structuredLayer" :language="language" :project="project" :layer="structuredLayer" :initial-liquify="stackLiquify" :commit="submitEdit" @close="structuredDialog=''"/>
    <FillDialog v-if="structuredDialog==='fill' && project" :language="language" :project="project" :layer="structuredLayer" :editing="structuredEditing" :commit="submitEdit" @close="structuredDialog=''"/>
    <PathDialog v-if="['path','mask'].includes(structuredDialog) && project" :language="language" :project="project" :layer="structuredLayer" :editing="structuredEditing" :mode="structuredDialog==='mask'?'mask':'path'" :commit="submitEdit" @close="structuredDialog=''"/>
    <div v-if="newDialog" class="modal-shade" @click.self="newDialog=false"><NewCanvas modal :language="language" :disabled="busy" :error="newCanvasError" @create="create" @close="newDialog=false"/></div>
    <div v-if="psdDialog" class="modal-shade" @click.self="psdDialog=false"><div class="dialog" role="dialog" aria-modal="true" :aria-label="t.editor.conversion"><h2>{{ t.editor.conversion }}</h2><p>{{ t.editor.conversionNote }}</p><p v-if="project?.manifest.animation">{{ language==='en'?'PSD keeps frame folders with current visibility. Save .comp or GIF to retain animation timing.':'PSD 保留帧文件夹和当前帧的可见性。动画时长请保存在 .comp 或 GIF 中。' }}</p><div class="button-row"><button @click="psdDialog=false">{{ t.editor.cancel }}</button><button :disabled="!layeredPSD || !editable" @click="exportImage('psd')">{{ t.editor.layered }}</button><button :disabled="!editable" class="primary" @click="exportImage('psd',true)">{{ t.editor.flattened }}</button></div></div></div>
    <div v-if="detailsDialog" class="modal-shade" @click.self="detailsDialog=false"><section class="dialog details-dialog" role="dialog" aria-modal="true" :aria-label="ui.details"><div class="dialog-heading"><h2>{{ ui.details }}</h2><button class="icon-button" :aria-label="t.close" @click="detailsDialog=false"><Icon name="close"/></button></div><p>{{ t.sourceNote }}</p><p>{{ t.readonly }} · {{ version }}</p><template v-if="project"><p>{{ ui.source }}：{{ source==='engine'?t.engine:source==='saved'?t.saved:t.metadata }}</p><section class="coverage"><h3>{{ t.coverage }}</h3><dl><div><dt>{{ t.simple }}</dt><dd>{{ project.analysis.coverage.simple }}</dd></div><div><dt>{{ t.pixels }}</dt><dd>{{ project.analysis.coverage.pixelFallback }}</dd></div><div><dt>{{ t.preview }}</dt><dd>{{ project.analysis.coverage.previewOnly }}</dd></div></dl><p>{{ t.coverageNote }}</p><button :disabled="busy" data-testid="copy-report" @click="copyReport">{{ t.copyReport }}</button><small>{{ t.reportPrivacy }}</small><small v-if="reportState!=='idle'" role="status">{{ reportState==='copied'?t.reportCopied:t.reportError }}</small></section><details v-if="selected" class="raw-properties"><summary>{{ t.properties }}</summary><pre>{{ formattedProperties }}</pre></details></template><div class="button-row"><button class="primary" @click="detailsDialog=false">{{ t.close }}</button></div></section></div>
  </div>
</template>

<style>
.external-notice{display:flex;align-items:center;gap:8px}.external-notice>span{flex:1}.navigation-workarea{position:relative}.floating-widgets{position:absolute;z-index:7;right:12px;top:12px;max-height:calc(100% - 24px);overflow:auto;display:flex;flex-direction:column;gap:10px;pointer-events:none}.floating-panel{pointer-events:auto;background: var(--panel,#242424);border: 1px solid var(--border);border-radius: 6px;padding:8px;box-shadow: 0 6px 20px var(--shadow)}.floating-panel>header{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}.floating-panel>header .icon-button{width:22px;height:22px;min-height:22px}.ruler-guide line{stroke:#71dfed}
</style>
