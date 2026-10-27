<script setup lang="ts">
import { computed, markRaw, ref } from 'vue';
import { parityMessages } from './parity-labels';
import { IDENTITY_MIXER, SELECTIVE_RANGES, parseColorLUT } from '../../../packages/comp-bridge/poster-color.mjs';
import type { Language } from './types';
const props=defineProps<{value:Record<string,any>;language:Language}>();
const t=computed(()=>parityMessages[props.language]),range=ref('Reds'),error=ref(''),file=ref<HTMLInputElement>();
const screens=['Automatic Channels','RGB Channels','Grayscale Screen','Legacy CMYK Print'];
function preset(size=8,shape='Round'){Object.assign(props.value.halftone,{size,shape,cyan:108,magenta:162,yellow:90,black:45,strength:100,screen:'Automatic Channels'});}
async function load(event:Event){const selected=(event.target as HTMLInputElement).files?.[0];if(!selected)return;error.value='';try{if(selected.size>16*1024**2)throw new Error('limit');props.value.colorLUT.table=markRaw(parseColorLUT(new Uint8Array(await selected.arrayBuffer()),selected.name));}catch{error.value=t.value.failed;}(event.target as HTMLInputElement).value='';}
</script>
<template>
  <template v-if="value.kind==='Color Halftone'">
    <div class="button-row"><button type="button" @click="preset()">{{t.defaults}}</button><button type="button" @click="preset(5)">{{t.newsprint}}</button><button type="button" @click="preset(18,'Square')">{{t.popArt}}</button></div>
    <div class="style-fields"><label>{{t.screen}}<select v-model="value.halftone.screen" data-testid="halftone-screen"><option v-for="(id,index) in screens" :key="id" :value="id">{{t.screens[index]}}</option></select></label><label>{{t.dotShape}}<select v-model="value.halftone.shape"><option v-for="(id,index) in ['Round','Square','Line']" :key="id" :value="id">{{t.dotShapes[index]}}</option></select></label><label>{{t.maxRadius}}<input v-model.number="value.halftone.size" type="number" min="2" max="128"></label><label>{{t.strength}}<input v-model.number="value.halftone.strength" type="number" min="0" max="100"></label></div>
    <fieldset><legend>{{t.channelAngles}}</legend><div class="style-fields"><label v-for="(id,index) in ['cyan','magenta','yellow','black']" :key="id">{{value.halftone.screen==='Legacy CMYK Print'?[t.cyan,t.magenta,t.yellow,t.black][index]:['R','G','B',t.selectiveRanges[8]][index]}}<input v-model.number="value.halftone[id]" type="number" min="-180" max="180"></label></div></fieldset>
  </template>
  <template v-else-if="value.kind==='Selective Color'">
    <label>{{t.selectiveRange}}<select v-model="range"><option v-for="(id,index) in SELECTIVE_RANGES" :key="id" :value="id">{{t.selectiveRanges[index]}}</option></select></label><label><input v-model="value.selectiveColor.relative" type="checkbox">{{t.relative}}</label>
    <div class="style-fields"><label v-for="(name,index) in [t.cyan,t.magenta,t.yellow,t.black]" :key="name">{{name}}<input v-model.number="value.selectiveColor.adjustments[range][index]" type="number" min="-100" max="100"></label></div>
  </template>
  <template v-else-if="value.kind==='Channel Mixer'">
    <button type="button" @click="value.channelMixer.coefficients=[...IDENTITY_MIXER]">{{t.defaults}}</button>
    <fieldset v-for="(channel,row) in ['R','G','B']" :key="channel"><legend>{{t.outputChannel}} {{channel}}</legend><div class="style-fields"><label v-for="(input,column) in ['R','G','B',t.constant]" :key="input">{{input}}<input v-model.number="value.channelMixer.coefficients[row*4+column]" type="number" min="-200" max="200"></label></div></fieldset>
  </template>
  <template v-else-if="value.kind==='Color Lookup'">
    <input ref="file" data-testid="lut-file" type="file" accept=".cube" hidden @change="load"><button type="button" @click="file?.click()">{{t.chooseLUT}}</button><span>{{value.colorLUT.table?.name??t.lutMissing}}</span><p v-if="error" role="alert">{{error}}</p>
    <div class="style-fields"><label>{{t.strength}}<input v-model.number="value.colorLUT.strength" type="number" min="0" max="100"></label><label>{{t.lutSpace}}<select v-model="value.colorLUT.space"><option v-for="(id,index) in ['Encoded sRGB','Linear sRGB']" :key="id" :value="id">{{t.lutSpaces[index]}}</option></select></label></div>
  </template>
</template>
