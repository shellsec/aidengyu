'use strict';

const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const pngToIcoModule = require('png-to-ico');

const pngToIco = pngToIcoModule.default || pngToIcoModule;
const output = path.join(__dirname, '..', 'assets', 'app.ico');
const svg = Buffer.from(`
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect x="20" y="20" width="216" height="216" rx="52" fill="#111817"/>
  <circle cx="128" cy="128" r="76" fill="#050707" stroke="#6e7672" stroke-width="6"/>
  <circle cx="128" cy="128" r="57" fill="#2ed164"/>
  <ellipse cx="106" cy="101" rx="17" ry="10" fill="#ffffff" fill-opacity=".52"/>
</svg>
`);

async function main() {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const images = await Promise.all([16, 24, 32, 48, 64, 128, 256].map((size) =>
    sharp(svg).resize(size, size).png().toBuffer()));
  fs.writeFileSync(output, await pngToIco(images));
  process.stdout.write(`${output}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
