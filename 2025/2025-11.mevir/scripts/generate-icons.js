/**
 * Script to generate PNG icons from SVG for Chrome extension
 * Run with: node scripts/generate-icons.js
 * 
 * Note: This creates placeholder icons. For production, use proper PNG files.
 */

const fs = require('fs');
const path = require('path');

const iconsDir = path.join(__dirname, '..', 'icons');

// Create icons directory if it doesn't exist
if (!fs.existsSync(iconsDir)) {
  fs.mkdirSync(iconsDir, { recursive: true });
}

// SVG template for the icon
const createSvgIcon = (size) => `<?xml version="1.0" encoding="UTF-8"?>
<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#3b82f6;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#1d4ed8;stop-opacity:1" />
    </linearGradient>
  </defs>
  <circle cx="${size/2}" cy="${size/2}" r="${size/2 - 1}" fill="url(#grad)"/>
  <text x="${size/2}" y="${size/2 + size*0.15}" font-family="Arial, sans-serif" font-size="${size*0.5}" font-weight="bold" fill="white" text-anchor="middle">D</text>
</svg>`;

// Generate SVG icons (Chrome can use SVG, but we'll create them for reference)
const sizes = [16, 48, 128];

sizes.forEach(size => {
  const svgContent = createSvgIcon(size);
  const svgPath = path.join(iconsDir, `icon${size}.svg`);
  fs.writeFileSync(svgPath, svgContent);
  console.log(`Created: ${svgPath}`);
});

console.log('\nNote: Chrome requires PNG icons.');
console.log('To convert SVG to PNG, you can use tools like:');
console.log('  - Inkscape: inkscape -w 128 -h 128 icon128.svg -o icon128.png');
console.log('  - ImageMagick: convert -background none icon128.svg icon128.png');
console.log('  - Online tools: svgtopng.com, cloudconvert.com');
console.log('\nFor development, you can use placeholder PNG files or install a converter.');

