'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const manifest = require('./SOURCE-MANIFEST.json');
for (const file of manifest.files) {
  const local = path.join(__dirname, file.sourcePath);
  const stat = fs.lstatSync(local);
  assert(stat.isFile() && !stat.isSymbolicLink(), file.sourcePath);
  assert.equal(stat.mode & 0o111 ? '100755' : '100644', file.mode, file.sourcePath);
  const bytes = fs.readFileSync(local);
  assert.equal(bytes.length, file.bytes, file.sourcePath);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), file.sha256, file.sourcePath);
}
console.log(JSON.stringify({files:manifest.files.length,sourceCommit:manifest.sourceCommit,sha256Matched:true,modeMatched:true}));
