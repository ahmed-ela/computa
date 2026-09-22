import { defineConfig } from 'vite';
import { octane } from 'octane/compiler/vite';

export default defineConfig(({ command }) => ({
  base: './',
  plugins: [
    octane(),
    {
      name: 'local-codex-production-csp',
      transformIndexHtml(html) {
        if (command !== 'build') return html;
        return html.replace(
          "connect-src 'self' http://127.0.0.1:* ws://127.0.0.1:*",
          "connect-src 'none'",
        );
      },
    },
  ],
  build: {
    outDir: '../Sources/LocalCodex/Resources/WebUI',
    emptyOutDir: true,
    sourcemap: false,
    target: 'safari17',
  },
}));
