'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const manifest = require('./SOURCE-MANIFEST.json');
const revision = process.argv[2];
if (revision) assert.match(revision,/^[0-9a-f]{40}$/);
for (const file of manifest.files) {
  const local = path.join(__dirname, file.sourcePath);
  let bytes;
  if (revision) {
    const args = ['-C',path.dirname(__dirname)];
    const entry = execFileSync('git',[...args,'ls-tree',revision,'--',file.destinationPath],{encoding:'utf8'}).split(/\s+/);
    assert.equal(entry[0],file.mode,file.sourcePath);
    assert.equal(entry[2],file.gitBlob,file.sourcePath);
    bytes = execFileSync('git',[...args,'show',revision+':'+file.destinationPath]);
  } else {
    const stat = fs.lstatSync(local);
    assert(stat.isFile() && !stat.isSymbolicLink(), file.sourcePath);
    assert.equal(stat.mode & 0o111 ? '100755' : '100644', file.mode, file.sourcePath);
    bytes = fs.readFileSync(local);
  }
  assert.equal(bytes.length, file.bytes, file.sourcePath);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), file.sha256, file.sourcePath);
}
console.log(JSON.stringify({files:manifest.files.length,sourceCommit:manifest.sourceCommit,sha256Matched:true,modeMatched:true}));
