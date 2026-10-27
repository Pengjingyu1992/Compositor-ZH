<script setup lang="ts">
import{computed}from'vue';
import{parityMessages}from'./parity-labels';
import{fullEditor}from'./editor-labels';
import{FILTERS}from'../../../packages/comp-bridge/raster-tools.mjs';
import type{Language,ViewerProject}from'./types';
const props=defineProps<{language:Language;project:ViewerProject;busy:boolean}>();
const emit=defineEmits(['close','jump']),t=computed(()=>parityMessages[props.language]);
function label(entry:{kind:string;detail?:string}){const names=t.value.historyKinds as Record<string,string>,kind=names[entry.kind]??names.edit,index=FILTERS.indexOf(entry.detail??'');return kind+(entry.kind==='filter'&&entry.detail?' · '+(index>=0?fullEditor[props.language].filters[index]:entry.detail):'');}
</script>
<template><div class="modal-shade" @click.self="!busy&&emit('close')"><section class="dialog history-dialog" role="dialog" aria-modal="true" :aria-label="t.historyPanel"><h2>{{t.historyPanel}}</h2><p>{{t.historyTip}}</p><ol><li v-for="entry in project.historyEntries??[]" :key="entry.index"><button :disabled="busy||entry.index===project.historyIndex" :aria-current="entry.index===project.historyIndex?'step':undefined" :data-history-index="entry.index" @click="emit('jump',entry.index)">{{entry.index}}. {{label(entry)}} <span v-if="entry.index===project.historyIndex">●</span></button></li></ol><button :disabled="busy" @click="emit('close')">{{t.close}}</button></section></div></template>
<style scoped>.history-dialog{width:min(620px,94vw);max-height:85vh}.history-dialog ol{max-height:56vh;overflow:auto;padding:0;list-style:none}.history-dialog li button{width:100%;text-align:left;margin:2px 0}.history-dialog button[aria-current=step]{border-color:var(--accent);opacity:1}</style>
