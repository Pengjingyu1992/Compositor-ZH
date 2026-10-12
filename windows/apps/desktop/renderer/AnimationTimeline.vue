<script setup lang="ts">
import { computed } from 'vue';
import type { Language, AnimationTrack } from './types';
const props = defineProps<{ language: Language; track?: AnimationTrack; active?: string; disabled: boolean; playing: boolean }>();
const emit = defineEmits<{ frame: [id: string]; play: []; edit: [op: Record<string, unknown>]; export: [] }>();
const labels = computed(() => props.language === 'en' ? {
  title: 'Animation', create: 'Create animation', hint: 'Turn this canvas into editable GIF frames', play: 'Play', pause: 'Pause',
  add: 'New frame', duplicate: 'Duplicate frame', remove: 'Delete frame', earlier: 'Earlier', later: 'Later', duration: 'Duration (ms)',
  loops: 'Repeats (−1 once, 0 forever)', frame: 'Frame', export: 'Export GIF…'
} : {
  title: '动画', create: '创建动画', hint: '把当前画布变为可编辑的 GIF 帧', play: '播放', pause: '暂停',
  add: '新建帧', duplicate: '复制帧', remove: '删除帧', earlier: '前移', later: '后移', duration: '时长（毫秒）',
  loops: '重复次数（−1 单次，0 无限）', frame: '帧', export: '导出 GIF…'
});
const index = computed(() => props.track?.frames.findIndex(f => f.groupID === props.active) ?? -1);
function edit(action: string, extra: Record<string, unknown> = {}) { emit('edit', { kind: 'animation', action, frameID: props.active, name: labels.value.frame + ' ' + (action==='create'?1:index.value+2), layerName: labels.value.frame, ...extra }); }
function timing(event: Event, loops = false) {
  const input = event.target as HTMLInputElement, value = Number(input.value);
  if (!Number.isFinite(value)) return;
  edit(loops ? 'loops' : 'duration', { value: loops ? Math.min(65535, Math.max(-1, Math.round(value))) : Math.min(655350, Math.max(10, Math.round(value / 10) * 10)) });
}
</script>
<template>
  <section class="animation-timeline" :aria-label="labels.title">
    <div class="animation-actions" v-if="track">
      <strong>{{ labels.title }}</strong>
      <button :disabled="disabled && !playing" @click="emit('play')">{{ playing ? labels.pause : labels.play }}</button>
      <button :disabled="disabled" @click="edit('add')">{{ labels.add }}</button>
      <button :disabled="disabled" @click="edit('duplicate')">{{ labels.duplicate }}</button>
      <button :disabled="disabled || track.frames.length < 2" @click="edit('delete')">{{ labels.remove }}</button>
      <button :disabled="disabled || index < 1" @click="edit('move', {direction:-1})">{{ labels.earlier }}</button>
      <button :disabled="disabled || index === track.frames.length-1" @click="edit('move', {direction:1})">{{ labels.later }}</button>
      <label>{{ labels.duration }}<input type="number" min="10" max="655350" step="10" :disabled="disabled" :value="track.frames[index]?.durationMS ?? 100" @change="timing($event)"></label>
      <label>{{ labels.loops }}<input type="number" min="-1" max="65535" step="1" :disabled="disabled" :value="track.loopCount" @change="timing($event,true)"></label>
      <button :disabled="disabled" @click="emit('export')">{{ labels.export }}</button>
    </div>
    <div class="animation-actions" v-else>
      <button :disabled="disabled" @click="edit('create')">{{ labels.create }}</button><span>{{ labels.hint }}</span>
    </div>
    <div v-if="track" class="animation-frames" role="group" :aria-label="labels.title">
      <button v-for="(frame, i) in track.frames" :key="frame.groupID" :disabled="disabled" :aria-pressed="frame.groupID===active" @click="emit('frame',frame.groupID)">
        {{ labels.frame }} {{ i+1 }}<small>{{ frame.durationMS }} ms</small>
      </button>
    </div>
  </section>
</template>
