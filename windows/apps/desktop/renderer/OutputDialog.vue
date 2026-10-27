<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { parityMessages } from './parity-labels';
import { localizedMessages } from '../../../packages/locales';
import type { Language, ViewerProject, OpenResult } from './types';
const props = defineProps<{ language:Language; project:ViewerProject; getComposite:()=>Promise<Uint8Array>; exportFile:(type:string, options:Record<string,unknown>)=>Promise<OpenResult|undefined> }>();
defineEmits(['close']);
const t = computed(() => parityMessages[props.language]);
const format=ref('png'), quality=ref(90), size=ref(0), resolution=ref(props.project.manifest.resolution??72), lossless=ref(false);
const busy=ref(false), error=ref(''), complete=ref(false), profile=ref('built-in-cmyk'), before=ref(''), after=ref('');
let generation=0;
function clearProof(){for(const url of [before.value,after.value])if(url)URL.revokeObjectURL(url);before.value='';after.value='';}
const failure = (code?:string) => (localizedMessages(props.language,'windows').errors as Record<string,string>)[code??'']??t.value.failed;
const payload = () => ({ id:props.project.id, revision:props.project.revision });
async function chooseProfile(reset=false){busy.value=true;error.value='';try{const result=await window.editor.outputTools('profile',{...payload(),reset});if(result.error)throw new Error(failure(result.error));if(result.profile){profile.value=result.profile;clearProof();}}catch(e){error.value=(e as Error).message;}finally{busy.value=false;}}
async function proof(){const own=++generation;busy.value=true;error.value='';try{const png=await props.getComposite(),result=await window.editor.outputTools('proof',{...payload(),png});if(own!==generation)return;if(result.error||!result.png)throw new Error(failure(result.error));clearProof();before.value=URL.createObjectURL(new Blob([new Uint8Array(png)],{type:'image/png'}));after.value=URL.createObjectURL(new Blob([new Uint8Array(result.png)],{type:'image/png'}));}catch(e){if(own===generation)error.value=(e as Error).message;}finally{if(own===generation)busy.value=false;}}
async function save(){busy.value=true;error.value='';complete.value=false;try{const result=await props.exportFile(format.value,{quality:quality.value,size:size.value,resolution:resolution.value,lossless:lossless.value});if(result?.error)throw new Error(failure(result.error));complete.value=!!result?.exported;}catch(e){error.value=(e as Error).message;}finally{busy.value=false;}}
watch(()=>[props.project.id,props.project.revision],()=>{generation++;clearProof();busy.value=false;complete.value=false;});
onMounted(async()=>{const result=await window.editor.outputTools('profileInfo',payload());if(result.profile)profile.value=result.profile;});
onUnmounted(()=>{generation++;clearProof();});
</script>
<template>
  <div class="modal-shade" @click.self="!busy && $emit('close')"><section class="dialog output-dialog" role="dialog" aria-modal="true" :aria-label="t.output">
    <div class="dialog-heading"><h2>{{t.output}}</h2><button type="button" :disabled="busy" @click="$emit('close')">{{t.close}}</button></div>
    <p v-if="error" role="alert">{{error}}</p><p v-if="complete" role="status">{{t.completed}}</p>
    <div class="style-fields">
      <label>{{t.format}}<select v-model="format" data-testid="output-format" :disabled="busy"><option v-for="[id,name] of [['png','PNG'],['jpeg','JPEG'],['tiff','TIFF (RGB)'],['webp','WebP'],['avif','AVIF'],['pdf','PDF'],['cmyktiff','TIFF (CMYK/ICC)']]" :key="id" :value="id">{{name}}</option></select></label>
      <label>{{t.longEdge}}<input v-model.number="size" data-testid="output-size" type="number" min="0" max="30000" :disabled="busy"></label>
      <label>{{t.quality}}<input v-model.number="quality" type="number" min="1" max="100" :disabled="busy || !['jpeg','webp','avif','pdf'].includes(format)"></label>
      <label>{{t.resolution}}<input v-model.number="resolution" data-testid="output-resolution" type="number" min="1" max="9600" :disabled="busy"></label>
      <label v-if="format==='webp'"><input v-model="lossless" type="checkbox" :disabled="busy">{{t.lossless}}</label>
    </div>
    <p>{{t.whiteBackground}}</p>
    <fieldset :disabled="busy"><legend>{{t.profile}}</legend><p>{{profile==='built-in-cmyk'?t.defaultProfile:profile}}</p><div class="button-row"><button @click="chooseProfile()">{{t.chooseProfile}}</button><button @click="chooseProfile(true)">{{t.resetProfile}}</button><button data-testid="print-proof" @click="proof()">{{t.proof}}</button></div><p>{{t.proofNote}}</p></fieldset>
    <div v-if="after" class="proof-comparison"><figure><figcaption>{{t.original}}</figcaption><img :src="before" :alt="t.original"></figure><figure><figcaption>{{t.simulated}}</figcaption><img data-testid="print-proof-image" :src="after" :alt="t.simulated"></figure></div>
    <div class="button-row dialog-actions"><span v-if="busy" role="status">{{t.loading}}</span><button :disabled="busy" @click="$emit('close')">{{t.close}}</button><button class="primary" data-testid="output-export" :disabled="busy" @click="save()">{{t.export}}</button></div>
  </section></div>
</template>
<style scoped>
.output-dialog{width:min(780px,95vw);max-height:90vh;overflow:auto}.proof-comparison{display:grid;grid-template-columns:1fr 1fr;gap:12px}.proof-comparison figure{margin:0;min-width:0}.proof-comparison img{max-width:100%;max-height:280px;object-fit:contain;background:repeating-conic-gradient(#777 0 25%,#aaa 0 50%) 0/16px 16px}fieldset{border:1px solid var(--border);margin:12px 0}p[role=alert]{color:#ffb4b4}
</style>
