<script setup lang="ts">
import{computed,onUnmounted,ref}from'vue';
import{createPreviewRenderer,makeCanvas,pngBytes}from'../../../packages/editor-adapter/render';
import{isolateBatchRows}from'../../../packages/comp-bridge/batch-export.mjs';
import{parityMessages}from'./parity-labels';
import{localizedMessages}from'../../../packages/locales';
import type{Language,ViewerProject}from'./types';
const props=defineProps<{language:Language;project:ViewerProject;selected:string[]}>(),emit=defineEmits(['close','running']),t=computed(()=>parityMessages[props.language]);
const sides=ref('0, 1080, 2048'),format=ref('png'),quality=ref(90),prefix=ref(''),individual=ref(false),busy=ref(false),error=ref(''),complete=ref(''),canceled=ref(false),completed=ref(0),total=ref(0);
let jobID='',aborted=false,live=true,renderer:ReturnType<typeof createPreviewRenderer>|undefined;
const unsubscribe=window.editor.onBatchProgress(value=>{if(value.jobID===jobID){completed.value=value.completed;total.value=value.total;}});
const failure=(code:string)=>(localizedMessages(props.language,'windows').errors as Record<string,string>)[code]??t.value.failed;
async function cancel(){aborted=true;renderer?.dispose();renderer=undefined;if(jobID)await window.editor.batchExport('cancel',{jobID});}
async function run(){
  if(busy.value)return;busy.value=true;emit('running',true);aborted=false;canceled.value=false;error.value='';complete.value='';completed.value=total.value=0;const surface=makeCanvas(1,1);
  try{
    const parts=sides.value.trim().split(/[,，;\s]+/);if(parts.some(value=>!/^\d+$/.test(value)))throw new Error(failure('invalid'));
    const result=await window.editor.batchExport('start',{id:props.project.id,revision:props.project.revision,selected:[...props.selected],options:{longSides:parts.map(Number),format:format.value,quality:quality.value,prefix:prefix.value,individualLayers:individual.value}});
    if(result.error)throw new Error(failure(result.error));if(!result.jobID||!result.targets){canceled.value=true;return;}jobID=result.jobID;total.value=result.total??0;
    if(aborted){await cancel();canceled.value=true;return;}renderer=createPreviewRenderer();
    for(const [index,target]of result.targets.entries()){
      if(aborted)break;const snapshot=target.id?{...props.project,manifest:{...props.project.manifest,animation:undefined},analysis:{...props.project.analysis,rows:isolateBatchRows(props.project.analysis.rows,target.id)}}:props.project;
      await renderer.render(snapshot,surface,()=>{aborted=true;error.value=failure('gpu');});if(aborted)break;
      const png=await pngBytes(surface);if(aborted)break;const appended=await window.editor.batchExport('append',{jobID,index,png});if(appended.error)throw new Error(failure(appended.error));if(appended.canceled){aborted=true;break;}completed.value=appended.completed??completed.value;
    }
    if(aborted){await cancel();canceled.value=true;return;}const resultEnd=await window.editor.batchExport('finish',{jobID});if(resultEnd.error)throw new Error(failure(resultEnd.error));if(resultEnd.exported)complete.value=resultEnd.folder??t.value.completed;
  }catch(e){if(aborted)canceled.value=true;else error.value=(e as Error).message;if(jobID)await window.editor.batchExport('cancel',{jobID}).catch(()=>{});}
  finally{jobID='';renderer?.dispose();renderer=undefined;surface.width=surface.height=1;if(live){busy.value=false;emit('running',false);}}
}
onUnmounted(()=>{live=false;unsubscribe();void cancel();emit('running',false);});
</script>
<template><div class="modal-shade" @click.self="!busy&&emit('close')" @keydown.esc.stop.prevent="busy?cancel():emit('close')"><section class="dialog batch-dialog" role="dialog" aria-modal="true" :aria-label="t.batchExport"><h2>{{t.batchExport}}</h2><p>{{t.batchTip}}</p><p v-if="error" role="alert">{{error}}</p><p v-if="complete" role="status">{{t.completed}} · {{complete}}</p><p v-if="canceled" role="status">{{t.batchCanceled}}</p><fieldset :disabled="busy"><div class="style-fields"><label>{{t.batchSizes}}<input v-model="sides" data-testid="batch-sizes"></label><label>{{t.format}}<select v-model="format" data-testid="batch-format"><option value="png">PNG</option><option value="jpeg">JPEG</option></select></label><label>{{t.quality}}<input v-model.number="quality" type="number" min="1" max="100" :disabled="format!=='jpeg'"></label><label>{{t.batchPrefix}}<input v-model="prefix" maxlength="120" data-testid="batch-prefix"></label><label><input v-model="individual" type="checkbox" data-testid="batch-layers" :disabled="!selected.length">{{t.batchLayers}} ({{selected.length}})</label></div></fieldset><div v-if="busy" class="batch-progress" role="status"><progress :value="completed" :max="total||1"></progress><span>{{completed}} / {{total}}</span></div><div class="button-row dialog-actions"><button v-if="busy" data-testid="batch-cancel" @click="cancel">{{t.cancel}}</button><button v-else @click="emit('close')">{{t.close}}</button><button class="primary" data-testid="batch-export" :disabled="busy" @click="run">{{t.export}}</button></div></section></div></template>
<style scoped>.batch-dialog{width:min(620px,94vw)}fieldset{border: 0;padding:0}.batch-progress{display:flex;gap:10px;align-items:center;margin:12px 0}.batch-progress progress{flex:1}p[role=alert]{color: var(--error)}</style>
