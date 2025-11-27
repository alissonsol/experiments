/**
 * Creates minimal placeholder PNG icons for Chrome extension
 * These are simple colored squares - replace with proper icons for production
 */

const fs = require('fs');
const path = require('path');

const iconsDir = path.join(__dirname, '..', 'icons');

// Create icons directory if it doesn't exist
if (!fs.existsSync(iconsDir)) {
  fs.mkdirSync(iconsDir, { recursive: true });
}

// Minimal PNG creation (1x1 blue pixel, scaled conceptually)
// This creates a valid PNG file structure
function createMinimalPng(size) {
  // PNG signature
  const signature = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  
  // IHDR chunk (image header)
  const ihdrData = Buffer.alloc(13);
  ihdrData.writeUInt32BE(size, 0);  // width
  ihdrData.writeUInt32BE(size, 4);  // height
  ihdrData.writeUInt8(8, 8);        // bit depth
  ihdrData.writeUInt8(2, 9);        // color type (RGB)
  ihdrData.writeUInt8(0, 10);       // compression
  ihdrData.writeUInt8(0, 11);       // filter
  ihdrData.writeUInt8(0, 12);       // interlace
  
  const ihdrChunk = createChunk('IHDR', ihdrData);
  
  // Create raw image data (blue square)
  const rawData = [];
  for (let y = 0; y < size; y++) {
    rawData.push(0); // filter byte for each row
    for (let x = 0; x < size; x++) {
      rawData.push(59);  // R - #3b82f6 blue
      rawData.push(130); // G
      rawData.push(246); // B
    }
  }
  
  // Compress with zlib (use deflate)
  const zlib = require('zlib');
  const compressed = zlib.deflateSync(Buffer.from(rawData));
  
  const idatChunk = createChunk('IDAT', compressed);
  
  // IEND chunk
  const iendChunk = createChunk('IEND', Buffer.alloc(0));
  
  return Buffer.concat([signature, ihdrChunk, idatChunk, iendChunk]);
}

function createChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  
  const typeBuffer = Buffer.from(type);
  const crcData = Buffer.concat([typeBuffer, data]);
  const crc = crc32(crcData);
  
  const crcBuffer = Buffer.alloc(4);
  crcBuffer.writeUInt32BE(crc >>> 0, 0);
  
  return Buffer.concat([length, typeBuffer, data, crcBuffer]);
}

// CRC32 implementation for PNG
function crc32(buffer) {
  let crc = 0xFFFFFFFF;
  const table = makeCrcTable();
  
  for (let i = 0; i < buffer.length; i++) {
    crc = (crc >>> 8) ^ table[(crc ^ buffer[i]) & 0xFF];
  }
  
  return crc ^ 0xFFFFFFFF;
}

function makeCrcTable() {
  const table = new Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c;
  }
  return table;
}

// Generate icons
const sizes = [16, 48, 128];

sizes.forEach(size => {
  const pngBuffer = createMinimalPng(size);
  const pngPath = path.join(iconsDir, `icon${size}.png`);
  fs.writeFileSync(pngPath, pngBuffer);
  console.log(`Created: icon${size}.png (${pngBuffer.length} bytes)`);
});

console.log('\nPlaceholder icons created successfully!');
console.log('Note: These are simple blue squares. Replace with proper icons for production.');

