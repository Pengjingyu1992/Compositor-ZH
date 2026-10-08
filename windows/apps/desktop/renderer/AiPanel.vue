<script setup lang="ts">
// The assistant panel, docked under the status bar.
//
// It is an ordinary flex child of `.shell`, so the canvas above gives up
// exactly the height the panel takes and nothing is covered. Operations go
// through the same `edit()` and `history()` the toolbar and the menus use, so
// revision binding, the undo stack, and every check the editor applies behave
// the same whether a person or the assistant asked for the change.

import { computed, onMounted, ref, watch } from 'vue';
import { messages } from '../../../packages/locales';
import { checkOperations, canonicalOperation, styledStyle, DEFAULT_ENDPOINT, DEFAULT_MODEL } from '../../../packages/platform/ai-assistant.mjs';
// A text or shape layer is an image plus the parameters it came from, so the
// layer is rendered here with the same code the editor uses for its own text
// and shape tools.
import { renderText, renderShape } from '../../../packages/editor-adapter/styled-layers';
import type { Language, ViewerProject, AssistantLayer, AiSettings, AiAnswer } from './types';

const props = defineProps<{
  language: Language;
  project?: ViewerProject;
  busy: boolean;
  editable: boolean;
  error: string;
  edit: (op: Record<string, unknown>) => unknown;
  history: (direction: string) => unknown;
}>();

const HEAD = 38, MIN = 96, STORE = 'compositor.aiPanel';
const t = computed(() => messages[props.language].ai);
// The dialog reuses the editor's Save and Cancel wording rather than adding
// duplicates to the catalog.
const editor = computed(() => messages[props.language].editor);
const errors = computed(() => messages[props.language].errors);

type Line = { kind: 'you' | 'reply' | 'ok' | 'skip' | 'bad' | 'note'; text: string };
const lines = ref<Line[]>([]);
const prompt = ref('');
const marked = ref('');
const open = ref(true);
const height = ref(216);
const asking = ref(false);
const settingsOpen = ref(false);
const settingsError = ref('');
const testing = ref(false);
const draft = ref({ endpoint: DEFAULT_ENDPOINT, model: DEFAULT_MODEL, key: '' });
const stored = ref<AiSettings>({ endpoint: DEFAULT_ENDPOINT, model: DEFAULT_MODEL, hasKey: false, encryption: true });

const layers = computed<AssistantLayer[]>(() => (props.project?.manifest.layers ?? []).map(layer => ({
  id: layer.id, name: layer.name, isVisible: layer.isVisible, opacity: layer.opacity,
  blendMode: layer.blendMode, isGroup: layer.isGroup,
  adjustment: layer.adjustment ? { kind: String(layer.adjustment.kind) } : undefined,
  maskFile: layer.maskFile
})));
const heading = computed(() => t.value.layerCount.replace('{count}', String(layers.value.length)));
const keyState = computed(() => stored.value.hasKey ? t.value.configured : t.value.keyEmpty);

function say(kind: Line['kind'], text: string) { lines.value.push({ kind, text }); }
function nameOf(id: unknown) { return layers.value.find(l => l.id === id)?.name ?? String(id ?? '').slice(0, 8); }
function describe(op: Record<string, unknown>) {
  const parts = [String(op.kind)];
  if (op.kind === 'styled') {
    parts.push(String(op.type), op.type === 'text' ? JSON.stringify((op.style as { content?: string })?.content ?? '') : String((op.style as { kind?: string })?.kind ?? ''));
    if (op.id) parts.push(nameOf(op.id));
    return parts.join(' ');
  }
  if (Array.isArray(op.ids)) parts.push(op.ids.map(nameOf).join(', '));
  else if (op.id) parts.push(nameOf(op.id));
  if (op.field) parts.push(`${op.field}=${JSON.stringify(op.value)}`);
  if (op.filter) parts.push(String(op.filter));
  if (op.effect) parts.push(String(op.effect));
  if (op.operation) parts.push(String(op.operation), `(${String(op.reference)})`);
  if (op.axis) parts.push(String(op.axis));
  if (op.delta) parts.push(JSON.stringify(op.delta));
  if (op.width) parts.push(`${op.width}×${op.height}`);
  if (op.name) parts.push(`→ ${op.name}`);
  if (op.direction) parts.push(op.direction === 1 ? '↑' : '↓');
  return parts.join(' ');
}
function message(answer: AiAnswer) {
  const key = (answer.error ?? 'network') as keyof typeof t.value.errors;
  return (t.value.errors[key] ?? t.value.errors.network).replace('{status}', String(answer.status ?? ''));
}

// A request the editor refuses changes no revision, exactly like a request that
// had nothing to do, so the outcome is read from three signals: the editor's own
// error, the revision, and whether anything moved.
type Outcome = 'applied' | 'unchanged' | 'rejected';
async function run(op: Record<string, unknown>): Promise<{ outcome: Outcome; detail: string }> {
  // `edit()` returns without doing anything while the editor is busy, so wait
  // for it rather than counting the operation as a no-op.
  for (let i = 0; i < 150 && props.busy; i++) await new Promise(r => setTimeout(r, 40));
  const beforeError = props.error, before = props.project?.revision;
  await Promise.resolve(props.edit(op));
  if (props.error && props.error !== beforeError) {
    const code = props.error as keyof typeof errors.value;
    return { outcome: 'rejected', detail: errors.value[code] ?? props.error };
  }
  if (!props.project || props.project.revision === before) return { outcome: 'unchanged', detail: '' };
  return { outcome: 'applied', detail: '' };
}

// The editor wants a rendered image for a text or shape layer, so it is built
// here from the parameters the model supplied. `id` is always present: the
// editor's own edit() fills in the selected layer when the key is missing,
// which would restyle that layer instead of creating a new one.
async function buildStyled(op: Record<string, unknown>) {
  const type = String(op.type);
  const built = styledStyle(type, op.style, props.project?.manifest);
  if (built.error) return { error: built.error as keyof typeof t.value.reasons };
  const style = built.style as Record<string, any>;
  const png = type === 'text'
    ? await renderText(style)
    : await renderShape(style, style.boxSize[0], style.boxSize[1]);
  return {
    operation: {
      kind: 'styled', id: op.id, type, style, png,
      origin: op.origin ?? [0, 0],
      name: type === 'text' ? String(style.content).slice(0, 64) : messages[props.language].shape
    }
  };
}

async function send() {
  const text = prompt.value.trim();
  if (!text || asking.value || !props.project) return;
  say('you', text);
  prompt.value = '';
  asking.value = true;
  try {
    const answer = await window.ai.complete(text, layers.value);
    if (answer.error) { say('bad', message(answer)); return; }
    if (answer.reply) say('reply', answer.reply);
    const checked = checkOperations(answer.operations ?? [], layers.value);
    for (const rejected of checked.rejected) {
      const reason = t.value.reasons[rejected.reason as keyof typeof t.value.reasons] ?? rejected.reason;
      say('skip', `${describe(rejected.operation)} — ${reason}`);
    }
    if (!checked.accepted.length) {
      if (!checked.rejected.length) say('note', t.value.noOperations);
      return;
    }
    for (const operation of checked.accepted) {
      // The editor matches ids exactly, so anything the model re-cased is put
      // back to the spelling the project uses before it is sent.
      let prepared = canonicalOperation(operation, layers.value) as Record<string, unknown>;
      if (operation.kind === 'styled') {
        const built = await buildStyled(prepared);
        if (built.error) { say('bad', `${describe(operation)} — ${t.value.reasons[built.error] ?? built.error}`); continue; }
        prepared = built.operation as Record<string, unknown>;
      }
      const { outcome, detail } = await run(prepared);
      if (outcome === 'rejected') say('bad', `${describe(operation)} — ${t.value.rejected}：${detail}`);
      else say(outcome === 'applied' ? 'ok' : 'note', `${describe(operation)} — ${outcome === 'applied' ? t.value.applied : t.value.noChange}`);
    }
  } catch { say('bad', t.value.errors.network); }
  finally { asking.value = false; }
}

async function step(direction: 'undo' | 'redo') {
  if (asking.value || !props.project) return;
  asking.value = true;
  try {
    await Promise.resolve(props.history(direction));
    say('note', direction === 'undo' ? t.value.undo : t.value.redo);
  } finally { asking.value = false; }
}

async function loadSettings() {
  try { stored.value = await window.ai.settings(); }
  catch { /* keep the defaults; saving will report the real problem */ }
  draft.value = { endpoint: stored.value.endpoint, model: stored.value.model, key: '' };
}

async function saveSettings() {
  settingsError.value = '';
  try {
    stored.value = await window.ai.save({
      endpoint: draft.value.endpoint.trim(), model: draft.value.model.trim(), key: draft.value.key
    });
    draft.value = { endpoint: stored.value.endpoint, model: stored.value.model, key: '' };
    say('note', t.value.saved);
    settingsOpen.value = false;
  } catch { settingsError.value = t.value.errors.settings; }
}

async function clearKey() {
  settingsError.value = '';
  try {
    stored.value = await window.ai.save({
      endpoint: draft.value.endpoint.trim(), model: draft.value.model.trim(), key: null
    });
    draft.value.key = '';
  } catch { settingsError.value = t.value.errors.settings; }
}

// A one-word round trip tells a wrong key or a wrong endpoint apart from a
// working one without touching the project.
async function testConnection() {
  testing.value = true;
  settingsError.value = '';
  try {
    const answer = await window.ai.complete('ping', []);
    if (answer.error) settingsError.value = message(answer);
    else say('note', `${t.value.testOk} ${stored.value.model}`);
  } finally { testing.value = false; }
}

// Height and folding are remembered so the panel comes back as it was left.
onMounted(() => {
  try {
    const kept = JSON.parse(localStorage.getItem(STORE) ?? '{}');
    if (typeof kept.height === 'number' && kept.height >= MIN) height.value = kept.height;
    if (typeof kept.open === 'boolean') open.value = kept.open;
  } catch { /* a damaged value just means the defaults */ }
  void loadSettings();
  say('note', t.value.ready);
});
watch([height, open], () => {
  try { localStorage.setItem(STORE, JSON.stringify({ height: height.value, open: open.value })); }
  catch { /* storage full or blocked */ }
});
watch(() => props.project?.id, () => { marked.value = ''; });

let anchor = 0;
function grab(event: PointerEvent) {
  anchor = event.clientY;
  (event.target as HTMLElement).setPointerCapture(event.pointerId);
}
function move(event: PointerEvent) {
  if (!anchor) return;
  height.value = Math.max(MIN, Math.min(Math.round(window.innerHeight * .72), height.value + anchor - event.clientY));
  anchor = event.clientY;
}
function release() { anchor = 0; }
</script>

<template>
  <section class="assistant" :style="{ height: (open ? height : HEAD) + 'px' }" :aria-label="t.title">
    <div v-if="open" class="assistant-grip" role="separator" :aria-label="t.title" @pointerdown="grab" @pointermove="move" @pointerup="release" @pointercancel="release"></div>
    <header class="assistant-head">
      <strong>{{ t.title }}</strong>
      <span class="muted">{{ project ? heading : t.noProject }}</span>
      <span class="spacer"></span>
      <span class="muted"><small>{{ keyState }}</small></span>
      <button data-testid="ai-settings" @click="settingsOpen = true">{{ t.settings }}</button>
      <button class="icon-button" :aria-label="open ? t.collapse : t.expand" :title="open ? t.collapse : t.expand" data-testid="ai-fold" @click="open = !open">{{ open ? '▾' : '▴' }}</button>
    </header>
    <div v-if="open" class="assistant-body">
      <div class="assistant-layers">
        <button v-for="layer in layers" :key="layer.id" type="button" class="assistant-chip" :class="{ marked: marked === layer.id, off: !layer.isVisible }" :title="layer.name" data-testid="ai-layer" @click="marked = marked === layer.id ? '' : layer.id">{{ layer.name }}</button>
      </div>
      <div class="assistant-log" role="log">
        <p v-for="(line, index) in lines" :key="index" :class="'line-' + line.kind"><template v-if="line.kind === 'you' || line.kind === 'reply'"><b>{{ line.kind === 'you' ? t.you : t.assistant }}</b> </template>{{ line.text }}</p>
        <p v-if="asking" class="muted">{{ t.working }}</p>
      </div>
      <form class="assistant-row" @submit.prevent="send">
        <input v-model="prompt" :placeholder="t.placeholder" :disabled="asking || !project" :aria-label="t.title" data-testid="ai-prompt" @keydown.ctrl.enter.prevent="send">
        <button class="primary" type="submit" :disabled="asking || !project || !prompt.trim()" data-testid="ai-send">{{ t.send }}</button>
        <button type="button" :disabled="asking || !project || !editable" data-testid="ai-undo" @click="step('undo')">{{ t.undo }}</button>
        <button type="button" :disabled="asking || !project || !editable" data-testid="ai-redo" @click="step('redo')">{{ t.redo }}</button>
      </form>
    </div>
    <div v-if="settingsOpen" class="modal-shade" @click.self="settingsOpen = false">
      <form class="dialog" role="dialog" aria-modal="true" :aria-label="t.settings" @submit.prevent="saveSettings">
        <h2>{{ t.settings }}</h2>
        <p>{{ t.settingsHint }}</p>
        <div class="assistant-settings">
          <label>{{ t.endpoint }}<input v-model="draft.endpoint" :disabled="testing" required :placeholder="DEFAULT_ENDPOINT"></label>
          <label>{{ t.model }}<input v-model="draft.model" :disabled="testing" required :placeholder="DEFAULT_MODEL"></label>
          <label>{{ t.apiKey }}<input v-model="draft.key" type="password" :disabled="testing" autocomplete="off" :placeholder="stored.hasKey ? t.keyStored : t.keyEmpty"></label>
        </div>
        <p class="muted"><small>{{ stored.encryption ? t.keyPrivacy : t.keyNoEncryption }}</small></p>
        <p v-if="settingsError" class="notice-error" role="status">{{ settingsError }}</p>
        <div class="button-row">
          <button type="button" class="icon-button" :disabled="testing || !stored.hasKey" :title="t.cancelKey" :aria-label="t.cancelKey" @click="clearKey">🗑</button>
          <button type="button" :disabled="testing" data-testid="ai-test" @click="testConnection">{{ testing ? t.testRunning : t.test }}</button>
          <span class="spacer"></span>
          <button type="button" @click="settingsOpen = false">{{ editor.cancel }}</button>
          <button class="primary" type="submit" :disabled="testing" data-testid="ai-save-settings">{{ editor.save }}</button>
        </div>
      </form>
    </div>
  </section>
</template>

<style scoped>
.assistant { position: relative; flex: 0 0 auto; display: flex; flex-direction: column; min-height: 0; border-top: 1px solid var(--border); background: var(--surface); }
.assistant-grip { position: absolute; inset: -3px 0 auto 0; height: 7px; cursor: ns-resize; z-index: 1; }
.assistant-grip:hover { background: color-mix(in srgb, var(--accent) 35%, transparent); }
.assistant-head { display: flex; align-items: center; gap: 8px; height: 38px; flex: 0 0 38px; padding: 0 10px; background: var(--surface-raised); }
.assistant-head strong { font-size: 13px; font-weight: 600; }
.assistant-body { flex: 1; display: flex; flex-direction: column; gap: 6px; padding: 6px 10px 8px; min-height: 0; }
.assistant-layers { display: flex; align-items: center; gap: 5px; overflow-x: auto; overflow-y: hidden; flex: 0 0 auto; padding-bottom: 2px; scrollbar-width: thin; }
.assistant-chip { flex: 0 0 auto; padding: 1px 9px; border-radius: 10px; font-size: 12px; white-space: nowrap; }
.assistant-chip.marked { border-color: var(--accent); color: #18392b; background: var(--accent); }
.assistant-chip.off { opacity: .5; text-decoration: line-through; }
.assistant-log { flex: 1; min-height: 0; overflow: auto; padding: 5px 8px; border: 1px solid var(--border); border-radius: 4px; background: var(--canvas); font-size: 12px; line-height: 1.6; }
.assistant-log p { margin: 0; overflow-wrap: anywhere; }
.line-you { color: #bcd7ff; }
.line-reply { color: #d8d8d8; }
.line-ok { color: #a8e0c4; }
.line-skip { color: #f0c98a; }
.line-bad { color: #f0a1a1; }
.line-note { color: var(--muted); }
.assistant-row { display: flex; gap: 6px; align-items: center; flex: 0 0 auto; }
.assistant-row input { flex: 1; min-width: 0; }
.assistant-settings { display: grid; gap: 8px; margin: 10px 0; }
.assistant-settings label { display: grid; gap: 4px; color: #bcbcbc; font-size: 12px; }
.assistant-settings input { width: 100%; }
.notice-error { color: #f0a1a1; }
</style>
