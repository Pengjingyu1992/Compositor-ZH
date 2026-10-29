<script setup lang="ts">
import{computed,ref}from'vue';
import{parityMessages}from'./parity-labels';
import{validateViewSettings}from'../../../packages/comp-bridge/view-settings.mjs';
import type{Language}from'./types';
const props=defineProps<{language:Language;settings:Record<string,any>}>(),emit=defineEmits(['close','apply']),draft=ref(JSON.parse(JSON.stringify(props.settings))),t=computed(()=>parityMessages[props.language]);
const valid=computed(()=>{try{validateViewSettings(draft.value);return true;}catch{return false;}});
</script>
<template>
  <div class="modal-shade" @click.self="emit('close')">
    <form class="dialog workspace-settings" role="dialog" aria-modal="true" :aria-label="t.viewSettings" @submit.prevent="valid&&emit('apply',draft)">
      <h2>{{t.viewSettings}}</h2>
      <div class="settings-group">
        <label>{{t.appearance}}<select v-model="draft.appearance" :aria-label="t.appearance" data-testid="interface-appearance"><option value="system">{{t.appearanceSystem}}</option><option value="light">{{t.appearanceLight}}</option><option value="dark">{{t.appearanceDark}}</option></select></label>
      </div>
      <fieldset class="settings-group">
        <legend>{{t.gridSection}}</legend>
        <label>{{t.gridSpacing}}<input v-model.number="draft.gridSpacing" type="number" min="1" max="30000" data-testid="grid-spacing"></label>
        <label>{{t.gridSubdivisions}}<input v-model.number="draft.gridSubdivisions" type="number" min="1" max="100"></label>
        <label>{{t.gridColor}}<input v-model="draft.gridColor" type="color"></label>
        <label>{{t.opacity}}<input v-model.number="draft.gridOpacity" type="number" min="0" max="100"></label>
      </fieldset>
      <div class="settings-group">
        <label>{{t.rulerUnit}}<select v-model="draft.rulerUnit" :aria-label="t.rulerUnit"><option value="px">{{t.pixelsUnit}}</option><option value="in">{{t.inchesUnit}}</option><option value="cm">{{t.centimetersUnit}}</option></select></label>
      </div>
      <p>{{t.viewSettingsTip}}</p>
      <div class="button-row dialog-actions"><button type="button" @click="emit('close')">{{t.cancel}}</button><button class="primary" type="submit" data-testid="apply-view-settings" :disabled="!valid">{{t.apply}}</button></div>
    </form>
  </div>
</template>
<style scoped>
.settings-group { display: grid; gap: 8px; min-width: 0; margin: 16px 0; padding: 0; border: 0; }
fieldset.settings-group { border-block: 1px solid var(--border); padding-block: 12px; }
.settings-group legend { padding: 0 8px 0 0; font-size: 12px; font-weight: 600; }
.settings-group label { display: grid; grid-template-columns: minmax(0, 1fr) 156px; align-items: center; gap: 16px; font-size: 12px; color: var(--muted); }
.settings-group input, .settings-group select { width: 100%; color: var(--text); }
.settings-group input[type=color] { height: 28px; padding: 3px; border: 1px solid var(--border); border-radius: 6px; background: var(--control); }
.workspace-settings p { margin-block: 14px; font-size: 12px; }
</style>
