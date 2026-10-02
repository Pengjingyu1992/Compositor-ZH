<script setup lang="ts">
import { computed, ref, reactive, onMounted, onUnmounted, nextTick, watch } from 'vue';
import { messages } from '../../../packages/locales';
import { createPreviewRenderer, pngBytes, exportPlaced, makeCanvas } from '../../../packages/editor-adapter/render';
import { BLEND_MODES, ADJUSTMENT_KINDS as ADJUSTMENTS, EFFECT_KINDS as EFFECTS } from '../../../packages/comp-bridge/capabilities.mjs';
import AdjustmentEditor from './AdjustmentEditor.vue';
import EffectEditor from './EffectEditor.vue';
import Icon from './Icon.vue';
import CompleteControls from './CompleteControls.vue';
import { useCompleteEditor, TOOL_LIST, TOOL_KEYS } from './useCompleteEditor';
import { visibleLayers } from '../../../packages/editor-adapter/layer-list';
import type { Language, ViewerProject, OpenResult, LayerRow } from './types';

const language = ref<Language>('zh-Hans'), version = ref(''), project = ref<ViewerProject>();
const iconURL = 'compositor://app/icon.png';
const selected = ref<LayerRow>(), busy = ref(false), error = ref(''), settingError = ref(false);
const query = ref(''), collapsed = ref(new Set<string>()), dropping = ref(false), reportState = ref<'idle' | 'copied' | 'error'>('idle');
const stage = ref<HTMLDivElement>(), canvas = ref<HTMLCanvasElement>(), zoom = ref(1);
const source = ref<'engine' | 'saved' | 'none'>('none'), extraIssues = ref<string[]>([]);
const tool=ref('pan'),color=ref('#bae9d6'),brushSize=ref(24),brushOpacity=ref(100),paintTarget=ref('content');
const newDialog=ref(false),newWidth=ref(1920),newHeight=ref(1080),psdDialog=ref(false),status=ref(''),painting=ref(false);
const overlay=ref<HTMLCanvasElement>(),artboard=ref<HTMLDivElement>();
const inspectorTab=ref('properties'), detailsDialog=ref(false), searchOpen=ref(false);
const tools=TOOL_LIST,toolKeys=TOOL_KEYS;
const ui = computed(() => t.value.workspace);
const thumbURL = (row: LayerRow, mask=false) => project.value?.urls[`images/${mask ? row.maskFile : row.imageFile}`];
function selectLayer(row: LayerRow,event?:MouseEvent) { full.select(row,event); inspectorTab.value=row.adjustment?'adjustments':'properties'; }
function showEffects() { if(selected.value?.imageFile)inspectorTab.value='effects'; }
function showDetails() { detailsDialog.value=true; }
function toggleSearch() { searchOpen.value=!searchOpen.value; if(!searchOpen.value)query.value=''; }
let returnFocus: HTMLElement | null = null;
watch(() => newDialog.value || psdDialog.value || detailsDialog.value || full.modal, async visible => {
  if (visible) {
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    await nextTick();
    if (newDialog.value || psdDialog.value || detailsDialog.value || full.modal) document.querySelector<HTMLElement>('.modal-shade:last-of-type input, .modal-shade:last-of-type button')?.focus();
  } else if (returnFocus?.isConnected) returnFocus.focus();
});
function tabKey(event: KeyboardEvent) {
  if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
  event.preventDefault();
  const tabs = ['properties','adjustments','effects'], i=tabs.indexOf(inspectorTab.value);
  inspectorTab.value = tabs[event.key==='Home'?0:event.key==='End'?2:(i+(event.key==='ArrowRight'?1:2))%3];
  nextTick(() => document.getElementById('tab-'+inspectorTab.value)?.focus());
}
const editable=computed(()=>!!project.value&&!busy.value&&!painting.value&&source.value==='engine'&&!issues.value.length);
const t = computed(() => messages[language.value]);
const issues = computed(() => [...(project.value?.analysis.issues ?? []), ...extraIssues.value]);
const rows = computed(() => visibleLayers(project.value?.analysis.rows ?? [], query.value, collapsed.value));
const previewURL = computed(() => project.value?.urls['QuickLook/Preview.jpg']);
const formattedProperties = computed(() => {
  if (!selected.value || !project.value) return '';
  const original = project.value.manifest.layers.find(l => l.id === selected.value?.id);
  return JSON.stringify(original, null, 2);
});
let renderer: ReturnType<typeof createPreviewRenderer> | undefined, epoch = 0, operation = 0, requests = 0, dragDepth = 0;
const subscriptions: (() => void)[] = [];
function fit() {
  if (project.value && stage.value) zoom.value = Math.min(8, Math.max(.01, Math.min((stage.value.clientWidth - 80) / project.value.manifest.width, (stage.value.clientHeight - 80) / project.value.manifest.height)));
}
function scale(factor: number) { zoom.value = Math.max(.01, Math.min(8, zoom.value * factor)); }
function labelIssue(key: string) { return t.value.issues[key as keyof typeof t.value.issues] ?? key; }
function labelError(key: string) { if(['locked','selection','source','limit'].includes(key))return key==='selection'?full.labels.noSelection:key==='source'?full.labels.sourceNeeded:full.labels[key as 'locked'|'limit']; return t.value.errors[key as keyof typeof t.value.errors] ?? t.value.errors.read; }
function kind(row: LayerRow) { return row.isGroup ? t.value.group : row.adjustment ? t.value.adjustment : row.text ? t.value.text : row.shape ? t.value.shape : t.value.raster; }
function fallback() { renderer?.dispose(); renderer = undefined; source.value = project.value?.preview ? 'saved' : 'none'; }
async function accept(result: OpenResult) {
  if (result.error) { error.value = result.error; return; }
  if (result.exported) status.value=t.value.editor.exported;
  if (result.warnings?.length) status.value=result.warnings.map(k=>t.value.editor[k as keyof typeof t.value.editor]??k).join(' · ');
  if (!result.project) return;
  const same=project.value?.id===result.project.id, selectedID=selected.value?.id, previousZoom=zoom.value,oldActive=(project.value?.manifest as any)?.activeLayerID,newActive=(result.project.manifest as any).activeLayerID;
  const own = ++epoch;
  renderer?.dispose(); renderer = undefined;
  project.value = result.project; selected.value = result.project.analysis.rows.find(l=>l.id===(newActive!==oldActive?newActive:same?selectedID:undefined)); error.value = ''; extraIssues.value = [];
  if(!same){query.value = ''; searchOpen.value=false; collapsed.value = new Set(); status.value='';}
  if(newActive!==oldActive && selected.value)inspectorTab.value=selected.value.adjustment?'adjustments':'properties';reportState.value = 'idle';
  if(result.backup)status.value=t.value.editor.backup;
  source.value = project.value.analysis.issues.length ? (project.value.preview ? 'saved' : 'none') : 'engine';
  await nextTick(); if(same)zoom.value=previousZoom;else fit();
  if (epoch !== own || project.value?.id !== result.project.id) return;
  if (source.value === 'engine' && canvas.value) {
    try {
      const preview = createPreviewRenderer(); renderer = preview;
      await preview.render(project.value, canvas.value, () => {
        if (epoch !== own) return;
        extraIssues.value = ['gpu']; fallback();
      });
    } catch (e) {
      console.warn('Preview failed', (e as Error).name, (e as Error).message);
      if (epoch !== own) return;
      extraIssues.value = [(e as Error).message === 'asset' ? 'asset' : 'gpu']; fallback();
    }
  }
}
async function request(action: () => Promise<OpenResult>): Promise<void> {
  if (busy.value) return;
  const own = ++operation;
  requests++; busy.value = true; reportState.value = 'idle';
  try { const result = await action(); if (operation === own) await accept(result); }
  catch { if (operation === own) error.value = 'read'; }
  finally { requests--; busy.value = requests > 0; }
}
function open() { return request(() => window.viewer.open()); }
function reload() { const id = project.value?.id; if (id) return request(() => window.viewer.reload(id)); }
async function closeProject() {
  const result=await window.viewer.close();if(!result.closed){if(result.error)error.value=result.error;return;}
  operation++; epoch++; renderer?.dispose(); renderer = undefined;
  drag = undefined;
  project.value = undefined; selected.value = undefined; source.value = 'none'; error.value = ''; extraIssues.value = [];
  query.value = ''; collapsed.value = new Set(); reportState.value = 'idle';
}
function edit(op:Record<string,unknown>){const p=project.value;if(!p||busy.value)return;return request(()=>window.editor.edit(p.id,p.revision,{id:selected.value?.id,...op}));}
function history(direction:string){const p=project.value;if(p)return request(()=>window.editor.history(p.id,p.revision,direction));}
function save(as=false){const p=project.value;if(p)return request(()=>window.editor.save(p.id,p.revision,as));}
function importImage(): Promise<void> | undefined {const p=project.value;if(p)return request(()=>window.editor.importImage(p.id,p.revision));}
function importPSD(){return request(()=>window.editor.importPSD());}
function recover(){return request(()=>window.editor.recover());}
function add(type:string,adjustment?:string){return edit({kind:'add',type,adjustment,name:type==='group'?t.value.editor.group:type==='adjustment'?t.value.adjustments[ADJUSTMENTS.indexOf(adjustment!)]:t.value.raster,parentID:selected.value?.isGroup?selected.value.id:selected.value?.parentID});}
function numberEvent(e:Event){return Number((e.target as HTMLInputElement).value);}
function transformPair(field:'origin'|'size',index:number,e:Event){if(!selected.value)return;const value=[...selected.value.transform[field]];value[index]=numberEvent(e);return edit({kind:'transform',field,value});}
async function create(){newDialog.value=false;await request(()=>window.editor.create(newWidth.value,newHeight.value));}
async function exportImage(type:string,flatten=false){
  const p=project.value,c=canvas.value;if(!p||!c||source.value!=='engine')return;psdDialog.value=false;
  await request(async()=>{
    const composite=await pngBytes(c),layers:{id:string;image:Uint8Array;left:number;top:number}[]=[],masks:{id:string;image:Uint8Array;left:number;top:number}[]=[];
    if(type==='psd'&&!flatten){
      if(p.manifest.layers.filter(l=>l.imageFile).length*p.manifest.width*p.manifest.height*8>512*1024**2)return {error:'limit'};
      for(const l of p.manifest.layers){
        if(l.imageFile)layers.push({id:l.id,...await exportPlaced(p.urls[`images/${l.imageFile}`],l.transform)});
        if(l.maskFile)masks.push({id:l.id,...await exportPlaced(p.urls[`images/${l.maskFile}`],l.maskLinked===false&&l.maskPlacement?l.maskPlacement:l.transform)});
      }
    }
    return window.editor.export(p.id,p.revision,type,{composite,layers,masks,flatten});
  });
}
const layeredPSD=computed(()=>project.value&&!project.value.manifest.layers.some(l=>l.adjustment||l.effects&&Object.values(l.effects).some(e=>e.enabled!==false)));
function dragEnter(event: DragEvent) {
  if (event.dataTransfer?.types.includes('Files')) { dragDepth++; dropping.value = true; }
}
function dragLeave() { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) dropping.value = false; }
function dragOver(event: DragEvent) { if (event.dataTransfer) event.dataTransfer.dropEffect = busy.value ? 'none' : 'copy'; }
function dropProject(event: DragEvent) {
  dragDepth = 0; dropping.value = false;
  if (busy.value) return;
  const files = event.dataTransfer?.files;
  if (!files?.length) return;
  if (files.length !== 1) { error.value = 'drop'; return; }
  return request(() => window.viewer.drop(files[0]));
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
  if (event.key==='Tab' && (newDialog.value || psdDialog.value || detailsDialog.value || full.modal)) {
    const modal=[...document.querySelectorAll<HTMLElement>('.modal-shade')].at(-1);
    const fields=[...(modal?.querySelectorAll<HTMLElement>('button:not([disabled]),input:not([disabled]),select:not([disabled]),summary') ?? [])].filter(e=>e.getClientRects().length);
    const first=fields[0],last=fields.at(-1);
    if(first && ((!event.shiftKey && (document.activeElement===last || !modal?.contains(document.activeElement))) || (event.shiftKey && (document.activeElement===first || !modal?.contains(document.activeElement))))) { event.preventDefault(); (event.shiftKey?last:first)?.focus(); }
  }
  full.key(event);
  const input=(event.target as HTMLElement)?.closest('input,textarea,select,[contenteditable]');
  if(!painting.value&&!input&&!event.ctrlKey&&!event.altKey&&!event.metaKey){const k=event.key.toLowerCase();if(['b','e','v','h'].includes(k))tool.value=({b:'brush',e:'eraser',v:'move',h:'pan'} as Record<string,string>)[k];}
  if(event.key==='Escape'){cancelStroke();newDialog.value=false;psdDialog.value=false;detailsDialog.value=false;}
  if (event.ctrlKey && event.key.toLowerCase() === 'r') { event.preventDefault(); reload(); }
  if (event.ctrlKey && event.key.toLowerCase() === 'w') { event.preventDefault(); closeProject(); }
  if (event.ctrlKey && event.key === '+') { event.preventDefault(); scale(1.25); }
  if (event.ctrlKey && event.key === '-') { event.preventDefault(); scale(.8); }
}
function wheel(event: WheelEvent) { if (event.ctrlKey) { event.preventDefault(); scale(event.deltaY < 0 ? 1.1 : 1 / 1.1); } }
let drag: { x: number; y: number; left: number; top: number } | undefined;
const full=reactive(useCompleteEditor({project,selected,tool,color,brushSize,brushOpacity,paintTarget,painting,editable,language,canvas,overlay,artboard,stage,zoom,error,execute:(op,p=project.value)=>{if(p)return request(()=>window.editor.edit(p.id,p.revision,{id:selected.value?.id,...op}));},receive:result=>request(()=>Promise.resolve(result)),history,scale}));
function cancelStroke(){full.cancel();drag=undefined;}
function panStart(event:PointerEvent){if(full.start(event))return;if(!stage.value||event.button!==0||!project.value)return;drag={x:event.clientX,y:event.clientY,left:stage.value.scrollLeft,top:stage.value.scrollTop};stage.value.setPointerCapture(event.pointerId);}
function panMove(event:PointerEvent){if(full.move(event))return;if(!stage.value||!drag)return;stage.value.scrollLeft=drag.left+drag.x-event.clientX;stage.value.scrollTop=drag.top+drag.y-event.clientY;}
async function panEnd(event:PointerEvent){drag=undefined;await full.end(event);}
onMounted(async () => {
  const settings = await window.viewer.settings(); language.value = settings.language; version.value = settings.version;
  document.documentElement.lang = language.value;
  subscriptions.push(window.viewer.onOpen(open), window.viewer.onReload(reload), window.viewer.onClose(closeProject), window.viewer.onFit(fit), window.viewer.onActual(() => zoom.value = 1));
  const commands: Record<string, () => unknown> = {...full.commands,new:()=>{newDialog.value=true;},image:importImage,importPSD,save:()=>save(),saveAs:()=>save(true),png:()=>exportImage('png'),exportPSD:()=>{psdDialog.value=true;},recover,undo:()=>history('undo'),redo:()=>history('redo'),addPixels:()=>add('pixels'),addGroup:()=>add('group'),addMask:()=>{if(selected.value)edit({kind:'mask',action:'add'});},details:showDetails,properties:()=>{inspectorTab.value='properties';},effects:showEffects};
  for(const [name,action] of Object.entries(commands))subscriptions.push(window.editor.onCommand(name,()=>{if(painting.value)return;if(['copy','cut','paste','selectAll'].includes(name)&&document.activeElement?.closest('input,textarea,[contenteditable]')){void window.editor.textClipboard(name);return;}action();}));
  window.addEventListener('keydown', onKey); window.addEventListener('resize', fit);
});
onUnmounted(() => { operation++; epoch++; cancelStroke();renderer?.dispose(); full.closeModal(); subscriptions.forEach(stop => stop()); window.removeEventListener('keydown', onKey); window.removeEventListener('resize', fit); });
</script>

<template>
  <div class="shell" @dragenter.prevent="dragEnter" @dragover.prevent="dragOver" @dragleave="dragLeave" @drop.prevent="dropProject">
    <div v-if="dropping" class="drop-target" role="status">{{ t.dropHint }}</div>
    <header class="toolbar documentbar">
      <div class="brand"><img :src="iconURL" alt=""><strong>{{ t.title }}</strong></div>
      <div class="document-actions">
        <button class="icon-button" :disabled="busy || painting" :title="t.editor.newCanvas + ' · Ctrl+N'" :aria-label="t.editor.newCanvas" data-testid="new-canvas" @click="newDialog=true"><Icon name="new"/></button>
        <button class="icon-button" :disabled="busy || painting" :title="t.open + ' · Ctrl+O'" :aria-label="t.open" data-testid="open-project" @click="open"><Icon name="open"/></button>
        <button class="icon-button" :disabled="!project || busy || painting" :title="t.editor.save + ' · Ctrl+S'" :aria-label="t.editor.save" data-testid="save-project" @click="save()"><Icon name="save"/></button>
      </div>
      <div class="document-tab" :class="{active:project}">
        <span class="document-name">{{ project?.name ?? ui.noDocument }}<span v-if="project?.dirty" class="dirty-dot" :title="t.editor.unsaved"></span></span>
        <button v-if="project || busy" class="icon-button tab-close" :title="t.close + ' · Ctrl+W'" :aria-label="t.close" data-testid="close-project" :disabled="painting" @click="closeProject"><Icon name="close"/></button>
      </div>
      <div class="history-tools">
        <button class="icon-button" :disabled="!project?.canUndo || busy || painting" :title="t.editor.undo + ' · Ctrl+Z'" :aria-label="t.editor.undo" data-testid="undo" @click="history('undo')"><Icon name="undo"/></button>
        <button class="icon-button" :disabled="!project?.canRedo || busy || painting" :title="t.editor.redo + ' · Ctrl+Shift+Z'" :aria-label="t.editor.redo" data-testid="redo" @click="history('redo')"><Icon name="redo"/></button>
      </div>
      <div class="toolbar-spacer"></div>
      <div class="zoom-tools">
        <button class="icon-button" :disabled="!project" :title="t.fit + ' · Ctrl+0'" :aria-label="t.fit" @click="fit"><Icon name="fit"/></button>
        <button class="icon-button" :disabled="!project" :aria-label="ui.zoomOut" @click="scale(.8)"><Icon name="minus"/></button>
        <button class="zoom-value" :disabled="!project" title="100% · Ctrl+1" @click="zoom=1">{{ Math.round(zoom * 100) }}%</button>
        <button class="icon-button" :disabled="!project" :aria-label="ui.zoomIn" @click="scale(1.25)"><Icon name="plus"/></button>
      </div>
      <select class="language-select" :aria-label="t.language" :value="language" data-testid="language" @change="changeLanguage"><option value="zh-Hans">简体中文</option><option value="en">English</option></select>
      <button class="icon-button" :aria-label="ui.details" :title="ui.details" data-testid="project-details" @click="showDetails"><Icon name="info"/></button>
    </header>
    <div v-if="error || settingError" class="error" role="alert">{{ settingError ? t.settingsError : t.errorTitle + ' · ' + labelError(error) }}<button class="icon-button" :aria-label="t.editor.cancel" @click="error='';settingError=false"><Icon name="close"/></button></div>
    <div class="optionsbar" data-testid="tool-options">
      <span class="tool-heading"><Icon :name="tool"/>{{ t.editor[tool as keyof typeof t.editor] }}</span>
      <template v-if="tool==='move' && selected">
        <label v-for="(key,i) in ['X','Y']" :key="key">{{ key }}<input type="number" :value="selected.transform.origin[i]" :disabled="!editable" @change="transformPair('origin',i,$event)"></label>
        <label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="key">{{ key }}<input type="number" min="1" max="300000" :value="selected.transform.size[i]" :disabled="!editable || selected.isGroup" @change="transformPair('size',i,$event)"></label>
        <label>{{ t.editor.rotation }}<span class="unit-field"><input type="number" :value="selected.transform.rotation" :disabled="!editable || selected.isGroup" @change="edit({kind:'transform',field:'rotation',value:numberEvent($event)})"><span>°</span></span></label>
        <button class="icon-button" :disabled="!editable || selected.isGroup" :title="t.editor.flipH" :aria-label="t.editor.flipH" @click="edit({kind:'transform',field:'flipX',value:!selected.transform.flipX})"><Icon name="flipH"/></button>
        <button class="icon-button" :disabled="!editable || selected.isGroup" :title="t.editor.flipV" :aria-label="t.editor.flipV" @click="edit({kind:'transform',field:'flipY',value:!selected.transform.flipY})"><Icon name="flipV"/></button>
      </template>
      <CompleteControls :e="full" mode="options" :tool="tool" :disabled="busy || painting" :selected="selected" :color="color" :size="brushSize" :opacity="brushOpacity" :target="paintTarget" @size="brushSize=$event" @opacity="brushOpacity=$event" @target="paintTarget=$event"/>
      <span v-if="tool==='pan'" class="tool-hint">{{ tool==='pan' ? ui.panHint : ui.moveHint }}</span>
    </div>
    <main>
      <nav class="toolrail" :aria-label="ui.tools">
        <button v-for="key in tools" :key="key" class="icon-button tool-button" :class="{active:tool===key}" :aria-pressed="tool===key" :disabled="painting || (key!=='pan' && !editable)" :title="(full.labels[key as keyof typeof full.labels] ?? t.editor[key as keyof typeof t.editor]) + ' (' + toolKeys[key] + ')'" :aria-label="full.labels[key as keyof typeof full.labels] ?? t.editor[key as keyof typeof t.editor]" @click="tool=key"><Icon :name="key"/></button>
        <div class="rail-divider"></div>
        <label class="color-swatch" :title="full.labels.foreground"><span :style="{background:color}"></span><input type="color" v-model="color" :aria-label="t.editor.color" :disabled="painting"></label>
        <label class="color-swatch background-swatch" :title="full.labels.background"><span :style="{background:full.background}"></span><input type="color" v-model="full.background" :aria-label="full.labels.background" :disabled="painting"></label>
        <button class="icon-button" :title="full.labels.swap+' (X)'" :aria-label="full.labels.swap" @click="[color,full.background]=[full.background,color]"><Icon name="swap"/></button>
        <button class="icon-button" :title="full.labels.defaults+' (D)'" :aria-label="full.labels.defaults" @click="color='#000000';full.background='#ffffff'"><Icon name="defaults"/></button>
      </nav>
      <section class="workarea">
        <div v-if="issues.length" class="notice">{{ source==='saved' ? t.fallback : t.detailsOnly }} {{ issues.map(labelIssue).join(' · ') }}</div>
        <div ref="stage" class="stage" @wheel="wheel" @pointerdown="panStart" @pointermove="panMove" @pointerup="panEnd" @pointercancel="cancelStroke">
          <div v-if="!project" class="welcome">
            <form @submit.prevent="create">
              <h1>{{ t.editor.newCanvas }}</h1><p>{{ ui.transparent }}</p>
              <div class="new-dimensions"><label>{{ t.editor.width }}<span class="unit-field"><input type="number" v-model.number="newWidth" min="1" max="30000" required><span>px</span></span></label><button class="icon-button" type="button" :aria-label="t.editor.swap" :title="t.editor.swap" @click="[newWidth,newHeight]=[newHeight,newWidth]"><Icon name="swap"/></button><label>{{ t.editor.height }}<span class="unit-field"><input type="number" v-model.number="newHeight" min="1" max="30000" required><span>px</span></span></label></div>
              <div class="welcome-actions"><button type="button" :disabled="busy" @click="open">{{ t.open }}</button><button class="primary" type="submit" :disabled="busy">{{ t.editor.create }}</button></div>
            </form>
            <div class="welcome-secondary"><button class="text-button" :disabled="busy" @click="importPSD">{{ t.editor.importPSD }}</button><button class="text-button" :disabled="busy" data-testid="recover" @click="recover">{{ t.editor.recover }}</button></div>
          </div>
          <div v-else-if="source!=='none'" class="canvas-surround" :style="{minWidth:project.manifest.width * zoom + 80 + 'px',minHeight:project.manifest.height * zoom + 80 + 'px'}">
            <div ref="artboard" class="artboard" :class="'tool-'+tool" :style="{width:project.manifest.width * zoom + 'px',height:project.manifest.height * zoom + 'px'}">
              <canvas v-if="source==='engine'" ref="canvas" data-testid="rendered-canvas"></canvas>
              <canvas v-if="source==='engine'" ref="overlay" class="paint-overlay"></canvas>
              <div v-if="source==='engine' && full.options.grid" class="grid-overlay" :style="{backgroundSize:10*zoom+'px '+10*zoom+'px'}"></div>
              <svg v-if="source==='engine'" class="geometry-overlay" :viewBox="'0 0 '+project.manifest.width+' '+project.manifest.height" :style="{width:'100%',height:'100%'}">
                <line v-for="g in project.manifest.guides??[]" :key="g.id" :x1="g.axis==='vertical'?g.position:0" :x2="g.axis==='vertical'?g.position:project.manifest.width" :y1="g.axis==='horizontal'?g.position:0" :y2="g.axis==='horizontal'?g.position:project.manifest.height" stroke="#71dfed" :stroke-width="1/zoom"/>
                <g v-if="tool==='move' && selected && !selected.isGroup" :transform="'translate('+(selected.transform.origin[0]+selected.transform.size[0]/2)+','+(selected.transform.origin[1]+selected.transform.size[1]/2)+') rotate('+selected.transform.rotation+') translate('+(-selected.transform.size[0]/2)+','+(-selected.transform.size[1]/2)+')'">
                  <rect x="0" y="0" :width="selected.transform.size[0]" :height="selected.transform.size[1]" fill="none" stroke="#99d7ed" :stroke-width="1/zoom"/>
                  <rect data-handle="resize" :x="selected.transform.size[0]-5/zoom" :y="selected.transform.size[1]-5/zoom" :width="10/zoom" :height="10/zoom" class="transform-handle" :aria-label="full.labels.resize"/>
                  <circle data-handle="rotate" :cx="selected.transform.size[0]/2" :cy="-20/zoom" :r="5/zoom" class="transform-handle" :aria-label="full.labels.rotate"/>
                </g>
              </svg>
              <img v-else :key="project.id" :src="previewURL" :alt="t.saved" draggable="false" data-testid="saved-preview" @error="savedPreviewFailed">
            </div>
          </div>
          <p v-else class="no-preview">{{ t.noPreview }}</p>
        </div>
      </section>
      <aside>
        <section class="layers-panel">
          <div class="panel-heading"><strong>{{ t.layers }}</strong><span class="layer-count">{{ project?.analysis.rows.length ?? 0 }}</span><button class="icon-button" :disabled="!project" :aria-label="ui.search" :title="ui.search" :aria-expanded="searchOpen" data-testid="toggle-layer-search" @click="toggleSearch"><Icon name="search"/></button></div>
          <div v-if="project" class="layer-appearance">
            <label class="blend-control"><span class="sr-only">{{ t.editor.blend }}</span><select :value="selected?.blendMode ?? 'Normal'" :disabled="!selected || !editable || selected.isGroup" data-testid="blend-mode" @change="edit({kind:'appearance',field:'blendMode',value:($event.target as HTMLSelectElement).value})"><option v-for="(mode,i) in BLEND_MODES" :key="mode" :value="mode">{{ t.blends[i] }}</option></select></label>
            <label class="opacity-control">{{ t.editor.opacity }}<span class="unit-field"><input type="number" min="0" max="100" :value="Math.round((selected?.opacity ?? 1) * 100)" :disabled="!selected || !editable" data-testid="layer-opacity" @change="edit({kind:'appearance',field:'opacity',value:numberEvent($event)/100})"><span>%</span></span></label>
            <input class="opacity-slider" type="range" min="0" max="100" :value="Math.round((selected?.opacity ?? 1) * 100)" :disabled="!selected || !editable" :aria-label="ui.opacitySlider" @change="edit({kind:'appearance',field:'opacity',value:numberEvent($event)/100})">
          </div>
          <div v-if="project && searchOpen" class="layer-search"><Icon name="search"/><input v-model="query" :placeholder="t.search" :aria-label="t.search" maxlength="256" data-testid="layer-search"><button v-if="query" class="icon-button" :aria-label="t.clearSearch" @click="query=''"><Icon name="close"/></button></div>
          <div class="layer-list">
            <p v-if="!project" class="muted">{{ t.empty }}</p><p v-else-if="!rows.length" class="muted">{{ query ? t.noMatches : ui.noLayers }}</p>
            <div v-for="row in rows" :key="row.id" class="layer-row" :class="{selected:full.ids.includes(row.id),hidden:!row.effectiveVisible}" :style="{paddingLeft:6 + row.depth * 12 + 'px'}">
              <button class="icon-button visibility-toggle" :disabled="!editable" :title="(row.isVisible ? ui.hideLayer : ui.showLayer) + ' · ' + row.name" :aria-label="(row.isVisible ? ui.hideLayer : ui.showLayer) + ' · ' + row.name" @click="edit({kind:'appearance',id:row.id,field:'isVisible',value:!row.isVisible})"><Icon :name="row.isVisible?'eye':'eyeOff'"/></button>
              <button v-if="row.isGroup" class="icon-button fold" :disabled="!!query.trim()" :aria-label="collapsed.has(row.id.toUpperCase()) && !query.trim() ? t.expand : t.collapse" :aria-expanded="!!query.trim() || !collapsed.has(row.id.toUpperCase())" @click="toggleGroup(row)"><Icon name="chevron"/></button><span v-else class="fold-spacer"></span>
              <button class="layer-select" :disabled="painting" :aria-pressed="selected?.id===row.id" @click="selectLayer(row,$event);paintTarget='content'">
                <span class="thumbnail"><img v-if="row.imageFile" :src="thumbURL(row)" alt="" loading="lazy" draggable="false"><Icon v-else :name="row.isGroup?'folder':'adjustment'"/></span>
                <span class="layer-title">{{ row.name }}<small>{{ kind(row) }}<span v-if="row.maskSourceID"> · {{ t.editor.clip }}</span></small></span>
              </button>
              <button v-if="row.maskFile" class="mask-thumbnail thumbnail" :class="{active:selected?.id===row.id && paintTarget==='mask'}" :title="ui.maskThumbnail + ' · ' + row.name" :aria-label="ui.maskThumbnail + ' · ' + row.name" :disabled="painting" @click="selectLayer(row,$event);paintTarget='mask'"><img :src="thumbURL(row,true)" alt="" loading="lazy" draggable="false"></button>
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
                  <label v-for="(key,i) in ['X','Y']" :key="key">{{ key }}<input type="number" :value="selected.transform.origin[i]" :disabled="!editable" @change="transformPair('origin',i,$event)"></label>
                  <label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="key">{{ key }}<input type="number" min="1" max="300000" :value="selected.transform.size[i]" :disabled="!editable || selected.isGroup" @change="transformPair('size',i,$event)"></label>
                  <label>{{ t.editor.rotation }}<input type="number" :value="selected.transform.rotation" :disabled="!editable || selected.isGroup" @change="edit({kind:'transform',field:'rotation',value:numberEvent($event)})"></label>
                  <div class="button-row"><button class="icon-button" :disabled="!editable || selected.isGroup" :title="t.editor.flipH" :aria-label="t.editor.flipH" @click="edit({kind:'transform',field:'flipX',value:!selected.transform.flipX})"><Icon name="flipH"/></button><button class="icon-button" :disabled="!editable || selected.isGroup" :title="t.editor.flipV" :aria-label="t.editor.flipV" @click="edit({kind:'transform',field:'flipY',value:!selected.transform.flipY})"><Icon name="flipV"/></button></div>
                </div></details>
                <details class="property-section"><summary>{{ ui.structure }}</summary>
                  <label>{{ t.editor.parent }}<select :disabled="!editable" :value="selected.parentID ?? ''" @change="edit({kind:'parent',parentID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.root }}</option><option v-for="g in project?.analysis.rows.filter(l=>l.isGroup && l.id!==selected?.id)" :key="g.id" :value="g.id">{{ g.name }}</option></select></label>
                  <label v-if="!selected.isGroup">{{ t.editor.clip }}<select :disabled="!editable" :value="selected.maskSourceID ?? ''" data-testid="clip-source" @change="edit({kind:'clip',sourceID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.none }}</option><option v-for="l in project?.analysis.rows.filter(l=>!l.isGroup && l.imageFile && l.id!==selected?.id && l.parentID?.toUpperCase()===selected?.parentID?.toUpperCase())" :key="l.id" :value="l.id">{{ l.name }}</option></select></label>
                  <div class="button-row"><button :disabled="!editable" @click="full.duplicate()"><Icon name="duplicate"/>{{ t.editor.duplicate }}</button><button class="icon-button" :disabled="!editable" :title="t.editor.up" :aria-label="t.editor.up" @click="edit({kind:'reorder',direction:1})"><Icon name="up"/></button><button class="icon-button" :disabled="!editable" :title="t.editor.down" :aria-label="t.editor.down" @click="edit({kind:'reorder',direction:-1})"><Icon name="down"/></button></div>
                </details>
                <details v-if="selected.maskFile" class="property-section" open><summary>{{ ui.mask }}</summary><div class="mask-flags"><label><input type="checkbox" :checked="selected.maskEnabled!==false" :disabled="!editable" @change="edit({kind:'mask',action:'toggle'})">{{ t.editor.enableMask }}</label><label><input type="checkbox" :checked="selected.maskLinked!==false" :disabled="!editable" @change="edit({kind:'mask',action:'link',value:($event.target as HTMLInputElement).checked})">{{ t.editor.linkMask }}</label></div><div class="button-row"><button :disabled="!editable" data-testid="invert-mask" @click="edit({kind:'mask',action:'invert'})">{{ t.editor.invertMask }}</button><button :disabled="!editable" @click="edit({kind:'mask',action:'remove'})">{{ t.editor.removeMask }}</button></div></details>
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
    <div class="statusbar">
      <span class="canvas-status">{{ busy ? ui.loading : project ? Math.round(zoom*100) + '%' : ui.transparent }}</span>
      <span v-if="project">{{ project.manifest.width.toLocaleString() }} × {{ project.manifest.height.toLocaleString() }} px · sRGB</span>
      <span class="preview-status" v-if="project">{{ source==='engine'?ui.livePreview:source==='saved'?ui.savedPreview:ui.metadataOnly }}</span>
      <span role="status">{{ status }}</span>
      <span v-if="project?.selection">{{ full.labels.selection }}</span>
      <span class="badge">{{ t.readonly }} · {{ project?.dirty?t.editor.unsaved:t.editor.saved }} · {{ version }}</span>
    </div>
    <CompleteControls :e="full" mode="dialogs" :tool="tool" :disabled="!editable" :selected="selected" :color="color" :size="brushSize" :opacity="brushOpacity" :target="paintTarget"/>
    <div v-if="newDialog" class="modal-shade" @click.self="newDialog=false"><form class="dialog" role="dialog" aria-modal="true" :aria-label="t.editor.newCanvas" @submit.prevent="create"><h2>{{ t.editor.newCanvas }}</h2><p>{{ ui.transparent }}</p><div class="new-dimensions"><label>{{ t.editor.width }}<input type="number" v-model.number="newWidth" min="1" max="30000" required></label><button class="icon-button" type="button" :aria-label="t.editor.swap" :title="t.editor.swap" @click="[newWidth,newHeight]=[newHeight,newWidth]"><Icon name="swap"/></button><label>{{ t.editor.height }}<input type="number" v-model.number="newHeight" min="1" max="30000" required></label></div><div class="button-row"><button type="button" @click="newDialog=false">{{ t.editor.cancel }}</button><button class="primary" type="submit">{{ t.editor.create }}</button></div></form></div>
    <div v-if="psdDialog" class="modal-shade" @click.self="psdDialog=false"><div class="dialog" role="dialog" aria-modal="true" :aria-label="t.editor.conversion"><h2>{{ t.editor.conversion }}</h2><p>{{ t.editor.conversionNote }}</p><div class="button-row"><button @click="psdDialog=false">{{ t.editor.cancel }}</button><button :disabled="!layeredPSD || !editable" @click="exportImage('psd')">{{ t.editor.layered }}</button><button :disabled="!editable" class="primary" @click="exportImage('psd',true)">{{ t.editor.flattened }}</button></div></div></div>
    <div v-if="detailsDialog" class="modal-shade" @click.self="detailsDialog=false"><section class="dialog details-dialog" role="dialog" aria-modal="true" :aria-label="ui.details"><div class="dialog-heading"><h2>{{ ui.details }}</h2><button class="icon-button" :aria-label="t.close" @click="detailsDialog=false"><Icon name="close"/></button></div><p>{{ t.sourceNote }}</p><p>{{ t.readonly }} · {{ version }}</p><template v-if="project"><p>{{ ui.source }}：{{ source==='engine'?t.engine:source==='saved'?t.saved:t.metadata }}</p><section class="coverage"><h3>{{ t.coverage }}</h3><dl><div><dt>{{ t.simple }}</dt><dd>{{ project.analysis.coverage.simple }}</dd></div><div><dt>{{ t.pixels }}</dt><dd>{{ project.analysis.coverage.pixelFallback }}</dd></div><div><dt>{{ t.preview }}</dt><dd>{{ project.analysis.coverage.previewOnly }}</dd></div></dl><p>{{ t.coverageNote }}</p><button :disabled="busy" data-testid="copy-report" @click="copyReport">{{ t.copyReport }}</button><small>{{ t.reportPrivacy }}</small><small v-if="reportState!=='idle'" role="status">{{ reportState==='copied'?t.reportCopied:t.reportError }}</small></section><details v-if="selected" class="raw-properties"><summary>{{ t.properties }}</summary><pre>{{ formattedProperties }}</pre></details></template><div class="button-row"><button class="primary" @click="detailsDialog=false">{{ t.close }}</button></div></section></div>
  </div>
</template>
