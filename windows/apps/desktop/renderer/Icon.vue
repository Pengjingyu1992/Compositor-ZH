<script setup lang="ts">
defineProps<{ name: string }>();
const paths: Record<string, string[]> = {
  move: ['M4 3v16l4-4 4 6 3-2-4-6 6-1Z'],
  brush: ['m14 4 3-2 5 5-2 3-8 8-5-5Z', 'M7 13c-3 0-4 2-4 5 0 1-1 2-2 3 5 1 9-1 9-5'],
  eraser: ['m14 3 7 7-10 11H6l-5-5Z', 'm7 10 7 7', 'M11 21h11'],
  pan: ['M8 11V5a2 2 0 0 1 4 0v6-8a2 2 0 0 1 4 0v8-6a2 2 0 0 1 4 0v7c0 6-3 9-8 9-2 0-3-1-4-3l-5-7c-1-2 2-4 4-2l1 2'],
  open: ['M3 8V5h7l2 3h9v11H3Z', 'M3 11h18'],
  new: ['M14 2H5v20h14V7Z', 'M14 2v5h5', 'M8 14h8', 'M12 10v8'],
  save: ['M3 3h15l3 3v15H3Z', 'M7 3v6h9V3', 'M7 21v-8h10v8'],
  undo: ['m8 4-5 5 5 5', 'M3 9h11a7 7 0 0 1 0 14'],
  redo: ['m16 4 5 5-5 5', 'M21 9H10a7 7 0 0 0 0 14'],
  close: ['m6 6 12 12', 'M6 18 18 6'],
  plus: ['M12 5v14', 'M5 12h14'],
  minus: ['M5 12h14'],
  fit: ['M8 3H3v5', 'M16 3h5v5', 'M3 16v5h5', 'M21 16v5h-5', 'M7 7h10v10H7Z'],
  search: ['M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0', 'm16 16 6 6'],
  info: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0', 'M12 11v6', 'M12 7h.01'],
  eye: ['M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7Z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0'],
  eyeOff: ['m3 3 18 18', 'M9 5c6-2 11 5 13 7l-3 4', 'M6 6c-2 2-4 5-4 6 3 4 8 9 15 5'],
  layer: ['m12 3 10 5-10 5L2 8Z', 'm2 12 10 5 10-5', 'm2 16 10 5 10-5'],
  folder: ['M2 6h8l2 3h10v11H2Z'],
  mask: ['M3 4h18v16H3Z', 'M17 12a5 5 0 1 1-10 0 5 5 0 0 1 10 0'],
  adjustment: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0', 'M12 2v20', 'M12 6h5', 'M12 10h8', 'M12 14h8', 'M12 18h5'],
  effects: ['m12 2 2 7 7 3-7 3-2 7-2-7-7-3 7-3Z'],
  trash: ['M3 6h18', 'M9 6V3h6v3', 'M5 6l1 15h12l1-15', 'M10 10v7', 'M14 10v7'],
  duplicate: ['M8 8h13v13H8Z', 'M16 8V3H3v13h5'],
  chevron: ['m9 5 7 7-7 7'],
  swap: ['m4 7 4-4-4 4 4 4', 'M4 7h16', 'm20 17-4 4 4-4-4-4', 'M20 17H4'],
  flipH: ['M12 2v20', 'M3 17V7l6 10Z', 'M21 17V7l-6 10Z'],
  flipV: ['M2 12h20', 'M7 3h10L7 9Z', 'M7 21h10l-10-6Z'],
  up: ['m6 14 6-6 6 6'],
  down: ['m6 10 6 6 6-6']
};
</script>
<template>
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path v-for="(d,i) in paths[name] ?? paths.info" :key="i" :d="d"/></svg>
</template>
