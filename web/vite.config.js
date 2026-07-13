import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Relative base so the built bundle works no matter how server.js serves it.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 1500 },
  // `npm run dev` proxies the API to the running node server for local dev.
  server: { port: 5173, proxy: { '/api': 'http://localhost:4747' } },
});
