import { defineConfig } from 'vite';
import { octane } from 'octane/compiler/vite';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig(({ command }) => ({
  base: './',
  plugins: [
    octane(),
    tailwindcss(),
    {
      name: 'heydash-production-csp',
      generateBundle(_options, bundle) {
        // Native shadcn ports must not silently introduce a second UI runtime.
        for (const output of Object.values(bundle)) {
          if (output.type !== 'chunk') continue;
          for (const moduleID of Object.keys(output.modules)) {
            if (/[/\\]node_modules[/\\](?:react|react-dom)[/\\]/.test(moduleID)) {
              this.error(`Unexpected React runtime in the Octane client: ${moduleID}`);
            }
          }
        }
      },
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
    outDir: '../Sources/HeyDash/Resources/WebUI',
    emptyOutDir: true,
    sourcemap: false,
    target: 'safari17',
  },
}));
