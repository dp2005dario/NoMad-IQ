// Construye mobile/assets/flight3d/vuelo.html: la plantilla (vuelo.html) con
// three.js y vuelo.js empaquetados DENTRO. Así la app no descarga nada de
// Internet (ni CDN ni fuentes): funciona en el avión, en modo avión.
//
// Uso (desde mobile/tool/flight3d, con Node 20+):
//   npm install
//   npm run build
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { build } from 'esbuild';

const out = await build({
  entryPoints: [new URL('./vuelo.js', import.meta.url).pathname],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2020'],
  write: false,
  legalComments: 'none',
  // La licencia de three.js (MIT) va arriba del todo, como pide.
  banner: { js: '/* three.js r160 · MIT License · Copyright © 2010-2023 three.js authors */' },
});
let js = out.outputFiles[0].text;
// Dentro de <script> no puede aparecer "</script" literal.
js = js.replaceAll('</script', '<\\/script');
const html = readFileSync(new URL('./vuelo.html', import.meta.url), 'utf8')
  .replace('/*NQ_BUNDLE*/', () => js);
const dir = new URL('../../assets/flight3d/', import.meta.url);
mkdirSync(dir, { recursive: true });
writeFileSync(new URL('vuelo.html', dir), html);
console.log(`vuelo.html: ${(html.length / 1024).toFixed(0)} KB`);
