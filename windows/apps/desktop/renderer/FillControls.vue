<script setup lang="ts">
import {computed}from'vue';
import{parityMessages}from'./parity-labels';
import type{Language}from'./types';
const props=defineProps<{value:Record<string,any>;language:Language;disabled?:boolean}>();
const emit=defineEmits<{change:[value:Record<string,any>]}>();
const t=computed(()=>parityMessages[props.language]);
const stops=computed<any[]>(()=>props.value.stops??[]);
const hex=(color:Record<string,number>)=>'#'+['red','green','blue'].map(key=>Math.round(color[key]*255).toString(16).padStart(2,'0')).join('');
function update(field:string,value:unknown){emit('change',{...JSON.parse(JSON.stringify(props.value)),[field]:value});}
function stop(index:number,field:string,value:unknown){const next=JSON.parse(JSON.stringify(props.value));if(field==='color'){const text=String(value);for(const [channel,key]of ['red','green','blue'].entries())next.stops[index].color[key]=parseInt(text.slice(channel*2+1,channel*2+3),16)/255;}else if(field==='alpha')next.stops[index].color.alpha=value;else next.stops[index][field]=value;next.stops.sort((a:any,b:any)=>a.position-b.position);emit('change',next);}
function add(){const next=JSON.parse(JSON.stringify(props.value));next.stops.push({id:crypto.randomUUID().toUpperCase(),position:.5,color:{red:1,green:1,blue:1,alpha:1}});next.stops.sort((a:any,b:any)=>a.position-b.position);emit('change',next);}
function remove(index:number){const next=JSON.parse(JSON.stringify(props.value));next.stops.splice(index,1);emit('change',next);}
</script>
<template><fieldset :disabled="disabled" class="fill-controls">
  <div class="style-fields"><label>{{t.fillLayer}}<select :value="value.kind" data-testid="fill-kind" @change="update('kind',($event.target as HTMLSelectElement).value)"><option v-for="(id,index) in ['Solid Color','Linear','Radial','Pattern']" :key="id" :value="id">{{t.fillKinds[index]}}</option></select></label><label>{{t.angle}}<input type="number" min="-180" max="180" :value="value.angle" @change="update('angle',Number(($event.target as HTMLInputElement).value))"></label><label>{{t.scale}}<input type="number" min=".01" max="10" step=".01" :value="value.scale" @change="update('scale',Number(($event.target as HTMLInputElement).value))"></label></div>
  <label v-if="['Linear','Radial'].includes(value.kind)"><input type="checkbox" :checked="value.reversed" @change="update('reversed',($event.target as HTMLInputElement).checked)">{{t.reverse}}</label>
  <div v-if="value.kind==='Pattern'" class="style-fields"><label>{{t.pattern}}<select :value="value.pattern" @change="update('pattern',($event.target as HTMLSelectElement).value)"><option v-for="(id,index) in ['Checkerboard','Stripes','Dots']" :key="id" :value="id">{{t.patterns[index]}}</option></select></label><label>{{t.cellSize}}<input type="number" min="4" max="512" :value="value.cellSize" @change="update('cellSize',Number(($event.target as HTMLInputElement).value))"></label></div>
  <fieldset><legend>{{t.stops}}</legend><div v-for="(entry,index) in stops" :key="entry.id" class="fill-stop"><label>{{t.position}}<input type="number" min="0" max="1" step=".01" :value="entry.position" @change="stop(index,'position',Number(($event.target as HTMLInputElement).value))"></label><input :aria-label="t.stops+' '+(index+1)" type="color" :value="hex(entry.color)" @change="stop(index,'color',($event.target as HTMLInputElement).value)"><label>{{t.opacity}}<input type="number" min="0" max="1" step=".01" :value="entry.color.alpha" @change="stop(index,'alpha',Number(($event.target as HTMLInputElement).value))"></label><button type="button" :disabled="value.stops.length<=2" @click="remove(index)">{{t.remove}}</button></div><button type="button" :disabled="value.stops.length>=32" @click="add()">{{t.addStop}}</button></fieldset>
</fieldset></template>
<style scoped>.fill-controls{border:0;padding:0}.fill-controls fieldset{border:1px solid var(--border);margin:10px 0}.fill-stop{display:flex;gap:8px;align-items:end;flex-wrap:wrap;margin:8px 0}.fill-stop label{flex:1;min-width:80px}.fill-stop input[type=number]{width:100%}</style>
