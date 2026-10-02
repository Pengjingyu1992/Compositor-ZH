import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { fileURLToPath } from 'node:url';

export default defineConfig({
  root: fileURLToPath(new URL('./apps/desktop/renderer/', import.meta.url)),
  base: './',
  plugins: [vue()],
  build: {
    outDir: fileURLToPath(new URL('./out/renderer/', import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
    target: 'es2022'
  }
});
