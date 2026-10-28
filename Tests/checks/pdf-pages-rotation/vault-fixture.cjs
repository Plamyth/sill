'use strict';
const fs = require('node:fs'),path = require('node:path'),os = require('node:os'),readline = require('node:readline');
const root = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-pdf-pages-'));
const vaultRoot = path.join(root,'vault');fs.mkdirSync(vaultRoot,{mode:0o700});
fs.mkdirSync(path.join(vaultRoot,'문서'),{mode:0o700});
process.env.TMPDIR = root;
process.env.CCR_FIX_MODULE_ROOT = path.resolve('CanvasRelay/relay');
process.env.CCR_CHILD_RECEIPTS = path.join(root,'children.jsonl');
require('../../../CanvasRelay/test-guard.cjs');
const {ObsidianVault} = require('../../../CanvasRelay/relay/obsidian-vault.js');
let requests = 0;
const reply = value => process.stdout.write(JSON.stringify(value)+'\n');
const lines = readline.createInterface({input:process.stdin,crlfDelay:Infinity});
reply({ready:true});
lines.on('line',line => {
  try {
    const request = JSON.parse(line),vault = new ObsidianVault(vaultRoot);
    requests += 1;
    let value;
    if (request.operation === 'readNote') value = vault.note(request.path);
    else if (request.operation === 'saveNote') value = vault.save(request.path,request.baseSha256,request.text);
    else throw new Error('지원하지 않는 자체 fixture 명령');
    reply({ok:true,value});
  } catch (error) {reply({ok:false,status:error.status ?? 500});}
});
lines.on('close',() => {
  const children = fs.existsSync(process.env.CCR_CHILD_RECEIPTS) ?
    fs.readFileSync(process.env.CCR_CHILD_RECEIPTS,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
  if (!children.every(item => item.pidGone && item.exitCode === 0)) process.exitCode = 1;
  fs.rmSync(root,{recursive:true});
  process.stderr.write(JSON.stringify({pdfPagesFileFixture:{requests,children,fixtureRemoved:!fs.existsSync(root)}})+'\n');
});
