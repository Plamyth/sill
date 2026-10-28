'use strict';
const zlib = require('node:zlib');
function crc32(data) {
  let crc = -1;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ -1) >>> 0;
}
function validPNG(image) {
  if (!image.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex'))) return false;
  let offset = 8, ihdr = false, ended = false;
  const idat = [];
  while (offset + 12 <= image.length) {
    const length = image.readUInt32BE(offset);
    if (length > image.length - offset - 12) return false;
    const kind = image.toString('ascii',offset+4,offset+8);
    const data = image.subarray(offset+8,offset+8+length);
    const crc = image.readUInt32BE(offset+8+length);
    if (crc32(image.subarray(offset+4,offset+8+length)) !== crc) return false;
    if (kind === 'IHDR') {
      if (ihdr || offset !== 8 || length !== 13 ||
          data.readUInt32BE(0) === 0 || data.readUInt32BE(4) === 0 ||
          data.readUInt32BE(0) > 8192 || data.readUInt32BE(4) > 8192) return false;
      ihdr = true;
    }
    if (kind === 'IDAT') idat.push(data);
    offset += length+12;
    if (kind === 'IEND') { ended = true; break; }
  }
  if (!ihdr || !ended || !idat.length || offset !== image.length) return false;
  try { zlib.inflateSync(Buffer.concat(idat),{maxOutputLength:64*1024*1024}); }
  catch { return false; }
  return true;
}

module.exports = {validPNG};
