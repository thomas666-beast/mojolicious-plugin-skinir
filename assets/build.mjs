#!/usr/bin/env node
// Bundles assets/src/*.js into public/skinir/app.js and compiles assets/skinir.css with Tailwind 4.
//
//   npm install        (tailwindcss + esbuild, see package.json)
//   npm run build
//
// Re-run after adding Tailwind classes to src/*.js or to the templates.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { compile } from 'tailwindcss';
import { transform } from 'esbuild';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const out = path.join(root, 'lib/Mojolicious/Plugin/Skinir/resources/public/skinir');
const tplDir = path.join(root, 'lib/Mojolicious/Plugin/Skinir/resources/templates/skinir');
const require = createRequire(import.meta.url);

// ---- JS bundle -------------------------------------------------------------------
const srcDir = path.join(here, 'src');
const parts = (await fs.readdir(srcDir)).filter(f => f.endsWith('.js')).sort();
const sources = await Promise.all(parts.map(f => fs.readFile(path.join(srcDir, f), 'utf8')));
await fs.mkdir(out, { recursive: true });
await fs.writeFile(path.join(out, 'app.js'), sources.join('\n'));
console.log(`app.js  <- ${parts.join(', ')}`);

// ---- Tailwind --------------------------------------------------------------------
const twDir = path.dirname(require.resolve('tailwindcss/package.json'));
const input = await fs.readFile(path.join(here, 'skinir.css'), 'utf8');

const compiler = await compile(input, {
  base: here,
  from: path.join(here, 'skinir.css'),
  async loadStylesheet(id, base) {
    const file = id === 'tailwindcss' ? path.join(twDir, 'index.css')
      : id.startsWith('tailwindcss/') ? path.join(twDir, id.slice('tailwindcss/'.length) + (id.endsWith('.css') ? '' : '.css'))
      : path.resolve(base, id);
    return { path: file, base: path.dirname(file), content: await fs.readFile(file, 'utf8') };
  },
});

const scan = [...sources];
for (const f of await fs.readdir(tplDir)) scan.push(await fs.readFile(path.join(tplDir, f), 'utf8'));
const candidates = new Set();
for (const text of scan) for (const tok of text.split(/[\s"'`<>=;{},\\|]+/)) if (tok) candidates.add(tok);

const css = compiler.build([...candidates]);
const min = await transform(css, { loader: 'css', minify: true });
await fs.writeFile(path.join(out, 'skinir.css'), min.code);
console.log(`skinir.css  ${(min.code.length / 1024).toFixed(1)} KB from ${candidates.size} candidates`);
