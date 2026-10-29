<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, useId } from 'vue';
import { localizedMessages } from '../../../packages/locales';
import { parityMessages } from './parity-labels';
import { CANVAS_PRESETS, CANVAS_UNITS, CANVAS_MAX_PIXELS, canvasPixels, canvasDimensionText } from '../../../packages/comp-bridge/new-canvas.mjs';
import Icon from './Icon.vue';
import type { Language, NewCanvasDefinition } from './types';

const props = defineProps<{ language: Language; disabled: boolean; modal?: boolean; error?: string }>();
const emit = defineEmits<{ create: [value: NewCanvasDefinition]; close: []; open: []; image: [] }>();
const t = computed(() => localizedMessages(props.language, 'windows'));
const labels = computed(() => parityMessages[props.language].newCanvas);
const id = useId(), widthInput = ref<HTMLInputElement>();
const width = ref('1920'), height = ref('1080'), unit = ref('px'), resolution = ref(72);
const background = ref<NewCanvasDefinition['background']>('transparent'), custom = ref(false), clipboardSuggested = ref(false);
let touched = false, alive = true;
// Preserve whole pixels when a unit is displayed with only two decimal places.
type PixelCache = { width: string; height: string; unit: string; resolution: number; pixels: [number, number] };
const cache = ref<PixelCache>();
const pixels = computed(() => {
  const saved = cache.value;
  if (saved && saved.width === width.value && saved.height === height.value && saved.unit === unit.value && saved.resolution === resolution.value) return saved.pixels;
  return [canvasPixels(width.value, unit.value, resolution.value), canvasPixels(height.value, unit.value, resolution.value)];
});
const dimensions = computed(() => pixels.value.every(n => n !== null) ? pixels.value as [number, number] : null);
const valid = computed(() => !!dimensions.value && dimensions.value[0] * dimensions.value[1] <= CANVAS_MAX_PIXELS);
const errorText = computed(() => dimensions.value ? valid.value ? '' : labels.value.limit : unit.value === 'px' ? labels.value.invalidSize : labels.value.invalidPrint);
const allPresets = CANVAS_PRESETS.flatMap(group => group.items);
const selectedPreset = computed(() => custom.value ? '' : allPresets.find(preset => dimensions.value?.[0] === preset.width && dimensions.value?.[1] === preset.height)?.id ?? '');
const quickPresets = computed(() => [
  { id: '1080p', title: '1080P', width: 1920, height: 1080 },
  { id: '4k', title: '4K', width: 3840, height: 2160 },
  { id: 'square', title: labels.value.square, width: 1080, height: 1080 }
]);
const matchesQuick = computed(() => quickPresets.value.some(preset => dimensions.value?.[0] === preset.width && dimensions.value?.[1] === preset.height));
function presetTitle(preset: { id: string; title: string }) {
  const titles: Record<string, string> = { square: labels.value.instagramSquare, portrait: labels.value.instagramPortrait, story: labels.value.instagramStory, youtube: labels.value.youtube };
  return titles[preset.id] ?? preset.title;
}
const unitNames = computed(() => [labels.value.pixels, labels.value.inches, labels.value.centimeters, labels.value.millimeters]);
const ratio = computed(() => {
  if (!dimensions.value) return '';
  const [w, h] = dimensions.value; let a = w, b = h;
  while (b) [a, b] = [b, a % b];
  return `${w / a}:${h / a}`;
});
const preview = computed(() => {
  if (!dimensions.value) return { x: 0, y: 0, width: 0, height: 0 };
  const [w, h] = dimensions.value, scale = Math.min(160 / w, 132 / h);
  return { x: (160 - w * scale) / 2, y: (132 - h * scale) / 2, width: w * scale, height: h * scale };
});
function touch() { touched = true; clipboardSuggested.value = false; }
function edited() { touch(); cache.value = undefined; }
function setPixels(w: number, h: number, user = true) {
  if (user) touch();
  width.value = canvasDimensionText(w, unit.value, resolution.value);
  height.value = canvasDimensionText(h, unit.value, resolution.value);
  custom.value = false;
  cache.value = { width: width.value, height: height.value, unit: unit.value, resolution: resolution.value, pixels: [w, h] };
}
function choosePreset(value: string) {
  const preset = allPresets.find(item => item.id === value);
  if (preset) setPixels(preset.width, preset.height);
  else { touch(); custom.value = true; widthInput.value?.focus(); }
}
function changeUnit(value: string) {
  const current = dimensions.value; touch(); unit.value = value;
  if (current) {
    const wasCustom = custom.value;
    setPixels(...current); custom.value = wasCustom;
  } else cache.value = undefined;
}
function swap() {
  const current = dimensions.value; touch(); [width.value, height.value] = [height.value, width.value];
  cache.value = current ? { width: width.value, height: height.value, unit: unit.value, resolution: resolution.value, pixels: [current[1], current[0]] } : undefined;
}
function create() {
  if (valid.value && !props.disabled && dimensions.value) emit('create', { width: dimensions.value[0], height: dimensions.value[1], resolution: resolution.value, background: background.value });
}
onMounted(async () => {
  await nextTick();
  if (props.modal || document.activeElement === document.body) widthInput.value?.focus();
  try {
    const size = await window.editor.canvasClipboardSize();
    if (alive && !touched && size && Number.isInteger(size.width) && Number.isInteger(size.height) && size.width > 0 && size.height > 0 && size.width <= 30000 && size.height <= 30000 && size.width * size.height <= CANVAS_MAX_PIXELS) {
      setPixels(size.width, size.height, false); clipboardSuggested.value = true;
    }
  } catch { /* Clipboard access is optional; normal defaults remain available. */ }
});
onUnmounted(() => { alive = false; });
</script>

<template>
  <div class="new-canvas-view" :class="{ 'canvas-modal': modal }">
    <form class="canvas-card" :role="modal ? 'dialog' : undefined" :aria-modal="modal ? true : undefined" :aria-label="t.editor.newCanvas" @submit.prevent="create">
      <fieldset class="canvas-fields" :disabled="disabled">
        <div class="canvas-main">
          <section class="canvas-settings">
            <header><h2>{{ t.editor.newCanvas }}</h2><p class="canvas-intro">{{ labels.intro }}</p></header>
            <section class="preset-section">
              <div class="preset-heading"><span>{{ labels.commonSizes }}</span><label class="preset-menu"><span class="sr-only">{{ labels.presetSizes }}</span><Icon name="more"/><select :value="selectedPreset" :aria-label="labels.presetSizes" data-testid="canvas-preset" @change="choosePreset(($event.target as HTMLSelectElement).value)"><option value="">{{ labels.custom }}</option><optgroup v-for="group in CANVAS_PRESETS" :key="group.group" :label="labels[group.group as 'screens' | 'devices' | 'social']"><option v-for="preset in group.items" :key="preset.id" :value="preset.id">{{ presetTitle(preset) }}</option></optgroup></select></label></div>
              <div class="canvas-presets"><button v-for="preset in quickPresets" :key="preset.id" type="button" :aria-pressed="!custom && dimensions?.[0] === preset.width && dimensions?.[1] === preset.height" @click="setPixels(preset.width, preset.height)">{{ preset.title }}</button><button type="button" :aria-pressed="custom || !matchesQuick" data-testid="canvas-custom" @click="choosePreset('')">{{ labels.custom }}</button></div>
            </section>
            <section class="canvas-size">
              <div class="dimension-labels"><label :for="id+'-width'">{{ t.editor.width }}</label><span></span><div><label :for="id+'-height'">{{ t.editor.height }}</label><select :value="unit" :aria-label="labels.units" data-testid="canvas-unit" @change="changeUnit(($event.target as HTMLSelectElement).value)"><option v-for="(value,i) in CANVAS_UNITS" :key="value" :value="value">{{ unitNames[i] }}</option></select></div></div>
              <div class="new-dimensions"><div class="canvas-dimension"><input :id="id+'-width'" ref="widthInput" v-model="width" type="text" inputmode="decimal" maxlength="32" required autofocus data-testid="canvas-width" @input="edited"><span>{{ unit }}</span></div><button type="button" class="canvas-swap" :aria-label="t.editor.swap" :title="t.editor.swap" @click="swap"><Icon name="swap"/></button><div class="canvas-dimension"><input :id="id+'-height'" v-model="height" type="text" inputmode="decimal" maxlength="32" required data-testid="canvas-height" @input="edited"><span>{{ unit }}</span></div></div>
            </section>
            <div class="canvas-choices"><label>{{ labels.background }}<select v-model="background" data-testid="canvas-background" @change="touch"><option value="transparent">{{ labels.transparent }}</option><option value="white">{{ labels.white }}</option><option value="black">{{ labels.black }}</option></select></label><label>{{ labels.resolution }}<select v-model.number="resolution" data-testid="canvas-resolution" @change="edited"><option :value="72">72 DPI</option><option :value="300">300 DPI</option></select></label></div>
            <p v-if="errorText" class="canvas-error" role="alert">{{ errorText }}</p><p v-else-if="clipboardSuggested" class="canvas-clipboard">{{ labels.clipboardSize }}</p>
            <p v-if="error" class="canvas-error" role="alert">{{ error }}</p>
          </section>
          <div class="canvas-divider"></div>
          <section class="canvas-preview">
            <div class="preview-graphic" aria-hidden="true"><svg v-if="dimensions" viewBox="0 0 160 132"><defs><pattern :id="id+'-checker'" width="16" height="16" patternUnits="userSpaceOnUse"><rect width="16" height="16" fill="#3d3d3d"/><path d="M0 0h8v8H0ZM8 8h8v8H8Z" fill="#4d4d4d"/></pattern></defs><rect v-bind="preview" rx="2" :fill="background === 'transparent' ? `url(#${id}-checker)` : background === 'white' ? '#fff' : '#000'" stroke="#ffffff66" stroke-width="1" vector-effect="non-scaling-stroke"/></svg><div v-else class="preview-invalid"><Icon name="marquee"/><span>{{ labels.preview }}</span></div></div>
            <template v-if="dimensions"><span class="preview-dimensions" data-testid="canvas-preview-dimensions" aria-live="polite">{{ dimensions[0] }} × {{ dimensions[1] }} px</span><span class="preview-ratio" data-testid="canvas-preview-ratio">{{ ratio }}</span></template>
          </section>
        </div>
        <footer class="canvas-actions"><div v-if="!modal" class="canvas-file-actions"><button type="button" @click="emit('open')"><Icon name="open"/>{{ t.open }}</button><button type="button" @click="emit('image')"><Icon name="image"/>{{ t.editor.importImage }}</button></div><button v-else type="button" class="canvas-cancel" @click="emit('close')">{{ t.editor.cancel }}</button><button class="primary canvas-create" type="submit" :disabled="!valid" data-testid="create-canvas">{{ labels.create }}<Icon name="arrowRight"/></button></footer>
      </fieldset>
    </form>
    <p v-if="!modal" class="canvas-drop-tip">{{ labels.dropTip }}</p>
  </div>
</template>

<style scoped>
.new-canvas-view { width: 100%; max-width: 560px; margin-block: auto; container: new-canvas / inline-size; flex-shrink: 0; }
.canvas-modal { width: min(560px,calc(100vw - 48px)); }
.canvas-card { width: 100%; padding: 18px; border: 1px solid var(--border); border-radius: 12px; background: var(--surface-raised); box-shadow: 0 6px 28px var(--shadow); }
.canvas-modal .canvas-card { max-height: calc(100dvh - 48px); overflow: auto; }
.canvas-fields { min-width: 0; margin: 0; padding: 0; border: 0; }
.canvas-main { display: grid; grid-template-columns: minmax(0,1fr) 1px 148px; gap: 14px; align-items: center; }
.canvas-settings { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.canvas-card h2 { margin: 0; font-size: 18px; line-height: 1.4; font-weight: 600; }
.canvas-card .canvas-intro { margin: 5px 0 0; font-size: 11px; line-height: 1.5; color: var(--muted); }
.preset-heading { display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px; font-size: 11px; font-weight: 500; }
.preset-menu { position: relative; display: grid; place-items: center; width: 26px; height: 22px; border-radius: 4px; }
.preset-menu svg { width: 18px; height: 18px; color: var(--muted); stroke-width: 2.5; }
.preset-menu select { position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0; cursor: pointer; }
.preset-menu:focus-within { outline: 2px solid var(--accent); outline-offset: 2px; }
.canvas-presets { display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap: 6px; }
.canvas-presets button { min-width: 0; min-height: 28px; padding: 3px 6px; font-size: 11px; border-radius: 6px; white-space: nowrap; }
.canvas-presets button[aria-pressed=true] { background: var(--selection); border-color: var(--accent); color: var(--text); font-weight: 600; }
.canvas-size { display: grid; gap: 5px; }
.dimension-labels, .canvas-card .new-dimensions { display: grid; grid-template-columns: minmax(0,1fr) 26px minmax(0,1fr); align-items: center; gap: 8px; margin: 0; }
.dimension-labels { min-height: 22px; font-size: 11px; font-weight: 500; }
.dimension-labels > div { display: flex; align-items: center; justify-content: space-between; gap: 6px; }
.dimension-labels select { width: 100px; min-width: 96px; height: 22px; padding: 1px 4px; font-size: 11px; }
.canvas-dimension { display: flex; align-items: center; gap: 6px; min-width: 0; height: 30px; padding: 0 10px; border: 1px solid var(--border); border-radius: 6px; background: var(--control); }
.canvas-dimension:focus-within { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
.new-canvas-view .canvas-card .canvas-dimension input { flex: 1; width: 0; min-width: 0; height: 28px; margin: 0; padding: 0; border: 0; border-radius: 0; background: transparent; font-size: 12px; outline: none; }
.canvas-dimension > span { font-size: 11px; color: var(--muted); }
.canvas-card .canvas-swap { min-height: 30px; width: 26px; padding: 3px; margin: 0; border: 0; background: transparent; }
.canvas-swap svg { width: 17px; height: 17px; }
.canvas-choices { display: grid; grid-template-columns: minmax(0,1fr) minmax(0,1fr); gap: 42px; }
.canvas-choices label { display: flex; flex-direction: column; gap: 5px; font-size: 11px; font-weight: 500; }
.canvas-choices select { height: 30px; width: 100%; font-size: 12px; border-radius: 6px; }
.canvas-divider { width: 1px; align-self: stretch; background: var(--border); }
.canvas-preview { display: flex; flex-direction: column; align-items: center; gap: 4px; color: var(--muted); font-variant-numeric: tabular-nums; }
.preview-graphic { display: flex; align-items: center; justify-content: center; width: 100%; height: 132px; margin-bottom: 4px; }
.preview-graphic svg { width: 100%; height: 100%; overflow: visible; filter: drop-shadow(0 4px 7px var(--shadow)); }
.preview-dimensions { font-size: 11px; font-weight: 500; white-space: nowrap; }
.preview-ratio { font-size: 10px; }
.preview-invalid { display: flex; flex-direction: column; align-items: center; gap: 10px; font-size: 11px; text-align: center; }
.preview-invalid svg { width: 32px; height: 32px; }
.canvas-card .canvas-error { margin: 0; color: var(--error); font-size: 11px; }
.canvas-card .canvas-clipboard { margin: 0; color: var(--muted); font-size: 10px; }
.canvas-actions { display: flex; align-items: center; gap: 8px; border-top: 1px solid var(--border); padding-top: 14px; margin-top: 14px; }
.canvas-file-actions { display: flex; align-items: center; gap: 8px; }
.canvas-actions button { min-height: 30px; padding: 4px 12px; border-radius: 6px; font-size: 11px; font-weight: 500; }
.canvas-actions svg { width: 15px; height: 15px; }
.canvas-create, .canvas-cancel { margin-left: auto; }
.canvas-cancel + .canvas-create { margin-left: 0; }
.canvas-card:has(fieldset:disabled) { opacity: .65; }
.canvas-drop-tip { margin: 12px 0 0; text-align: center; color: var(--muted); font-size: 10px; }
@container new-canvas (max-width: 528px) {
  .canvas-main { grid-template-columns: minmax(0,1fr); }
  .canvas-divider { display: none; }
  .preview-graphic { height: 100px; }
  .canvas-actions:has(.canvas-file-actions) { flex-direction: column; align-items: stretch; }
  .canvas-file-actions { display: grid; grid-template-columns: 1fr 1fr; }
  .canvas-file-actions + .canvas-create { width: 100%; margin: 0; }
}
</style>
