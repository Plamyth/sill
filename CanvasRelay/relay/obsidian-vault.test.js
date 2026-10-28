'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {ObsidianVault} = require('./obsidian-vault');
const {createServer} = require('./server');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-vault-'));
  t.after(() => fs.rmSync(root,{recursive:true,force:true}));
  fs.mkdirSync(path.join(root,'Notes'));
  fs.mkdirSync(path.join(root,'.obsidian'));
  fs.writeFileSync(path.join(root,'Notes','계획.md'),'# 시작\n');
  fs.writeFileSync(path.join(root,'.obsidian','app.json'),'{}');
  return root;
}

const MEMO_BOUNDARY = '\n<!-- ccr:markdown-memo:v1 -->\n';
const MEMO = '\n## 메모\n\n한글 e\u0301 👩🏽‍💻 🧑‍🚀\r\n' +
  '> 인용 **강조**  \n\n- [ ] [[다른 노트]]\n\n```js\nconst x = "메모";\n```\n\t끝  ';

function canvasFixture(t) {
  const root = fixture(t), vault = new ObsidianVault(root), id = crypto.randomUUID();
  const scene = Buffer.from(JSON.stringify({schemaVersion:1,id,revision:1,drawingBase64:'',nodes:[],links:[],strokes:[],
    futureField:{language:'한국어',values:[null,1,'🖊️']}}));
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
  const first = vault.saveCanvas(id,1,scene,image,null);
  return {root,vault,id,scene,image,first};
}

function memoText(note, memo = MEMO) {
  return note.text.split(MEMO_BOUNDARY)[0] + MEMO_BOUNDARY + memo;
}

function assets(root) {
  const directory = path.join(root,'CCR Canvas','Assets');
  return Object.fromEntries(fs.readdirSync(directory).map(name => [name,fs.readFileSync(path.join(directory,name))]));
}

test('raw Markdown memo edits remain readable as a canvas without changing original assets', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const originals = assets(root), note = vault.note(first.path);
  assert.ok(note.text.endsWith(MEMO_BOUNDARY + '\n## 메모\n\n'));
  const edited = vault.save(first.path,note.sha256,memoText(note));
  const read = vault.canvas(id);
  assert.equal(read.noteSha256,edited.sha256);
  assert.equal(read.sceneSha256,crypto.createHash('sha256').update(scene).digest('hex'));
  assert.equal(read.imageSha256,crypto.createHash('sha256').update(image).digest('hex'));
  assert.deepEqual(Buffer.from(read.sceneJSONBase64,'base64'),scene);
  assert.deepEqual(assets(root),originals);
  assert.equal(vault.note(first.path).text,edited.text);
});

test('ink autosaves preserve the exact Markdown suffix and stale saves or retries lose no memo', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const originals = assets(root), note = vault.note(first.path);
  const edited = vault.save(first.path,note.sha256,memoText(note));
  const nextScene = Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,drawingBase64:'aW5r'}));
  assert.throws(() => vault.saveCanvas(id,2,nextScene,image,first.noteSha256),{status:409});
  assert.equal(vault.note(first.path).text,edited.text);
  const saved = vault.saveCanvas(id,2,nextScene,image,edited.sha256);
  assert.equal(vault.canvas(id).revision,2);
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),nextScene);
  assert.deepEqual(Buffer.from(vault.note(first.path).text.split(MEMO_BOUNDARY)[1]),Buffer.from(MEMO));
  assert.throws(() => vault.saveCanvas(id,2,nextScene,image,edited.sha256),{status:409});
  assert.equal(vault.note(first.path).sha256,saved.noteSha256);
  const retried = vault.saveCanvas(id,2,nextScene,image,saved.noteSha256);
  assert.equal(retried.noteSha256,saved.noteSha256);
  const laterMemo = '\n## 새 제목\n\n에이전트가 편집 🧠\r\n마지막 줄\n\n';
  const later = vault.save(first.path,saved.noteSha256,memoText(vault.note(first.path),laterMemo));
  assert.throws(() => vault.saveCanvas(id,2,nextScene,image,saved.noteSha256),{status:409});
  assert.equal(vault.note(first.path).text,later.text);
  vault.saveCanvas(id,2,nextScene,image,later.sha256);
  assert.equal(vault.note(first.path).text,later.text);
  for (const [name,bytes] of Object.entries(originals)) assert.deepEqual(assets(root)[name],bytes);
});

test('exact legacy notes read without mutation and gain a memo section on the next canvas save', t => {
  const {vault,id,scene,image,first} = canvasFixture(t);
  const legacy = `---\nccr_scene_id: ${id}\nccr_revision: 1\n` +
    `ccr_scene_sha256: ${first.sceneSha256}\nccr_image_sha256: ${first.imageSha256}\n---\n\n` +
    `# iPad 그림 ${id.slice(0,8)}\n\n![[Assets/${id}-${first.imageSha256}.png]]\n\n` +
    `원본 획과 구조: [[Assets/${id}-${first.sceneSha256}.json]]\n`;
  const note = vault.save(first.path,first.noteSha256,legacy);
  assert.equal(vault.canvas(id).noteSha256,note.sha256);
  assert.equal(vault.note(first.path).text,legacy);
  const saved = vault.saveCanvas(id,1,scene,image,note.sha256);
  assert.equal(vault.note(first.path).text,legacy + MEMO_BOUNDARY + '\n## 메모\n\n');
  assert.equal(vault.canvas(id).noteSha256,saved.noteSha256);
});

test('changed managed metadata, unknown fields, paths and unmarked edits refuse without rewriting', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const original = vault.note(first.path), originals = assets(root);
  const edits = [
    text => text.replace('ccr_revision: 1','ccr_revision: 7'),
    text => text.replace(`ccr_scene_id: ${id}`,`ccr_scene_id: ${crypto.randomUUID()}`),
    text => text.replace('ccr_revision: 1','ccr_revision: 1\nccr_future: true'),
    text => text.replace('ccr_revision: 1','ccr_revision: 1\nccr_revision: 1'),
    text => text.replace('![[Assets/','![[Other/'),
    text => text.replace(first.sceneSha256,'0'.repeat(64)),
    text => text.replace(first.imageSha256,'0'.repeat(64)),
    text => text.replace('# iPad 그림','# 내 그림'),
    text => text.split(MEMO_BOUNDARY)[0] + '\n표식 없는 메모',
  ];
  for (const edit of edits) {
    const current = vault.note(first.path);
    const changed = vault.save(first.path,current.sha256,edit(original.text));
    assert.throws(() => vault.canvas(id),{status:409});
    assert.throws(() => vault.saveCanvas(id,1,scene,image,changed.sha256),{status:409});
    assert.equal(vault.note(first.path).text,changed.text);
    assert.deepEqual(assets(root),originals);
  }
});

test('ambiguous and unsupported memo markers refuse and leave all bytes intact', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const original = vault.note(first.path), originals = assets(root);
  for (const suffix of [MEMO + MEMO_BOUNDARY + '두 번째 메모',
    MEMO + '\n<!-- ccr:markdown-memo:v2 -->\nunknown',
    MEMO + '\n```\n<!-- ccr:markdown-memo:v1 -->\n```']) {
    const current = vault.note(first.path);
    const changed = vault.save(first.path,current.sha256,memoText(original,suffix));
    assert.throws(() => vault.canvas(id),{status:409});
    assert.throws(() => vault.saveCanvas(id,1,scene,image,changed.sha256),{status:409});
    assert.equal(vault.note(first.path).text,changed.text);
    assert.deepEqual(assets(root),originals);
  }
  const current = vault.note(first.path);
  const unsupported = vault.save(first.path,current.sha256,
    memoText(original).replace(MEMO_BOUNDARY,'\n<!-- ccr:markdown-memo:v2 -->\n'));
  assert.throws(() => vault.canvas(id),{status:409});
  assert.throws(() => vault.saveCanvas(id,1,scene,image,unsupported.sha256),{status:409});
  assert.equal(vault.note(first.path).text,unsupported.text);
});

test('an empty memo suffix stays empty and memo text cannot override managed metadata', t => {
  const {vault,id,scene,image,first} = canvasFixture(t);
  let note = vault.note(first.path);
  note = vault.save(first.path,note.sha256,memoText(note,''));
  vault.saveCanvas(id,1,scene,image,note.sha256);
  assert.equal(vault.note(first.path).text,note.text);
  const memo = '\nccr_scene_sha256: ' + '0'.repeat(64) + '\nccr_revision: 999\n---\n';
  note = vault.save(first.path,note.sha256,memoText(note,memo));
  assert.equal(vault.canvas(id).revision,1);
  vault.saveCanvas(id,1,scene,image,note.sha256);
  assert.equal(vault.note(first.path).text,note.text);
});

test('a memo edited during the temporary note write wins the final CAS check', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const note = vault.note(first.path), originals = assets(root);
  const externalText = memoText(note,'\n## 메모\n\nMac에서 마지막 순간 편집 📝\r\n');
  const fsync = fs.fsyncSync;
  let edited = false;
  fs.fsyncSync = fd => {
    fsync(fd);
    if (!edited) {
      edited = true;
      fs.writeFileSync(path.join(root,first.path),externalText);
    }
  };
  try {
    assert.throws(() => vault.saveCanvas(id,1,scene,image,note.sha256),{status:409});
  } finally { fs.fsyncSync = fsync; }
  assert.ok(edited);
  assert.equal(vault.note(first.path).text,externalText);
  assert.equal(vault.canvas(id).noteSha256,vault.note(first.path).sha256);
  assert.deepEqual(assets(root),originals);
  assert.ok(!fs.readdirSync(path.join(root,'CCR Canvas')).some(name => name.endsWith('.tmp')));
});

test('a missing or corrupted scene or preview asset refuses without repairing or rewriting the note', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const note = vault.note(first.path), originals = assets(root);
  for (const [name,bytes] of Object.entries(originals)) {
    const file = path.join(root,'CCR Canvas','Assets',name);
    fs.writeFileSync(file,'corrupted');
    assert.throws(() => vault.canvas(id),{status:409});
    assert.throws(() => vault.saveCanvas(id,1,scene,image,note.sha256),{status:409});
    assert.equal(vault.note(first.path).text,note.text);
    assert.equal(fs.readFileSync(file,'utf8'),'corrupted');
    fs.unlinkSync(file);
    assert.throws(() => vault.canvas(id),{status:409});
    assert.throws(() => vault.saveCanvas(id,1,scene,image,note.sha256),{status:409});
    assert.ok(!fs.existsSync(file));
    assert.equal(vault.note(first.path).text,note.text);
    fs.writeFileSync(file,bytes);
  }
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),scene);
  assert.deepEqual(assets(root),originals);
});

test('reads Markdown, lists visible entries, and detects external edits before save', t => {
  const root = fixture(t), vault = new ObsidianVault(root);
  assert.deepEqual(vault.entries('').map(entry => entry.name),['Notes']);
  const before = vault.note('Notes/계획.md');
  assert.equal(before.text,'# 시작\n');
  fs.writeFileSync(path.join(root,'Notes','계획.md'),'# 다른 편집\n');
  assert.throws(() => vault.save('Notes/계획.md',before.sha256,'# iPad 편집\n'),
    {message:'Note changed on Mac; reload before saving'});
  assert.equal(fs.readFileSync(path.join(root,'Notes','계획.md'),'utf8'),'# 다른 편집\n');
  const current = vault.note('Notes/계획.md');
  const saved = vault.save('Notes/계획.md',current.sha256,'# iPad 편집\n');
  assert.equal(saved.text,'# iPad 편집\n');
  assert.equal(vault.note('Notes/계획.md').sha256,saved.sha256);
});

test('blocks traversal, hidden metadata, symlinks, non-Markdown and missing base revisions', t => {
  const root = fixture(t), vault = new ObsidianVault(root);
  fs.symlinkSync(os.tmpdir(),path.join(root,'outside'));
  for (const name of ['../outside.md','/tmp/outside.md','.obsidian/app.json','outside/file.md',
    'Notes/../계획.md','Notes\\계획.md','Notes/test.json'])
    assert.throws(() => vault.note(name));
  assert.throws(() => vault.save('Notes/계획.md',null,'replace'));
  const created = vault.save('Notes/새 문서.md',null,'# 새 문서\n');
  assert.equal(created.text,'# 새 문서\n');
  assert.throws(() => vault.save('Notes/새 문서.md',null,'overwrite'));
});

test('authenticated HTTP read and compare-and-swap write expose Mac changes', async t => {
  const root = fixture(t), token = crypto.randomBytes(24).toString('hex');
  const store = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-packets-'));
  t.after(() => fs.rmSync(store,{recursive:true,force:true}));
  const server = createServer({vaultRoot:root,token,store});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const endpoint = `${base}/vault/note?path=${encodeURIComponent('Notes/계획.md')}`;
  const denied = await fetch(endpoint);
  assert.equal(denied.status,401);
  const headers = {'x-canvas-token':token};
  const note = await (await fetch(endpoint,{headers})).json();
  const result = await fetch(endpoint,{method:'PUT',headers:{...headers,'content-type':'application/json'},
    body:JSON.stringify({baseSha256:note.sha256,text:'# iPad에서 수정\n'})});
  assert.equal(result.status,200);
  assert.equal(fs.readFileSync(path.join(root,'Notes','계획.md'),'utf8'),'# iPad에서 수정\n');
  const conflict = await fetch(endpoint,{method:'PUT',headers:{...headers,'content-type':'application/json'},
    body:JSON.stringify({baseSha256:note.sha256,text:'# 오래된 편집\n'})});
  assert.equal(conflict.status,409);
  assert.equal(fs.readFileSync(path.join(root,'Notes','계획.md'),'utf8'),'# iPad에서 수정\n');
});

test('canvas export preserves a visible Markdown preview and immutable source assets', async t => {
  const root = fixture(t), vault = new ObsidianVault(root);
  const id = crypto.randomUUID();
  const scene = Buffer.from(JSON.stringify({schemaVersion:1,id,revision:1,drawingBase64:'',nodes:[],links:[],strokes:[]}));
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
  const first = vault.saveCanvas(id,1,scene,image,null);
  const loaded = vault.canvas(id);
  assert.equal(loaded.noteSha256,first.noteSha256);
  assert.deepEqual(Buffer.from(loaded.sceneJSONBase64,'base64'),scene);
  const note = vault.note(first.path);
  assert.match(note.text,/!\[\[Assets\/.*\.png\]\]/);
  assert.match(note.text,/원본 획과 구조: \[\[Assets\/.*\.json\]\]/);
  assert.throws(() => vault.saveCanvas(id,1,scene,image,null),
    {message:'Note changed on Mac; reload before saving'});
  const second = vault.saveCanvas(id,1,scene,image,first.noteSha256);
  assert.equal(second.noteSha256,first.noteSha256);
});

test('authenticated canvas HTTP round trip rejects stale note versions', async t => {
  const root = fixture(t), store = fs.mkdtempSync(path.join(os.tmpdir(),'ccr-packets-'));
  t.after(() => fs.rmSync(store,{recursive:true,force:true}));
  const token = crypto.randomBytes(24).toString('hex');
  const server = createServer({vaultRoot:root,token,store});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  t.after(() => server.close());
  const id = crypto.randomUUID();
  const endpoint = `http://127.0.0.1:${server.address().port}/vault/canvas?id=${id}`;
  const headers = {'x-canvas-token':token,'content-type':'application/json'};
  assert.equal((await fetch(endpoint,{headers})).status,404);
  const scene = Buffer.from(JSON.stringify({schemaVersion:1,id,revision:1,drawingBase64:'',nodes:[],links:[],strokes:[]}));
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
  const body = {revision:1,baseSha256:null,sceneJSONBase64:scene.toString('base64'),
    imagePNGBase64:image.toString('base64')};
  const first = await fetch(endpoint,{method:'PUT',headers,body:JSON.stringify(body)});
  assert.equal(first.status,200);
  const saved = await first.json();
  const loaded = await (await fetch(endpoint,{headers})).json();
  assert.equal(loaded.noteSha256,saved.noteSha256);
  const stale = await fetch(endpoint,{method:'PUT',headers,body:JSON.stringify(body)});
  assert.equal(stale.status,409);
  assert.equal((await (await fetch(endpoint,{headers})).json()).sceneSha256,saved.sceneSha256);
  const noteEndpoint = `http://127.0.0.1:${server.address().port}/vault/note?path=${encodeURIComponent(saved.path)}`;
  const note = await (await fetch(noteEndpoint,{headers})).json();
  const editedText = memoText(note);
  const editedResponse = await fetch(noteEndpoint,{method:'PUT',headers,
    body:JSON.stringify({baseSha256:note.sha256,text:editedText})});
  assert.equal(editedResponse.status,200);
  const edited = await editedResponse.json();
  const canvasResponse = await fetch(endpoint,{headers});
  assert.equal(canvasResponse.status,200);
  assert.equal((await canvasResponse.json()).noteSha256,edited.sha256);
  assert.equal((await (await fetch(noteEndpoint,{headers})).json()).text,editedText);
  const nextScene = Buffer.from(JSON.stringify({schemaVersion:1,id,revision:2,drawingBase64:'aW5r',nodes:[],links:[],strokes:[]}));
  const nextBody = {...body,revision:2,sceneJSONBase64:nextScene.toString('base64')};
  const staleInk = await fetch(endpoint,{method:'PUT',headers,
    body:JSON.stringify({...nextBody,baseSha256:saved.noteSha256})});
  assert.equal(staleInk.status,409);
  assert.equal((await (await fetch(noteEndpoint,{headers})).json()).text,editedText);
  const autosave = await fetch(endpoint,{method:'PUT',headers,
    body:JSON.stringify({...nextBody,baseSha256:edited.sha256})});
  assert.equal(autosave.status,200);
  const updated = await autosave.json();
  const readbackResponse = await fetch(endpoint,{headers});
  assert.equal(readbackResponse.status,200);
  const readback = await readbackResponse.json();
  assert.equal(readback.revision,2);
  assert.equal(readback.noteSha256,updated.noteSha256);
  assert.deepEqual(Buffer.from(readback.sceneJSONBase64,'base64'),nextScene);
  const finalNote = await (await fetch(noteEndpoint,{headers})).json();
  assert.equal(finalNote.text.split(MEMO_BOUNDARY)[1],MEMO);
  assert.equal(fs.readFileSync(path.join(root,saved.path),'utf8'),finalNote.text);
  assert.deepEqual(fs.readFileSync(path.join(root,'CCR Canvas','Assets',`${id}-${saved.sceneSha256}.json`)),scene);
  assert.deepEqual(fs.readFileSync(path.join(root,'CCR Canvas','Assets',`${id}-${saved.imageSha256}.png`)),image);
});

test('confirmed ink text and typed relations are readable in Markdown while JSON remains canonical', t => {
  const {vault,id,scene,image,first} = canvasFixture(t);
  const a=crypto.randomUUID(), b=crypto.randomUUID(), stroke=crypto.randomUUID();
  const next = Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,nodes:[
    {id:a,kind:'note',confidence:'confirmed',text:'카고24 (실기기 인식 교정 검증)',sourceStrokeIds:[stroke]},
    {id:b,kind:'box',confidence:'proposal',text:'다음 단계',sourceStrokeIds:[]}
  ],links:[{id:crypto.randomUUID(),kind:'parentChild',from:a,to:b}]}));
  const saved=vault.saveCanvas(id,2,next,image,first.noteSha256), note=vault.note(saved.path);
  assert.ok(note.text.includes('## 그림의 글자와 관계'));
  assert.ok(note.text.includes('카고24 (실기기 인식 교정 검증)'));
  assert.ok(note.text.includes(`${a} → ${b} · 부모·자식`));
  assert.ok(note.text.includes('확정 · 출처 획 1개'));
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),next);
});

test('지원하지 않는 종류는 마지막 정상 노트와 원본 바이트를 보존하며 거부한다', t => {
  const {vault,id,scene,image,first} = canvasFixture(t);
  const next=Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,nodes:[
    {id:crypto.randomUUID(),kind:'future',text:'원본 보존',sourceStrokeIds:[]}
  ]}));
  const original=Buffer.from(next),note=vault.note(first.path);
  assert.throws(() => vault.saveCanvas(id,2,next,image,first.noteSha256),/요소 종류/);
  assert.equal(vault.note(first.path).sha256,note.sha256);
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),scene);
  assert.deepEqual(next,original);
});

test('old structure notes migrate only on save and preserve the Markdown owned memo byte exactly', t => {
  const {vault,id,scene,image,first} = canvasFixture(t);
  const next=Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,nodes:[
    {id:crypto.randomUUID(),kind:'note',confidence:'confirmed',text:'원문'}]}));
  const saved=vault.saveCanvas(id,2,next,image,first.noteSha256), note=vault.note(saved.path);
  const legacy=note.text.split('\n## 그림의 글자와 관계')[0]+MEMO_BOUNDARY+MEMO;
  const edited=vault.save(saved.path,note.sha256,legacy);
  assert.equal(vault.canvas(id).noteSha256,edited.sha256);
  assert.equal(vault.note(saved.path).text,legacy);
  const migrated=vault.saveCanvas(id,2,next,image,edited.sha256);
  assert.ok(vault.note(saved.path).text.includes('<pre>원문</pre>'));
  assert.equal(vault.note(saved.path).text.split(MEMO_BOUNDARY)[1],MEMO);
  assert.equal(vault.canvas(id).noteSha256,migrated.noteSha256);
  const tampered=vault.save(saved.path,migrated.noteSha256,vault.note(saved.path).text.replace('<pre>원문','<pre>임의 변경'));
  assert.throws(()=>vault.canvas(id),{status:409});
  assert.throws(()=>vault.saveCanvas(id,2,next,image,tampered.sha256),{status:409});
  assert.equal(vault.note(saved.path).sha256,tampered.sha256);
});

test('readable projection is bounded without truncating canonical text or rewriting memo on overflow', t => {
  const {root,vault,id,scene,image,first} = canvasFixture(t);
  const next=Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,nodes:[
    {id:crypto.randomUUID(),kind:'note',text:'가'.repeat(23000)}]}));
  const saved=vault.saveCanvas(id,2,next,image,first.noteSha256), note=vault.note(saved.path);
  assert.ok(Buffer.byteLength(note.text)<66*1024);
  assert.ok(note.text.includes('일부 요소는 생략됐습니다.'));
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),next);
  const hugeMemo='m'.repeat(1024*1024-Buffer.byteLength(note.text.split(MEMO_BOUNDARY)[0]+MEMO_BOUNDARY));
  const edited=vault.save(saved.path,note.sha256,memoText(note,hugeMemo));
  const originalAssets=assets(root);
  const larger=Buffer.from(JSON.stringify({...JSON.parse(next),revision:3,nodes:[
    {id:crypto.randomUUID(),kind:'note',text:'작지만 이전보다 긴 실제 투영 글자'.repeat(30)}]}));
  assert.throws(()=>vault.saveCanvas(id,3,larger,image,edited.sha256),{status:409});
  assert.equal(vault.note(saved.path).sha256,edited.sha256);
  assert.deepEqual(assets(root),originalAssets);
});

test('derived Mermaid migrates old structure notes while preserving original assets and exact memo', t => {
  const {vault,id,scene,image,first}=canvasFixture(t);
  const a=crypto.randomUUID(), b=crypto.randomUUID();
  const next=Buffer.from(JSON.stringify({...JSON.parse(scene),revision:2,nodes:[
    {id:a,kind:'note',text:'Pencil 계획',confidence:'confirmed'},
    {id:b,kind:'box',text:'AI 수정',confidence:'confirmed'}],
    links:[{id:crypto.randomUUID(),from:a,to:b,label:'반영'}]}));
  const saved=vault.saveCanvas(id,2,next,image,first.noteSha256);
  const note=vault.note(saved.path);
  assert.ok(note.text.includes('```mermaid\nflowchart TD'));
  assert.ok(note.text.includes('n'+a.replaceAll('-','')));
  const old=note.text.replace(/\n## 다이어그램\n[\s\S]*?(?=\n<!-- ccr:markdown-memo:v1 -->)/,'');
  const legacy=vault.save(saved.path,note.sha256,old.split(MEMO_BOUNDARY)[0]+MEMO_BOUNDARY+MEMO);
  assert.equal(vault.canvas(id).noteSha256,legacy.sha256);
  const updated=vault.saveCanvas(id,2,next,image,legacy.sha256);
  assert.ok(vault.note(saved.path).text.includes('```mermaid'));
  assert.deepEqual(Buffer.from(vault.note(saved.path).text.split(MEMO_BOUNDARY)[1]),Buffer.from(MEMO));
  assert.deepEqual(Buffer.from(vault.canvas(id).sceneJSONBase64,'base64'),next);
  assert.equal(vault.canvas(id).noteSha256,updated.noteSha256);
  const tampered=vault.save(saved.path,updated.noteSha256,vault.note(saved.path).text.replace('flowchart TD','flowchart LR'));
  assert.throws(()=>vault.canvas(id),{status:409});
  assert.equal(vault.note(saved.path).sha256,tampered.sha256);
});
