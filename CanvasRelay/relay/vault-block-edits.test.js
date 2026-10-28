'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {once} = require('node:events');
const {createServer} = require('./server');
const {ObsidianVault} = require('./obsidian-vault');
const {VaultBlockEdits} = require('./vault-block-edits');

const sha = text => crypto.createHash('sha256').update(text).digest('hex');
const relative = 'Notes/계획 👩🏽‍💻.md', blockID = 'sill-abc-123';
const original = '# 제목\n\n원본 e\u0301 👩🏽‍💻\n다음 문장 ^sill-abc-123\t  \n\n마지막 문단\n';

async function fixture(t, text = original) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-block-edit-'));
  const root = path.join(directory,'vault'), store = path.join(directory,'store');
  fs.mkdirSync(path.join(root,'Notes'),{recursive:true});
  fs.mkdirSync(store);
  const file = path.join(root,relative), token = crypto.randomBytes(24).toString('hex');
  fs.writeFileSync(file,text);
  let server, url;
  const endpoint = (name = relative, id = blockID) => '/vault/block?' + new URLSearchParams({path:name,blockID:id});
  const f = {root,store,file,token,endpoint,
    write:text => fs.writeFileSync(file,text),
    bytes:() => fs.readFileSync(file),
    receipt:id => path.join(store,'.block-edits',id.toLowerCase(),'receipt.json'),
    async start() {
      server = createServer({vaultRoot:root,store,token});
      await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
      url = `http://127.0.0.1:${server.address().port}`;
    },
    async stop() {
      if (!server) return;
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      server = null;
    },
    call:(method = 'GET', body, name = relative, id = blockID, headers = {'x-canvas-token':token}) =>
      fetch(url+endpoint(name,id),{method,headers,body:body === undefined ? undefined : JSON.stringify(body)}),
    async block() {
      const response = await f.call();
      assert.equal(response.status,200);
      return response.json();
    },
    request:(block, replacementText = '수정한 e\u0301 🧑‍🚀\n두 번째 문장') => ({schemaVersion:1,
      operationId:crypto.randomUUID(),baseSha256:block.note.sha256,baseQuoteSha256:block.quoteSha256,replacementText})
  };
  t.after(async () => { await f.stop(); fs.rmSync(directory,{recursive:true,force:true}); });
  await f.start();
  return f;
}

test('shared authenticated HTTP contract preserves exact Unicode, marker suffix and all outside bytes', async t => {
  const f = await fixture(t), before = f.bytes();
  assert.equal((await f.call('GET',undefined,relative,blockID,{})).status,401);
  assert.equal((await f.call('PUT',{ownerThreadId:'01a13ace-e372-7ed1-9946-149df37ee1c3'},relative,blockID,{})).status,401);
  const block = await f.block();
  assert.deepEqual(Object.keys(block).sort(),['schemaVersion','blockID','text','quoteSha256','note'].sort());
  assert.equal(block.schemaVersion,1);
  assert.equal(block.blockID,blockID);
  assert.equal(block.text,'원본 e\u0301 👩🏽‍💻\n다음 문장');
  assert.equal(block.quoteSha256,sha(Buffer.from(block.text)));
  assert.equal(block.note.path,relative);
  assert.equal(block.note.sha256,sha(before));
  assert.equal(block.note.text,original);
  assert.ok(Number.isFinite(Date.parse(block.note.modifiedAt)));
  const request = f.request(block);
  const response = await f.call('PUT',request);
  assert.equal(response.status,200);
  const result = await response.json();
  assert.deepEqual(Object.keys(result).sort(),['schemaVersion','operationId','blockID','disposition','quoteSha256','note'].sort());
  assert.equal(result.disposition,'committed');
  assert.equal(result.operationId,request.operationId);
  assert.equal(result.quoteSha256,sha(request.replacementText));
  const expected = Buffer.from(original.replace(block.text,request.replacementText));
  assert.deepEqual(f.bytes(),expected);
  assert.equal(result.note.text,expected.toString('utf8'));
  assert.equal(result.note.sha256,sha(expected));
  const receipt = JSON.parse(fs.readFileSync(f.receipt(request.operationId)));
  assert.equal(receipt.state,'committed');
  assert.equal(receipt.expectedSha256,sha(expected));
  assert.equal(fs.readdirSync(f.root).includes('.block-edits'),false);
  assert.equal((await f.block()).text,request.replacementText);
  const savedInode = fs.statSync(f.file).ino;
  await f.stop(); await f.start();
  const replay = await f.call('PUT',request);
  assert.equal(replay.status,200);
  assert.equal((await replay.json()).disposition,'reconciled');
  assert.deepEqual(f.bytes(),expected);
  assert.equal(fs.statSync(f.file).ino,savedInode);
});

test('CRLF paragraph and single line replacement preserve the original CRLF marker tail', async t => {
  const source = original.replaceAll('\n','\r\n'), f = await fixture(t,source);
  let block = await f.block();
  assert.equal(block.text,'원본 e\u0301 👩🏽‍💻\r\n다음 문장');
  for (const replacement of ['잘못된\n줄바꿈','혼합\r\n줄\n바꿈','bare\rreturn']) {
    assert.equal((await f.call('PUT',f.request(block,replacement))).status,422);
    assert.deepEqual(f.bytes(),Buffer.from(source));
  }
  const replacement = '첫 줄 🧑‍🚀\r\n둘째 줄';
  assert.equal((await f.call('PUT',f.request(block,replacement))).status,200);
  assert.deepEqual(f.bytes(),Buffer.from(source.replace(block.text,replacement)));
  block = await f.block();
  assert.equal((await f.call('PUT',f.request(block,'한 줄'))).status,200);
  assert.equal(f.bytes().toString(),source.replace('원본 e\u0301 👩🏽‍💻\r\n다음 문장','한 줄'));
});

test('LF source rejects CRLF replacement and a BOM outside the selected block survives', async t => {
  const source = '\ufeff# 제목\n\n안전한 문단 ^sill-abc-123\n', f = await fixture(t,source);
  const block = await f.block();
  assert.equal(block.note.text,source);
  assert.equal((await f.call('PUT',f.request(block,'첫 줄\r\n둘째 줄'))).status,422);
  assert.equal((await f.call('PUT',f.request(block,'바뀐 문단'))).status,200);
  assert.deepEqual(f.bytes(),Buffer.from(source.replace('안전한 문단','바뀐 문단')));
});

test('missing and duplicate anchors, opaque, structural and unsupported chunks are refused without mutation', async t => {
  const f = await fixture(t);
  const examples = [
    ['표식 없음\n',404],
    ['한 문단 ^sill-abc-123\n\n다른 문단 ^sill-abc-123\n',409],
    ['한 문단 ^sill-abc-123\n\n```\n다른 문단 ^sill-abc-123\n```\n',409],
    ['---\ntitle: 문단 ^sill-abc-123\n---\n',422],
    ['```md\n문단 ^sill-abc-123\n```\n',422],
    ['~~~\n문단 ^sill-abc-123\n~~~\n',422],
    ['<span>다른 내용</span>\n\n문단 ^sill-abc-123\n',422],
    ['%% 숨김 %%\n\n문단 ^sill-abc-123\n',422],
    ['$$ x $$\n\n문단 ^sill-abc-123\n',422],
    ['# 제목 ^sill-abc-123\n',422],
    ['- 목록 ^sill-abc-123\n',422],
    ['1. 순서 ^sill-abc-123\n',422],
    ['> 인용 ^sill-abc-123\n',422],
    [' 들여쓰기 ^sill-abc-123\n',422],
    ['문단\n--- ^sill-abc-123\n',422],
    ['열 | 표 ^sill-abc-123\n',422],
    ['문단 [[링크]] ^sill-abc-123\n',422],
    ['문단 `코드` ^sill-abc-123\n',422],
    ['문단 \\이스케이프 ^sill-abc-123\n',422],
    ['문단\n\n^sill-abc-123\n',422],
    ['문단 ^sill-abc-123\n\n^다른표식\n',422],
    ['문단  ^sill-abc-123\n',422],
    ['문단\r내부 ^sill-abc-123\n',422],
    ['문단\r\n이어짐 ^sill-abc-123\n',422],
    ['\ufeff\n문단 ^sill-abc-123\n',422],
  ];
  for (const [source,status] of examples) {
    f.write(source);
    const body = {schemaVersion:1,operationId:crypto.randomUUID(),baseSha256:sha(source),
      baseQuoteSha256:sha('문단'),replacementText:'새 문단'};
    assert.equal((await f.call()).status,status,source);
    assert.equal((await f.call('PUT',body)).status,status,source);
    assert.deepEqual(f.bytes(),Buffer.from(source));
  }
});

test('valid frontmatter and closed fences elsewhere do not prevent an existing plain paragraph edit', async t => {
  const source = '---\ntitle: 제목\n---\n\n~~~\n보호할 코드\n~~~\n\n문단 ^sill-abc-123\n';
  const f = await fixture(t,source), block = await f.block();
  assert.equal((await f.call('PUT',f.request(block,'새 문단'))).status,200);
  assert.deepEqual(f.bytes(),Buffer.from(source.replace('문단 ^','새 문단 ^')));
});

test('replacement cannot inject anchors, blank paragraphs, formatting structure or invalid Unicode', async t => {
  const f = await fixture(t), block = await f.block();
  for (const replacement of ['', ' ', '문단\n', '\n문단', '첫 문단\n\n둘째 문단', '# 제목', '- 항목',
    '1) 항목','> 인용','문단 ^new-id','문단 ^sill-abc-123','원문\n^other','<tag>','숨김 %%','수식 $$',
    '인라인 `코드`','열|표','[[링크]]','들여\t쓰기','끝 공백 ','끝 탭\t','\ufeff문단','\ud800']) {
    assert.equal((await f.call('PUT',f.request(block,replacement))).status,422,JSON.stringify(replacement));
    assert.deepEqual(f.bytes(),Buffer.from(original));
  }
});

test('stale note or quote versions refuse, even when the other version still matches', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block);
  assert.equal((await f.call('PUT',{...request,baseQuoteSha256:'0'.repeat(64)})).status,409);
  assert.equal(fs.existsSync(path.dirname(f.receipt(request.operationId))),false);
  const changed = original.replace('마지막 문단','다른 담당의 변경');
  f.write(changed);
  assert.equal((await f.call('PUT',request)).status,409);
  assert.deepEqual(f.bytes(),Buffer.from(changed));
});

test('operation IDs bind path, block and every request field across restarts; changed results never reapply', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block);
  assert.equal((await f.call('PUT',request)).status,200);
  const saved = f.bytes();
  fs.writeFileSync(path.join(f.root,'Notes','other.md'),original);
  for (const change of [{replacementText:'다른 편집'},{baseSha256:'0'.repeat(64)},
    {baseQuoteSha256:'1'.repeat(64)}]) {
    assert.equal((await f.call('PUT',{...request,...change})).status,409);
    assert.deepEqual(f.bytes(),saved);
  }
  assert.equal((await f.call('PUT',request,'Notes/other.md')).status,409);
  assert.equal((await f.call('PUT',request,relative,'other-id')).status,409);
  await f.stop(); await f.start();
  f.write(saved.toString().replace('마지막 문단','새 외부 변경'));
  const changed = f.bytes();
  assert.equal((await f.call('PUT',request)).status,409);
  assert.deepEqual(f.bytes(),changed);
  fs.unlinkSync(f.file);
  assert.equal((await f.call('PUT',request)).status,409);
  assert.equal(fs.existsSync(f.file),false);
});

test('HTTP input validation, auth, traversal and symlink protections retain the vault boundary', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block);
  fs.symlinkSync(f.file,path.join(f.root,'alias.md'));
  fs.symlinkSync(path.join(f.root,'Notes'),path.join(f.root,'linked'));
  for (const name of ['../outside.md','/tmp/outside.md','.obsidian/private.md','Notes/../other.md',
    'Notes\\other.md','Notes/non-markdown.json','alias.md','linked/계획 👩🏽‍💻.md']) {
    assert.equal((await f.call('GET',undefined,name)).status,400,name);
    assert.equal((await f.call('PUT',request,name)).status,400,name);
  }
  for (const change of [{schemaVersion:2},{schemaVersion:'1'},{operationId:'bad'},
    {baseSha256:'A'.repeat(64)},{baseQuoteSha256:null},{replacementText:null},
    {ownerThreadId:'01a13ace-e372-7ed1-9946-149df37ee1c3'}])
    assert.equal((await f.call('PUT',{...request,...change})).status,400);
  for (const id of ['', '../bad','with space','bad_id']) {
    assert.equal((await f.call('GET',undefined,relative,id)).status,400);
    assert.equal((await f.call('PUT',request,relative,id)).status,400);
  }
  assert.deepEqual(f.bytes(),Buffer.from(original));
});

test('1 MiB note and replacement limits count UTF-8 bytes and reject oversized results before receipts', async t => {
  const f = await fixture(t), block = await f.block();
  assert.equal((await f.call('PUT',f.request(block,'한'.repeat(350000)))).status,413);
  const request = f.request(block,'a'.repeat(1024*1024));
  assert.equal((await f.call('PUT',request)).status,413);
  assert.equal(fs.existsSync(path.dirname(f.receipt(request.operationId))),false);
  f.write('a'.repeat(1024*1024)+' ^sill-abc-123');
  assert.equal((await f.call()).status,413);
});

test('concurrent same-ID retries yield one commit and concurrent different IDs respect whole-note CAS', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block);
  const responses = await Promise.all(Array.from({length:5},() => f.call('PUT',request)));
  const results = await Promise.all(responses.map(async response => {
    assert.equal(response.status,200);
    return response.json();
  }));
  assert.equal(results.filter(result => result.disposition === 'committed').length,1);
  assert.equal(results.filter(result => result.disposition === 'reconciled').length,4);
  f.write(original);
  const fresh = await f.block();
  const competing = await Promise.all([f.call('PUT',f.request(fresh,'편집 하나')),f.call('PUT',f.request(fresh,'편집 둘'))]);
  assert.deepEqual(competing.map(response => response.status).sort(),[200,409]);
});

for (const mode of ['before-save','after-save','response-loss']) {
  test(`process exit ${mode} retains durable outcome and same-ID reconciliation never reapplies`, async t => {
    const f = await fixture(t), block = await f.block(), request = f.request(block);
    await f.stop();
    const script = `
      const fs = require('node:fs');
      const {createServer} = require(${JSON.stringify(require.resolve('./server'))});
      const {ObsidianVault} = require(${JSON.stringify(require.resolve('./obsidian-vault'))});
      const options = JSON.parse(process.argv[1]), save = ObsidianVault.prototype.save;
      ObsidianVault.prototype.save = function(...args) {
        if (options.mode === 'before-save') process.exit(73);
        const result = save.apply(this,args);
        if (options.mode === 'after-save') process.exit(73);
        return result;
      };
      const server = createServer(options);
      if (options.mode === 'response-loss') server.prependListener('request',(req,res) => {
        if (req.method === 'PUT') res.end = () => process.exit(73);
      });
      server.listen(0,'127.0.0.1',() => process.stdout.write(String(server.address().port)+'\\n'));
    `;
    const child = spawn(process.execPath,['-e',script,JSON.stringify({vaultRoot:f.root,store:f.store,token:f.token,mode})],
      {stdio:['ignore','pipe','pipe']});
    t.after(() => child.kill());
    const exited = once(child,'exit');
    const port = await new Promise((resolve,reject) => {
      child.once('error',reject);
      child.stdout.once('data',data => resolve(Number(String(data).trim())));
      child.once('exit',code => reject(new Error('Child exited before listening: '+code)));
    });
    await assert.rejects(fetch(`http://127.0.0.1:${port}`+f.endpoint(),{method:'PUT',
      headers:{'x-canvas-token':f.token},body:JSON.stringify(request)}));
    assert.equal((await exited)[0],73);
    const receipt = JSON.parse(fs.readFileSync(f.receipt(request.operationId)));
    assert.equal(receipt.state,mode === 'response-loss' ? 'committed' : 'prepared');
    const expected = original.replace(block.text,request.replacementText);
    assert.equal(receipt.expectedSha256,sha(expected));
    assert.deepEqual(f.bytes(),Buffer.from(mode === 'before-save' ? original : expected));
    const savedInode = fs.statSync(f.file).ino;
    await f.start();
    const response = await f.call('PUT',request);
    assert.equal(response.status,mode === 'before-save' ? 409 : 200);
    if (response.status === 200) assert.equal((await response.json()).disposition,'reconciled');
    assert.deepEqual(f.bytes(),Buffer.from(mode === 'before-save' ? original : expected));
    assert.equal(fs.statSync(f.file).ino,savedInode);
  });
}

test('incomplete receipt reservation and failed prepared persistence never write or blindly retry', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block);
  fs.mkdirSync(path.dirname(f.receipt(request.operationId)));
  assert.equal((await f.call('PUT',request)).status,409);
  assert.deepEqual(f.bytes(),Buffer.from(original));
  const vault = new ObsidianVault(f.root), edits = new VaultBlockEdits(vault,f.store);
  const next = f.request(block), originalFsync = fs.fsyncSync;
  fs.fsyncSync = fd => {
    if (fs.fstatSync(fd).isFile()) throw new Error('injected prepared receipt sync failure');
    return originalFsync(fd);
  };
  try { assert.throws(() => edits.edit(relative,blockID,next),/injected/); }
  finally { fs.fsyncSync = originalFsync; }
  assert.deepEqual(f.bytes(),Buffer.from(original));
  assert.equal((await f.call('PUT',next)).status,409);
});

test('a no-op can commit but an ambiguous prepared no-op never claims reconciliation', async t => {
  const f = await fixture(t), block = await f.block(), request = f.request(block,block.text);
  request.operationId = request.operationId.toUpperCase();
  const response = await f.call('PUT',request);
  assert.equal(response.status,200);
  const result = await response.json();
  assert.equal(result.operationId,request.operationId.toLowerCase());
  assert.equal(result.note.sha256,block.note.sha256);
  assert.equal((await (await f.call('PUT',request)).json()).disposition,'reconciled');
  const receiptPath = f.receipt(request.operationId);
  const receipt = JSON.parse(fs.readFileSync(receiptPath));
  fs.writeFileSync(receiptPath,JSON.stringify({...receipt,state:'prepared'}));
  assert.equal((await f.call('PUT',request)).status,409);
  assert.deepEqual(f.bytes(),Buffer.from(original));
});

test('external write during save and failed committed receipt are conservative and recoverable', async t => {
  const f = await fixture(t), vault = new ObsidianVault(f.root), edits = new VaultBlockEdits(vault,f.store);
  const block = await f.block(), request = f.request(block), originalSave = vault.save.bind(vault);
  vault.save = (...args) => {
    const note = originalSave(...args);
    f.write(note.text + '\n외부 변경\n');
    return note;
  };
  assert.throws(() => edits.edit(relative,blockID,request),{status:409});
  assert.equal(JSON.parse(fs.readFileSync(f.receipt(request.operationId))).state,'prepared');
  assert.equal((await f.call('PUT',request)).status,409);
  f.write(original);
  vault.save = (...args) => {
    const note = originalSave(...args);
    fs.fsyncSync = () => { throw new Error('injected committed receipt sync failure'); };
    return note;
  };
  const next = f.request(block), originalFsync = fs.fsyncSync;
  try { assert.throws(() => edits.edit(relative,blockID,next),/injected/); }
  finally { fs.fsyncSync = originalFsync; }
  assert.equal(JSON.parse(fs.readFileSync(f.receipt(next.operationId))).state,'prepared');
  assert.equal((await f.call('PUT',next)).status,200);
  assert.equal(JSON.parse(fs.readFileSync(f.receipt(next.operationId))).state,'committed');
});
