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
    target: 'es2022',
    // Electron supports native light-dark(); a legacy CSS polyfill cannot
    // follow the interface's explicit color-scheme preference.
    cssTarget: 'chrome130'
  }
});
