'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {ObsidianVault} = require('./obsidian-vault');
const {createServer} = require('./server');
const {Readable,Writable} = require('node:stream');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-pdf-'));
  t.after(() => fs.rmSync(root,{recursive:true,force:true}));
  fs.mkdirSync(path.join(root,'문서'));
  const bytes = Buffer.from('%PDF-1.4\nfixture-only\n%%EOF');
  fs.writeFileSync(path.join(root,'문서','원본.pdf'),bytes);
  return {root,bytes,vault:new ObsidianVault(root)};
}

test('PDF listing and bounded authenticated read are read-only; all writes remain Markdown-only',async t => {
  const {root,bytes,vault} = fixture(t);
  assert.deepEqual(vault.entries('문서'),[{name:'원본.pdf',path:'문서/원본.pdf',kind:'pdf'}]);
  const hash = crypto.createHash('sha256').update(bytes).digest('hex');
  assert.deepEqual(vault.pdf('문서/원본.pdf'),{path:'문서/원본.pdf',sha256:hash,dataBase64:bytes.toString('base64')});
  assert.throws(() => vault.note('문서/원본.pdf'),{status:400});
  assert.throws(() => vault.save('문서/원본.pdf',null,'changed'),{status:400});
  const token = 'fixture-token-at-least-24-characters';
  const server = createServer({token,store:path.join(root,'store'),vaultRoot:root,
    snapshotPath:path.join(root,'absent-snapshot'),hiddenPath:path.join(root,'absent-policy')});
  t.after(() => server.close());
  async function request(method,authenticated = true) {
    const incoming = Readable.from([]);
    incoming.url = '/vault/pdf?path='+encodeURIComponent('문서/원본.pdf');
    incoming.method = method;
    incoming.headers = authenticated ? {'x-canvas-token':token} : {};
    const chunks = [];
    const response = new Writable({write(chunk,encoding,done) { chunks.push(Buffer.from(chunk)); done(); }});
    response.writeHead = (status,headers) => { response.statusCode = status; response.headers = headers; };
    const completed = new Promise(resolve => response.on('finish',resolve));
    server.emit('request',incoming,response);
    await completed;
    return {status:response.statusCode,body:JSON.parse(Buffer.concat(chunks).toString())};
  }
  assert.equal((await request('GET',false)).status,401);
  assert.deepEqual((await request('GET')).body,vault.pdf('문서/원본.pdf'));
  assert.notEqual((await request('PUT')).status,200);
  assert.equal(server.listening,false);
  assert.deepEqual(fs.readFileSync(path.join(root,'문서','원본.pdf')),bytes);
});

test('PDF path, links, magic, extension and size boundaries fail closed',t => {
  const {root,vault} = fixture(t);
  fs.writeFileSync(path.join(root,'wrong.pdf'),'not a PDF');
  fs.writeFileSync(path.join(root,'wrong.md'),'%PDF-1.4');
  fs.symlinkSync(path.join(root,'문서','원본.pdf'),path.join(root,'link.pdf'));
  fs.symlinkSync(path.join(root,'문서'),path.join(root,'linked'));
  const oversized = path.join(root,'big.pdf');
  fs.writeFileSync(oversized,'%PDF-');
  fs.truncateSync(oversized,20*1024*1024+1);
  for (const relative of ['../escape.pdf','/absolute.pdf','문서/../wrong.pdf','문서//원본.pdf',
    '.hidden.pdf','wrong.md','wrong.PDF','wrong.pdf','link.pdf','linked/원본.pdf','문서\\원본.pdf','bad\0.pdf'])
    assert.throws(() => vault.pdf(relative),{status:400},relative);
  assert.throws(() => vault.pdf('missing.pdf'),{status:404});
  assert.throws(() => vault.pdf('big.pdf'),{status:413});
  assert(!vault.entries().some(entry => ['link.pdf','linked'].includes(entry.name)));
});

test('growth during a PDF read is bounded and source bytes are never written',t => {
  const {root,vault} = fixture(t);
  const read = fs.readSync;
  let grown = false;
  fs.readSync = (...args) => {
    const count = read(...args);
    if (!grown) { grown = true; fs.truncateSync(path.join(root,'문서','원본.pdf'),20*1024*1024+1); }
    return count;
  };
  try { assert.throws(() => vault.pdf('문서/원본.pdf'),{status:413}); }
  finally { fs.readSync = read; }
});

test('a parent swapped for a symlink during open is rejected before reading any bytes',t => {
  const {root,vault} = fixture(t);
  const outside = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-pdf-outside-'));
  t.after(() => fs.rmSync(outside,{recursive:true,force:true}));
  fs.writeFileSync(path.join(outside,'원본.pdf'),'%PDF-private-outside');
  const open = fs.openSync, read = fs.readSync;
  let swapped = false, reads = 0;
  fs.openSync = (file,...args) => {
    if (!swapped && file === path.join(vault.root,'문서','원본.pdf')) {
      swapped = true;
      fs.renameSync(path.join(root,'문서'),path.join(root,'preserved'));
      fs.symlinkSync(outside,path.join(root,'문서'));
    }
    return open(file,...args);
  };
  fs.readSync = (...args) => { reads++; return read(...args); };
  try {
    assert.throws(() => vault.pdf('문서/원본.pdf'),{status:409});
    assert.equal(swapped,true);
    assert.equal(reads,0);
  } finally { fs.openSync = open; fs.readSync = read; }
});
