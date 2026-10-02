<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted, nextTick } from 'vue';
import { messages } from '../../../packages/locales';
import { createPreviewRenderer, pngBytes, exportPlaced, makeCanvas } from '../../../packages/editor-adapter/render';
import { BLEND_MODES, ADJUSTMENT_KINDS as ADJUSTMENTS, EFFECT_KINDS as EFFECTS } from '../../../packages/comp-bridge/capabilities.mjs';
import AdjustmentEditor from './AdjustmentEditor.vue';
import EffectEditor from './EffectEditor.vue';
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
  if (project.value && stage.value) zoom.value = Math.min(1, Math.max(.01, Math.min((stage.value.clientWidth - 80) / project.value.manifest.width, (stage.value.clientHeight - 80) / project.value.manifest.height)));
}
function scale(factor: number) { zoom.value = Math.max(.01, Math.min(8, zoom.value * factor)); }
function labelIssue(key: string) { return t.value.issues[key as keyof typeof t.value.issues] ?? key; }
function labelError(key: string) { return t.value.errors[key as keyof typeof t.value.errors] ?? t.value.errors.read; }
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
  if(!same){query.value = ''; collapsed.value = new Set();}reportState.value = 'idle';
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
  const input=(event.target as HTMLElement)?.closest('input,textarea,select,[contenteditable]');
  if(!painting.value&&!input&&!event.ctrlKey&&!event.altKey&&!event.metaKey){const k=event.key.toLowerCase();if(['b','e','v','h'].includes(k))tool.value=({b:'brush',e:'eraser',v:'move',h:'pan'} as Record<string,string>)[k];}
  if(event.key==='Escape'){cancelStroke();newDialog.value=false;psdDialog.value=false;}
  if (event.ctrlKey && event.key.toLowerCase() === 'r') { event.preventDefault(); reload(); }
  if (event.ctrlKey && event.key.toLowerCase() === 'w') { event.preventDefault(); closeProject(); }
  if (event.ctrlKey && event.key === '+') { event.preventDefault(); scale(1.25); }
  if (event.ctrlKey && event.key === '-') { event.preventDefault(); scale(.8); }
}
function wheel(event: WheelEvent) { if (event.ctrlKey) { event.preventDefault(); scale(event.deltaY < 0 ? 1.1 : 1 / 1.1); } }
let drag: { x: number; y: number; left: number; top: number } | undefined;
let stroke:{project:ViewerProject;row:LayerRow;revision:string;target:string;pointer:number;asset?:HTMLCanvasElement;last?:[number,number];start:[number,number];current:[number,number];moved:boolean}|undefined;
function point(e:PointerEvent):[number,number]{const box=artboard.value!.getBoundingClientRect();return [(e.clientX-box.left)/zoom.value,(e.clientY-box.top)/zoom.value];}
function localPoint(p:[number,number],s:NonNullable<typeof stroke>):[number,number]{const transform=s.target==='mask'&&s.row.maskLinked===false&&s.row.maskPlacement?s.row.maskPlacement:s.row.transform,[x,y]=transform.origin,[w,h]=transform.size,angle=-transform.rotation*Math.PI/180,dx=p[0]-x-w/2,dy=p[1]-y-h/2;return [((Math.cos(angle)*dx-Math.sin(angle)*dy)*(transform.flipX?-1:1)+w/2)/w*s.asset!.width,((Math.sin(angle)*dx+Math.cos(angle)*dy)*(transform.flipY?-1:1)+h/2)/h*s.asset!.height];}
function clearOverlay(){if(overlay.value){overlay.value.width=project.value?.manifest.width??1;overlay.value.height=project.value?.manifest.height??1;}}
function cancelStroke(){if(stroke?.asset)stroke.asset.width=stroke.asset.height=1;stroke=undefined;painting.value=false;drag=undefined;clearOverlay();}
function paint(e:PointerEvent){const s=stroke;if(!s?.asset)return;const doc=point(e),p=localPoint(doc,s),ctx=s.asset.getContext('2d')!;
  const transform=s.target==='mask'&&s.row.maskLinked===false&&s.row.maskPlacement?s.row.maskPlacement:s.row.transform;
  const size=Math.min(500,Math.max(1,Number(brushSize.value)||1));
  ctx.globalAlpha=Math.min(100,Math.max(1,Number(brushOpacity.value)||1))/100;ctx.globalCompositeOperation=tool.value==='eraser'&&s.target!=='mask'?'destination-out':'source-over';ctx.strokeStyle=s.target==='mask'?(tool.value==='eraser'?'#000000':'#ffffff'):color.value;ctx.fillStyle=ctx.strokeStyle;ctx.lineWidth=size*s.asset.width/transform.size[0];ctx.lineCap=ctx.lineJoin='round';ctx.beginPath();ctx.moveTo(...(s.last??p));ctx.lineTo(...p);ctx.stroke();if(!s.last){ctx.beginPath();ctx.arc(p[0],p[1],ctx.lineWidth/2,0,Math.PI*2);ctx.fill();}s.last=p;s.current=doc;s.moved=true;
  const preview=overlay.value?.getContext('2d');if(preview){preview.globalAlpha=.65;preview.strokeStyle=s.target==='mask'?'#ffffff':color.value;preview.lineWidth=size;preview.lineCap='round';preview.beginPath();preview.moveTo(...s.start);preview.lineTo(...doc);preview.stroke();s.start=doc;}
}
function panStart(event: PointerEvent) {
  if (!stage.value || event.button !== 0 || !project.value) return;
  if(tool.value!=='pan'&&editable.value&&artboard.value?.contains(event.target as Node)&&selected.value){
    const row=selected.value;if(tool.value!=='move'&&((paintTarget.value==='mask'&&!row.maskFile)||(paintTarget.value==='content'&&!row.imageFile)))return;
    const s=stroke={project:project.value,row,revision:project.value.revision,target:paintTarget.value,pointer:event.pointerId,start:point(event),current:point(event),moved:false} as NonNullable<typeof stroke>;
    painting.value=true;clearOverlay();stage.value.setPointerCapture(event.pointerId);
    if(tool.value!=='move'){
      const file=s.target==='mask'?row.maskFile:row.imageFile;
      fetch(project.value.urls[`images/${file}`]).then(r=>r.blob()).then(createImageBitmap).then(bitmap=>{if(stroke!==s){bitmap.close();return;}s.asset=makeCanvas(bitmap.width,bitmap.height);s.asset.getContext('2d')!.drawImage(bitmap,0,0);bitmap.close();paint(event);}).catch(()=>{error.value='asset';cancelStroke();});
    }return;
  }
  drag = { x: event.clientX, y: event.clientY, left: stage.value.scrollLeft, top: stage.value.scrollTop };
  stage.value.setPointerCapture(event.pointerId);
}
function panMove(event: PointerEvent) {
  if(stroke){if(tool.value==='move'){stroke.current=point(event);stroke.moved=true;}else paint(event);return;}
  if (!stage.value || !drag) return;
  stage.value.scrollLeft = drag.left + drag.x - event.clientX;
  stage.value.scrollTop = drag.top + drag.y - event.clientY;
}
async function panEnd(event:PointerEvent){
  drag=undefined;const s=stroke;if(!s||s.pointer!==event.pointerId)return;
  stroke=undefined;painting.value=false;clearOverlay();
  if(!s.moved||project.value?.id!==s.project.id||project.value.revision!==s.revision){if(s.asset)s.asset.width=s.asset.height=1;return;}
  if(tool.value==='move'){await request(()=>window.editor.edit(s.project.id,s.revision,{kind:'transform',id:s.row.id,field:'origin',value:s.row.transform.origin.map((v,i)=>v+s.current[i]-s.start[i])}));}
  else if(s.asset){try{await request(async()=>{const png=await pngBytes(s.asset!);return window.editor.edit(s.project.id,s.revision,{kind:'pixels',id:s.row.id,target:s.target,png});});}catch{error.value='asset';}finally{s.asset.width=s.asset.height=1;}}
}
onMounted(async () => {
  const settings = await window.viewer.settings(); language.value = settings.language; version.value = settings.version;
  document.documentElement.lang = language.value;
  subscriptions.push(window.viewer.onOpen(open), window.viewer.onReload(reload), window.viewer.onClose(closeProject), window.viewer.onFit(fit), window.viewer.onActual(() => zoom.value = 1));
  const commands: Record<string, () => unknown> = {new:()=>{newDialog.value=true;},image:importImage,importPSD,save:()=>save(),saveAs:()=>save(true),png:()=>exportImage('png'),exportPSD:()=>{psdDialog.value=true;},recover,undo:()=>history('undo'),redo:()=>history('redo')};
  for(const [name,action] of Object.entries(commands))subscriptions.push(window.editor.onCommand(name,()=>{if(!painting.value)action();}));
  window.addEventListener('keydown', onKey); window.addEventListener('resize', fit);
});
onUnmounted(() => { operation++; epoch++; cancelStroke();renderer?.dispose(); subscriptions.forEach(stop => stop()); window.removeEventListener('keydown', onKey); window.removeEventListener('resize', fit); });
</script>

<template>
  <div class="shell" @dragenter.prevent="dragEnter" @dragover.prevent="dragOver" @dragleave="dragLeave" @drop.prevent="dropProject">
    <div v-if="dropping" class="drop-target" role="status">{{ t.dropHint }}</div>
    <header class="toolbar">
      <div class="brand"><img :src="iconURL" alt=""><div><strong>{{ t.title }}</strong><small>{{ t.subtitle }}</small></div></div>
      <button class="primary" :disabled="busy" @click="open">{{ t.open }} <kbd>Ctrl O</kbd></button>
      <button :disabled="busy || painting" data-testid="new-canvas" @click="newDialog=true">{{ t.editor.newCanvas }}</button>
      <button :disabled="!project || busy || painting" data-testid="save-project" @click="save()">{{ t.editor.save }}{{ project?.dirty?' *':'' }}</button>
      <button class="project-control" :disabled="!project || busy" :title="t.reload + ' · Ctrl+R'" :aria-label="t.reload" data-testid="reload-project" @click="reload">↻</button>
      <button class="project-control" :disabled="!project && !busy" :title="t.close + ' · Ctrl+W'" :aria-label="t.close" data-testid="close-project" @click="closeProject">×</button>
      <span class="document-name">{{ project?.name ?? '' }}</span>
      <div class="zoom-tools"><button :disabled="!project" @click="fit">{{ t.fit }}</button><button :disabled="!project" aria-label="−" @click="scale(.8)">−</button><button :disabled="!project" @click="zoom = 1">{{ Math.round(zoom * 100) }}%</button><button :disabled="!project" aria-label="+" @click="scale(1.25)">+</button></div>
      <select :aria-label="t.language" :value="language" data-testid="language" @change="changeLanguage"><option value="zh-Hans">简体中文</option><option value="en">English</option></select>
    </header>
    <div v-if="error || settingError" class="error" role="alert">{{ settingError ? t.settingsError : t.errorTitle + ' · ' + labelError(error) }}<button @click="error = ''; settingError = false">×</button></div>
    <main>
      <nav class="toolrail" :aria-label="t.editor.maskTarget"><button v-for="(symbol,key) in {move:'↖',brush:'●',eraser:'▰',pan:'✥'}" :class="{active:tool===key}" :disabled="painting || (key!=='pan'&&!editable)" :title="t.editor[key as keyof typeof t.editor]" :aria-label="t.editor[key as keyof typeof t.editor]" @click="tool=key">{{ symbol }}</button><input type="color" v-model="color" :aria-label="t.editor.color" :disabled="painting"></nav>
      <section class="workarea">
        <div v-if="project" class="optionsbar"><button :disabled="!editable" data-testid="import-image" @click="importImage">{{ t.editor.importImage }}</button><button :disabled="busy" @click="importPSD">{{ t.editor.importPSD }}</button><button :disabled="!project.canUndo || busy || painting" data-testid="undo" @click="history('undo')">{{ t.editor.undo }}</button><button :disabled="!project.canRedo || busy || painting" data-testid="redo" @click="history('redo')">{{ t.editor.redo }}</button><button :disabled="busy || painting" data-testid="save-as" @click="save(true)">{{ t.editor.saveAs }}</button><button :disabled="!editable" data-testid="export-png" @click="exportImage('png')">PNG</button><button :disabled="!editable" data-testid="export-psd" @click="psdDialog=true">PSD</button><template v-if="tool==='brush'||tool==='eraser'"><label>{{ t.editor.size }} <input type="number" v-model.number="brushSize" min="1" max="500" :disabled="painting"></label><label>{{ t.editor.brushOpacity }} <input type="number" v-model.number="brushOpacity" min="1" max="100" :disabled="painting"></label><select v-model="paintTarget" :disabled="painting" :aria-label="t.editor.maskTarget"><option value="content">{{ t.editor.content }}</option><option value="mask">{{ t.editor.mask }}</option></select></template></div>
        <div v-if="issues.length" class="notice">{{ source === 'saved' ? t.fallback : t.detailsOnly }} {{ issues.map(labelIssue).join(' · ') }}</div>
        <div ref="stage" class="stage" @wheel="wheel" @pointerdown="panStart" @pointermove="panMove" @pointerup="panEnd" @pointercancel="cancelStroke">
          <div v-if="!project" class="welcome"><img :src="iconURL" alt=""><span class="eyebrow">COMPOSITOR / WINDOWS</span><h1>{{ t.welcome }}</h1><p>{{ t.intro }}</p><button class="primary" :disabled="busy" @click.stop="open">{{ busy ? t.loading : t.open }} →</button><div><button :disabled="busy" @click="importPSD">{{ t.editor.importPSD }}</button><button :disabled="busy" data-testid="recover" @click="recover">{{ t.editor.recover }}</button></div><small>{{ t.hint }}</small></div>
          <div v-else-if="source !== 'none'" class="canvas-surround" :style="{ minWidth: project.manifest.width * zoom + 80 + 'px', minHeight: project.manifest.height * zoom + 80 + 'px' }">
            <div ref="artboard" class="artboard" :class="'tool-'+tool" :style="{ width: project.manifest.width * zoom + 'px', height: project.manifest.height * zoom + 'px' }">
              <canvas v-if="source === 'engine'" ref="canvas" data-testid="rendered-canvas"></canvas>
              <canvas v-if="source === 'engine'" ref="overlay" class="paint-overlay"></canvas>
              <img v-else :key="project.id" :src="previewURL" :alt="t.saved" draggable="false" data-testid="saved-preview" @error="savedPreviewFailed">
            </div>
          </div>
          <p v-else class="no-preview">{{ t.noPreview }}</p>
        </div>
        <footer><span>{{ busy ? t.loading : project ? (source === 'engine' ? t.engine : source === 'saved' ? t.saved : t.metadata) : t.sourceNote }}</span><span v-if="project">{{ project.manifest.width.toLocaleString() }} × {{ project.manifest.height.toLocaleString() }} px · sRGB · v{{ project.manifest.version }}</span></footer>
      </section>
      <aside>
        <div class="panel-heading"><strong>{{ t.layers }}</strong><span>{{ project?.analysis.rows.length ?? 0 }}</span></div>
        <div v-if="project" class="layer-actions"><button :disabled="!editable" data-testid="add-pixels" :title="t.editor.addPixels" @click="add('pixels')">＋</button><button :disabled="!editable" :title="t.editor.addGroup" @click="add('group')">▱</button><select :disabled="!editable" :aria-label="t.editor.addAdjustment" value="" @change="add('adjustment',($event.target as HTMLSelectElement).value)"><option value="">{{ t.editor.addAdjustment }}</option><option v-for="(kind,i) in ADJUSTMENTS" :value="kind">{{ t.adjustments[i] }}</option></select></div>
        <div v-if="project" class="layer-search"><input v-model="query" :placeholder="t.search" :aria-label="t.search" maxlength="256" data-testid="layer-search"><button v-if="query" :aria-label="t.clearSearch" @click="query = ''">×</button></div>
        <div class="layer-list"><p v-if="!project" class="muted">{{ t.empty }}</p><p v-else-if="!rows.length" class="muted">{{ t.noMatches }}</p><div v-for="row in rows" :key="row.id" class="layer-row" :class="{ selected: selected?.id === row.id, hidden: !row.effectiveVisible }" :style="{ paddingLeft: 8 + row.depth * 14 + 'px' }">
          <button v-if="row.isGroup" class="fold" :disabled="!!query.trim()" :aria-label="collapsed.has(row.id.toUpperCase()) && !query.trim() ? t.expand : t.collapse" :aria-expanded="!!query.trim() || !collapsed.has(row.id.toUpperCase())" @click="toggleGroup(row)">{{ collapsed.has(row.id.toUpperCase()) && !query.trim() ? '▸' : '▾' }}</button><span v-else class="fold-spacer"></span>
          <button class="layer-select" :disabled="painting" :aria-pressed="selected?.id === row.id" @click="selected = row"><span aria-hidden="true">{{ row.isGroup ? '▱' : '▧' }}</span><span class="layer-title">{{ row.name }}<small>{{ kind(row) }} · {{ Math.round(row.effectiveOpacity * 100) }}%{{ row.maskFile?' · ◧':'' }}{{ row.maskSourceID?' · ↳':'' }}</small></span><span class="eye" aria-hidden="true">{{ row.effectiveVisible ? '◉' : '○' }}</span></button>
        </div></div>
        <div class="inspector"><template v-if="selected"><strong>{{ t.editor.edit }}</strong><p v-if="!editable&&!busy" class="muted">{{ t.editor.readOnly }}</p><div class="parameter-form"><label>{{ t.editor.rename }}<input :value="selected.name" maxlength="256" :disabled="busy" data-testid="layer-name" @change="edit({kind:'rename',name:($event.target as HTMLInputElement).value})"></label><label>{{ t.editor.visible }}<input type="checkbox" :checked="selected.isVisible" :disabled="!editable" @change="edit({kind:'appearance',field:'isVisible',value:($event.target as HTMLInputElement).checked})"></label><label>{{ t.editor.opacity }}<input type="number" min="0" max="100" :value="Math.round((selected.opacity??1)*100)" :disabled="!editable" data-testid="layer-opacity" @change="edit({kind:'appearance',field:'opacity',value:numberEvent($event)/100})"></label><label>{{ t.editor.blend }}<select :value="selected.blendMode??'Normal'" :disabled="!editable||selected.isGroup" data-testid="blend-mode" @change="edit({kind:'appearance',field:'blendMode',value:($event.target as HTMLSelectElement).value})"><option v-for="(mode,i) in BLEND_MODES" :value="mode">{{ t.blends[i] }}</option></select></label><label v-for="(key,i) in ['X','Y']" :key="key">{{ key }}<input type="number" :value="selected.transform.origin[i]" :disabled="!editable" @change="transformPair('origin',i,$event)"></label><label v-for="(key,i) in [t.editor.width,t.editor.height]" :key="key">{{ key }}<input type="number" min="1" max="300000" :value="selected.transform.size[i]" :disabled="!editable||selected.isGroup" @change="transformPair('size',i,$event)"></label><label>{{ t.editor.rotation }}<input type="number" :value="selected.transform.rotation" :disabled="!editable||selected.isGroup" @change="edit({kind:'transform',field:'rotation',value:numberEvent($event)})"></label><div class="button-row"><button :disabled="!editable||selected.isGroup" @click="edit({kind:'transform',field:'flipX',value:!selected.transform.flipX})">{{ t.editor.flipH }}</button><button :disabled="!editable||selected.isGroup" @click="edit({kind:'transform',field:'flipY',value:!selected.transform.flipY})">{{ t.editor.flipV }}</button></div><label>{{ t.editor.parent }}<select :disabled="!editable" :value="selected.parentID??''" @change="edit({kind:'parent',parentID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.root }}</option><option v-for="g in project?.analysis.rows.filter(l=>l.isGroup&&l.id!==selected?.id)" :value="g.id">{{ g.name }}</option></select></label><label v-if="!selected.isGroup">{{ t.editor.clip }}<select :disabled="!editable" :value="selected.maskSourceID??''" data-testid="clip-source" @change="edit({kind:'clip',sourceID:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.none }}</option><option v-for="l in project?.analysis.rows.filter(l=>!l.isGroup&&l.imageFile&&l.id!==selected?.id&&l.parentID?.toUpperCase()===selected?.parentID?.toUpperCase())" :value="l.id">{{ l.name }}</option></select></label><div class="button-row"><button :disabled="!editable||selected.isGroup" @click="edit({kind:'duplicate'})">{{ t.editor.duplicate }}</button><button :disabled="!editable" data-testid="delete-layer" @click="edit({kind:'delete'})">{{ t.editor.delete }}</button><button :disabled="!editable" @click="edit({kind:'reorder',direction:1})">↑</button><button :disabled="!editable" @click="edit({kind:'reorder',direction:-1})">↓</button></div><button v-if="!selected.maskFile" :disabled="!editable" data-testid="add-mask" @click="edit({kind:'mask',action:'add'})">{{ t.editor.addMask }}</button><template v-else><label><input type="checkbox" :checked="selected.maskEnabled!==false" :disabled="!editable" @change="edit({kind:'mask',action:'toggle'})">{{ t.editor.enableMask }}</label><label><input type="checkbox" :checked="selected.maskLinked!==false" :disabled="!editable" @change="edit({kind:'mask',action:'link',value:($event.target as HTMLInputElement).checked})">{{ t.editor.linkMask }}</label><div class="button-row"><button :disabled="!editable" data-testid="invert-mask" @click="edit({kind:'mask',action:'invert'})">{{ t.editor.invertMask }}</button><button :disabled="!editable" @click="edit({kind:'mask',action:'remove'})">{{ t.editor.removeMask }}</button></div></template></div>
          <small v-if="selected.text||selected.shape" class="muted">{{ t.editor.rasterize }}</small>
          <details v-if="selected.adjustment" open><summary>{{ t.editor.adjustment }}</summary><AdjustmentEditor :value="selected.adjustment" :zh="language==='zh-Hans'" :disabled="!editable" @edit="edit({kind:'adjustment',...$event})"/></details>
          <details v-if="selected.imageFile" open><summary>{{ t.editor.effect }}</summary><select :disabled="!editable" value="" :aria-label="t.editor.addEffect" @change="edit({kind:'effect',effect:($event.target as HTMLSelectElement).value})"><option value="">{{ t.editor.addEffect }}</option><option v-for="(effect,i) in EFFECTS" :value="effect">{{ t.effects[i] }}</option></select><EffectEditor :value="selected.effects??{}" :zh="language==='zh-Hans'" :disabled="!editable" :names="t.effects" @edit="edit({kind:'effect',...$event})"/></details>
          <details class="raw-properties"><summary>{{ t.properties }}</summary><pre>{{ formattedProperties }}</pre></details></template><p v-else class="muted">{{ t.noSelection }}</p></div>
        <details v-if="project" class="coverage"><summary>{{ t.coverage }}</summary><dl><div><dt>{{ t.simple }}</dt><dd>{{ project.analysis.coverage.simple }}</dd></div><div><dt>{{ t.pixels }}</dt><dd>{{ project.analysis.coverage.pixelFallback }}</dd></div><div><dt>{{ t.preview }}</dt><dd>{{ project.analysis.coverage.previewOnly }}</dd></div></dl><small>{{ t.coverageNote }}</small><button class="report-button" :disabled="busy" data-testid="copy-report" @click="copyReport">{{ t.copyReport }}</button><small>{{ t.reportPrivacy }}</small><small v-if="reportState !== 'idle'" role="status">{{ reportState === 'copied' ? t.reportCopied : t.reportError }}</small></details>
      </aside>
    </main>
    <div class="statusbar"><span class="badge">{{ t.readonly }} · {{ project?.dirty?t.editor.unsaved:t.editor.saved }}</span><span role="status">{{ status }}</span><span>{{ t.version }} {{ version }}</span></div>
    <div v-if="newDialog" class="modal-shade" @click.self="newDialog=false"><form class="dialog" @submit.prevent="create"><h2>{{ t.editor.newCanvas }}</h2><div class="new-dimensions"><label>{{ t.editor.width }}<input type="number" v-model.number="newWidth" min="1" max="30000" required></label><button type="button" :aria-label="t.editor.swap" @click="[newWidth,newHeight]=[newHeight,newWidth]">⇄</button><label>{{ t.editor.height }}<input type="number" v-model.number="newHeight" min="1" max="30000" required></label></div><div class="button-row"><button type="button" @click="newDialog=false">{{ t.editor.cancel }}</button><button class="primary" type="submit">{{ t.editor.create }}</button></div></form></div>
    <div v-if="psdDialog" class="modal-shade" @click.self="psdDialog=false"><div class="dialog"><h2>{{ t.editor.conversion }}</h2><p>{{ t.editor.conversionNote }}</p><div class="button-row"><button @click="psdDialog=false">{{ t.editor.cancel }}</button><button :disabled="!layeredPSD||!editable" @click="exportImage('psd')">{{ t.editor.layered }}</button><button :disabled="!editable" class="primary" @click="exportImage('psd',true)">{{ t.editor.flattened }}</button></div></div></div>
  </div>
</template>
