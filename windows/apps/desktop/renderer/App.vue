<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted, nextTick } from 'vue';
import { messages } from '../../../packages/locales';
import { createPreviewRenderer } from '../../../packages/editor-adapter/render';
import type { Language, ViewerProject, OpenResult, LayerRow } from './types';

const language = ref<Language>('zh-Hans'), version = ref(''), project = ref<ViewerProject>();
const selected = ref<LayerRow>(), busy = ref(false), error = ref(''), settingError = ref(false);
const stage = ref<HTMLDivElement>(), canvas = ref<HTMLCanvasElement>(), zoom = ref(1);
const source = ref<'engine' | 'saved' | 'none'>('none'), extraIssues = ref<string[]>([]);
const t = computed(() => messages[language.value]);
const issues = computed(() => [...(project.value?.analysis.issues ?? []), ...extraIssues.value]);
const rows = computed(() => [...(project.value?.analysis.rows ?? [])].reverse());
const previewURL = computed(() => project.value?.urls['QuickLook/Preview.jpg']);
const formattedProperties = computed(() => {
  if (!selected.value || !project.value) return '';
  const original = project.value.manifest.layers.find(l => l.id === selected.value?.id);
  return JSON.stringify(original, null, 2);
});
let renderer: ReturnType<typeof createPreviewRenderer> | undefined, epoch = 0;
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
  if (!result.project) return;
  const own = ++epoch;
  renderer?.dispose(); renderer = undefined;
  project.value = result.project; selected.value = undefined; error.value = ''; extraIssues.value = [];
  source.value = project.value.analysis.issues.length ? (project.value.preview ? 'saved' : 'none') : 'engine';
  await nextTick(); fit();
  if (source.value === 'engine' && canvas.value) {
    renderer = createPreviewRenderer();
    try {
      await renderer.render(project.value, canvas.value, () => {
        if (epoch !== own) return;
        extraIssues.value = ['gpu']; fallback();
      });
    } catch (e) {
      if (epoch !== own) return;
      extraIssues.value = [(e as Error).message === 'asset' ? 'asset' : 'gpu']; fallback();
    }
  }
}
async function open() {
  if (busy.value) return;
  busy.value = true;
  try { await accept(await window.viewer.open()); } catch { error.value = 'read'; } finally { busy.value = false; }
}
async function changeLanguage(event: Event) {
  const value = (event.target as HTMLSelectElement).value as Language;
  try { const result = await window.viewer.language(value); language.value = result.language; document.documentElement.lang = result.language; settingError.value = false; }
  catch { settingError.value = true; }
}
function onKey(event: KeyboardEvent) {
  if (event.ctrlKey && ['s', 'z', 'y'].includes(event.key.toLowerCase())) event.preventDefault();
  if (event.ctrlKey && event.key === '+') { event.preventDefault(); scale(1.25); }
  if (event.ctrlKey && event.key === '-') { event.preventDefault(); scale(.8); }
}
function wheel(event: WheelEvent) { if (event.ctrlKey) { event.preventDefault(); scale(event.deltaY < 0 ? 1.1 : 1 / 1.1); } }
let drag: { x: number; y: number; left: number; top: number } | undefined;
function panStart(event: PointerEvent) {
  if (!stage.value || event.button !== 0 || !project.value) return;
  drag = { x: event.clientX, y: event.clientY, left: stage.value.scrollLeft, top: stage.value.scrollTop };
  stage.value.setPointerCapture(event.pointerId);
}
function panMove(event: PointerEvent) {
  if (!stage.value || !drag) return;
  stage.value.scrollLeft = drag.left + drag.x - event.clientX;
  stage.value.scrollTop = drag.top + drag.y - event.clientY;
}
onMounted(async () => {
  const settings = await window.viewer.settings(); language.value = settings.language; version.value = settings.version;
  document.documentElement.lang = language.value;
  subscriptions.push(window.viewer.onOpen(open), window.viewer.onFit(fit), window.viewer.onActual(() => zoom.value = 1));
  window.addEventListener('keydown', onKey); window.addEventListener('resize', fit);
  // The packaged app returns canceled; cloud smoke builds can load a synthetic fixture.
  await accept(await window.viewer.fixture());
});
onUnmounted(() => { epoch++; renderer?.dispose(); subscriptions.forEach(stop => stop()); window.removeEventListener('keydown', onKey); window.removeEventListener('resize', fit); });
</script>

<template>
  <div class="shell">
    <header class="toolbar">
      <div class="brand"><img src="./icon.png" alt=""><div><strong>{{ t.title }}</strong><small>{{ t.subtitle }}</small></div></div>
      <button class="primary" :disabled="busy" @click="open">{{ t.open }} <kbd>Ctrl O</kbd></button>
      <span class="document-name">{{ project?.name ?? '' }}</span>
      <div class="zoom-tools"><button :disabled="!project" @click="fit">{{ t.fit }}</button><button :disabled="!project" aria-label="−" @click="scale(.8)">−</button><button :disabled="!project" @click="zoom = 1">{{ Math.round(zoom * 100) }}%</button><button :disabled="!project" aria-label="+" @click="scale(1.25)">+</button></div>
      <select :aria-label="t.language" :value="language" @change="changeLanguage"><option value="zh-Hans">简体中文</option><option value="en">English</option></select>
    </header>
    <div v-if="error || settingError" class="error" role="alert">{{ settingError ? t.settingsError : t.errorTitle + ' · ' + labelError(error) }}<button @click="error = ''; settingError = false">×</button></div>
    <main>
      <section class="workarea">
        <div v-if="issues.length" class="notice">{{ source === 'saved' ? t.fallback : t.detailsOnly }} {{ issues.map(labelIssue).join(' · ') }}</div>
        <div ref="stage" class="stage" @wheel="wheel" @pointerdown="panStart" @pointermove="panMove" @pointerup="drag = undefined" @pointercancel="drag = undefined">
          <div v-if="!project" class="welcome"><img src="./icon.png" alt=""><span class="eyebrow">COMPOSITOR / WINDOWS</span><h1>{{ t.welcome }}</h1><p>{{ t.intro }}</p><button class="primary" :disabled="busy" @click.stop="open">{{ busy ? t.loading : t.open }} →</button><small>{{ t.hint }}</small></div>
          <div v-else-if="source !== 'none'" class="canvas-surround" :style="{ minWidth: project.manifest.width * zoom + 80 + 'px', minHeight: project.manifest.height * zoom + 80 + 'px' }">
            <div class="artboard" :style="{ width: project.manifest.width * zoom + 'px', height: project.manifest.height * zoom + 'px' }">
              <canvas v-if="source === 'engine'" ref="canvas" data-testid="rendered-canvas"></canvas>
              <img v-else :src="previewURL" :alt="t.saved" draggable="false" data-testid="saved-preview">
            </div>
          </div>
          <p v-else class="no-preview">{{ t.noPreview }}</p>
        </div>
        <footer><span>{{ busy ? t.loading : project ? (source === 'engine' ? t.engine : source === 'saved' ? t.saved : t.metadata) : t.sourceNote }}</span><span v-if="project">{{ project.manifest.width.toLocaleString() }} × {{ project.manifest.height.toLocaleString() }} px · sRGB · v{{ project.manifest.version }}</span></footer>
      </section>
      <aside>
        <div class="panel-heading"><strong>{{ t.layers }}</strong><span>{{ rows.length }}</span></div>
        <div class="layer-list"><p v-if="!project" class="muted">{{ t.empty }}</p><button v-for="row in rows" :key="row.id" class="layer-row" :class="{ selected: selected?.id === row.id, hidden: !row.effectiveVisible }" :style="{ paddingLeft: 12 + row.depth * 14 + 'px' }" @click="selected = row"><span aria-hidden="true">{{ row.isGroup ? '▱' : '▧' }}</span><span class="layer-title">{{ row.name }}<small>{{ kind(row) }} · {{ Math.round(row.effectiveOpacity * 100) }}%</small></span><span class="eye" aria-hidden="true">{{ row.effectiveVisible ? '◉' : '○' }}</span></button></div>
        <details v-if="project" class="coverage" open><summary>{{ t.coverage }}</summary><dl><div><dt>{{ t.simple }}</dt><dd>{{ project.analysis.coverage.simple }}</dd></div><div><dt>{{ t.pixels }}</dt><dd>{{ project.analysis.coverage.pixelFallback }}</dd></div><div><dt>{{ t.preview }}</dt><dd>{{ project.analysis.coverage.previewOnly }}</dd></div></dl><small>{{ t.coverageNote }}</small></details>
        <div class="inspector"><strong>{{ t.properties }}</strong><pre v-if="selected">{{ formattedProperties }}</pre><p v-else class="muted">{{ t.noSelection }}</p></div>
      </aside>
    </main>
    <div class="statusbar"><span class="badge">{{ t.readonly }}</span><span>{{ t.version }} {{ version }}</span></div>
  </div>
</template>
