<script setup lang="ts">
import{computed,onMounted,ref,watch}from'vue';
import FillControls from'./FillControls.vue';
import{parityMessages}from'./parity-labels';
import{localizedMessages}from'../../../packages/locales';
import{defaultFillStyle,fillSampler}from'../../../packages/comp-bridge/layer-styles.mjs';
import type{Language,ViewerProject,LayerRow,OpenResult}from'./types';
const props=defineProps<{language:Language;project:ViewerProject;layer?:LayerRow;editing:boolean;commit:(op:Record<string,unknown>,owner:{id:string;revision:string})=>Promise<OpenResult>}>();
const emit=defineEmits(['close']);
const owner={id:props.project.id,revision:props.project.revision},existing=props.editing?props.layer:undefined;
const style=ref<any>(JSON.parse(JSON.stringify(existing?.fill??defaultFillStyle()))),canvas=ref<HTMLCanvasElement>(),busy=ref(false),error=ref('');
const t=computed(()=>parityMessages[props.language]);
const [width,height]=existing?.pixelSize??[props.project.manifest.width,props.project.manifest.height];
function preview(){if(!canvas.value)return;try{const factor=Math.min(1,420/Math.max(width,height)),w=Math.max(1,Math.round(width*factor)),h=Math.max(1,Math.round(height*factor)),sample=fillSampler(width,height,style.value);canvas.value.width=w;canvas.value.height=h;const image=new ImageData(w,h);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const color=sample((x+.5)/factor,(y+.5)/factor);for(const[c,key]of ['red','green','blue','alpha'].entries())image.data[(y*w+x)*4+c]=Math.round(color[key]*255);}canvas.value.getContext('2d')!.putImageData(image,0,0);error.value='';}catch{error.value=t.value.failed;}}
async function apply(){busy.value=true;error.value='';try{const result=await props.commit({kind:'fillLayer',id:existing?.id,style:JSON.parse(JSON.stringify(style.value)),name:t.value.fillLayer,...(!existing&&props.layer?{parentID:props.layer.isGroup?props.layer.id:props.layer.parentID}:{})},owner);if(result.project)emit('close');else if(result.error)error.value=(localizedMessages(props.language,'windows').errors as Record<string,string>)[result.error]??t.value.failed;}catch{error.value=t.value.failed;}finally{busy.value=false;}}
onMounted(preview);watch(style,preview,{deep:true,flush:'post'});
</script>
<template><div class="modal-shade" @click.self="!busy&&emit('close')"><section class="dialog fill-dialog" role="dialog" aria-modal="true" :aria-label="t.fillLayer" @keydown.esc.stop.prevent="!busy&&emit('close')"><h2>{{t.fillLayer}}</h2><p v-if="error" role="alert">{{error}}</p><canvas ref="canvas" class="fill-preview" data-testid="fill-preview"></canvas><FillControls :value="style" :language="language" :disabled="busy" @change="style=$event"/><div class="button-row dialog-actions"><button :disabled="busy" @click="emit('close')">{{t.cancel}}</button><button class="primary" data-testid="apply-fill-layer" :disabled="busy||!!error" @click="apply()">{{busy?t.loading:t.apply}}</button></div></section></div></template>
<style scoped>.fill-dialog{max-height:90vh;overflow:auto;width:min(680px,94vw)}.fill-preview{display:block;max-width:100%;max-height:240px;object-fit:contain;margin:0 auto 12px;background:repeating-conic-gradient(#777 0 25%,#aaa 0 50%) 0/16px 16px}</style>
