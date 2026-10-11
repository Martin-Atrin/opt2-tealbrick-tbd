import { build } from 'esbuild';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const at = (path) => resolve(root, path);
const platformPlugin = { name: 'tbd-platform', setup(b) {
  b.onResolve({filter: /^electron$/}, () => ({path: at('src/tbd/platform.ts')}));
  b.onResolve({filter: /^\.\/dictation$/}, a => a.importer.endsWith('/main/ipc.ts') ? ({path: at('src/tbd/dictation.ts')}) : undefined);
  b.onResolve({filter: /^\.\/voice$/}, a => a.importer.endsWith('/main/ipc.ts') ? ({path: at('src/tbd/voice.ts')}) : undefined);
}};
/** Bundle the TBD Chat helper (Electron main replaced by src/tbd/platform.ts). */
export async function buildHelper(outfile = at('out/tbd/helper.cjs')) {
  await build({ entryPoints: [at('src/tbd/helper.ts')], outfile, bundle: true, platform: 'node', format: 'cjs', target: 'node22', plugins: [platformPlugin], alias: { '@shared': at('src/shared') }, logLevel: 'error' });
  return outfile;
}
