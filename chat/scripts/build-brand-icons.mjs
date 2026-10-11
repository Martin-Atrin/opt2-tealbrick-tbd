// Mechanical macOS icon packaging; the supplied artwork is not redrawn.
import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const source = `${root}src/renderer/public/brand/teal-brick-colour.png`;
const iconset = `${root}build/teal-brick-colour.iconset`;
mkdirSync(iconset, { recursive: true });
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const pixels = String(size * scale);
    execFileSync('/usr/bin/sips', ['-z', pixels, pixels, source, '--out', `${iconset}/icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`], { stdio: 'ignore' });
  }
}
execFileSync('/usr/bin/sips', ['-z', '1024', '1024', source, '--out', `${root}build/teal-brick-colour.png`], { stdio: 'ignore' });
execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', `${root}build/teal-brick-colour.icns`]);
