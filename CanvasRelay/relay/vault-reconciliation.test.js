'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const child = require('node:child_process');
const {ObsidianVault} = require('./obsidian-vault');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'vault-save-boundary-reconciliation-'));
  t.after(() => fs.rmSync(root,{recursive:true,force:true}));
  const vault = new ObsidianVault(root),id = crypto.randomUUID();
  const scene = {schemaVersion:2,id,revision:1,width:200,height:100,drawingBase64:'',strokes:[],nodes:[],links:[],annotations:[]};
  const first = vault.saveCanvas(id,1,Buffer.from(JSON.stringify(scene)),png,null);
  const file = path.join(root,first.path),base = fs.readFileSync(file,'utf8'),external = base+'\n외부의 유일한 메모\n';
  return {root,vault,id,scene,first,file,base,external};
}
function exchangeAt(file,callback,operation) {
  const exec = child.execFileSync;let injected = false;
  child.execFileSync = function(program,args) {
    if (!injected && args?.[0]?.endsWith('vault-note-exchange.py') && args[2] === file) { injected = true;callback(); }
    return exec.apply(this,arguments);
  };
  try { const result = operation();assert.ok(injected);return result; }
  finally { child.execFileSync = exec; }
}
function makeConflict(f) {
  let error;
  exchangeAt(f.file,() => child.execFileSync(process.execPath,[path.join(__dirname,'test-input/vault-external-writer.cjs'),
    f.file,Buffer.from(f.external).toString('base64'),'atomic-replace']),() => {
    try { f.vault.saveCanvas(f.id,2,Buffer.from(JSON.stringify({...f.scene,revision:2})),png,f.first.noteSha256); }
    catch (caught) { error = caught; }
  });
  assert.equal(error?.code,'note_reconciliation_required');
  assert.equal(error.reconciliationRequired,true);assert.equal(error.status,409);
  const state = new ObsidianVault(f.root).canvasConflict(f.id);
  assert.equal(error.recoveryID,state.recoveryID);return state;
}
const request = (state,decision='keepCurrent') => ({recoveryID:state.recoveryID,expected:state.expected,decision});
const fresh = f => new ObsidianVault(f.root);
function preserved(f,state) {
  const folder = path.join(f.root,'CCR Canvas',`.ccr-save-${state.recoveryID}`);
  return {folder,files:['base','displaced','proposal'].map(kind => fs.readFileSync(path.join(folder,kind+'.md')))};
}

for (const decision of ['keepCurrent','useDisplaced']) test(`명시 ${decision}만 held를 해제하고 새 인스턴스와 정상 저장으로 복귀한다`,t => {
  const f = fixture(t),state = makeConflict(f),before = preserved(f,state);
  assert.equal(state.materials.active.sha256,state.materials.proposal.sha256,'원래 client SHA 자동해제 반례');
  assert.equal(Buffer.from(state.materials.displaced.markdownBase64,'base64').toString(),f.external);
  for (const get of [() => fresh(f).note(f.first.path),() => fresh(f).canvas(f.id)])
    assert.throws(get,{status:409,code:'note_reconciliation_required',recoveryID:state.recoveryID});
  assert.throws(() => fresh(f).saveCanvas(f.id,3,Buffer.from(JSON.stringify({...f.scene,revision:3})),png,state.expected.activeSha256),
    {status:409,code:'note_reconciliation_required'});
  assert.throws(() => fresh(f).save(f.first.path,state.expected.activeSha256,'not a canvas'),{code:'note_reconciliation_required'});
  assert.equal(fresh(f).save('other.md',null,'다른 노트의 독립 저장').text,'다른 노트의 독립 저장');
  const body = request(state,decision),result = fresh(f).resolveCanvasConflict(f.id,body);
  assert.equal(result.resolved,true);assert.equal(result.reconciliationRequired,false);
  if (process.env.CCR_RECONCILIATION_EXAMPLE && decision === 'useDisplaced')
    fs.writeFileSync(process.env.CCR_RECONCILIATION_EXAMPLE,JSON.stringify({get:state,put:body,result},null,2)+'\n');
  const selected = state.materials[decision === 'keepCurrent' ? 'active' : 'displaced'];
  assert.equal(fresh(f).note(f.first.path).sha256,selected.sha256);
  assert.equal(fresh(f).canvas(f.id).sceneSha256,selected.canvas.sceneSha256);
  assert.deepEqual(fresh(f).resolveCanvasConflict(f.id,body),result,'같은 ID·결정·원래 expected는 같은 결과');
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,{...body,decision:decision === 'keepCurrent' ? 'useDisplaced' : 'keepCurrent'}),{status:409});
  assert.throws(() => fresh(f).canvasConflict(f.id),{status:404});
  assert.deepEqual(preserved(f,state).files,before.files,'원래 세 자료를 삭제·변환하지 않는다');
  const saved = fresh(f).saveCanvas(f.id,3,Buffer.from(JSON.stringify({...f.scene,revision:3})),png,result.noteSha256);
  assert.equal(fresh(f).canvas(f.id).noteSha256,saved.noteSha256);
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,body),{status:409},'이후 정상 저장을 과거 조정 재시도로 되돌리지 않는다');
});

test('새 active·보존 자료 SHA가 다르면 조정하지 않으며 임의 경로·다른 Canvas ID도 거부한다',t => {
  const f = fixture(t),state = makeConflict(f),body = request(state),before = preserved(f,state);
  fs.appendFileSync(f.file,'\n조정 이후의 새 외부 메모\n');
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,body),{code:'note_reconciliation_required'});
  const newer = fresh(f).canvasConflict(f.id);
  fs.appendFileSync(path.join(before.folder,'displaced.md'),'\n열린 외부 fd의 추가 메모\n');
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,request(newer)),{code:'note_reconciliation_required'});
  assert.throws(() => fresh(f).resolveCanvasConflict(crypto.randomUUID(),body),{status:409});
  assert.throws(() => fresh(f).canvasConflict('../outside'),{status:400});
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,{...body,path:'/tmp/elsewhere'}),{status:400});
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,{...body,decision:'rollback'}),{status:400});
  assert.deepEqual(preserved(f,state).files[0],before.files[0]);
});

test('Canvas가 아닌 displaced는 명시 거부하고 유효한 현재 선택으로는 복귀할 수 있다',t => {
  const f = fixture(t);f.external = '외부가 쓴 일반 Markdown: 원본을 버리지 않는다.';
  const state = makeConflict(f),before = preserved(f,state);
  assert.equal(state.materials.displaced.validCanvas,false);
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,request(state,'useDisplaced')),
    {status:409,code:'reconciliation_candidate_invalid',recoveryID:state.recoveryID});
  assert.deepEqual(preserved(f,state).files,before.files);
  assert.equal(fresh(f).resolveCanvasConflict(f.id,request(state)).resolved,true);
});

for (const failure of ['exchange-unavailable','resolution-write','late-external']) test(`조정 중 ${failure} 실패는 원본과 시도를 보존하며 명시 재조정할 수 있다`,t => {
  const f = fixture(t),state = makeConflict(f),body = request(state),before = preserved(f,state);
  const exec = child.execFileSync,open = fs.openSync;
  let injected = false;
  if (failure === 'exchange-unavailable') child.execFileSync = function(program,args) {
    if (args?.[0]?.endsWith('vault-note-exchange.py')) { injected = true;throw new Error('fixture unsupported exchange'); }
    return exec.apply(this,arguments);
  };
  if (failure === 'resolution-write') fs.openSync = function(file,flags) {
    if (String(file).endsWith('/resolution.json') && flags === 'wx') { injected = true;throw new Error('fixture disk full'); }
    return open.apply(this,arguments);
  };
  try {
    if (failure === 'late-external') exchangeAt(f.file,() => { injected = true;fs.appendFileSync(f.file,'\n조정 전환의 외부 변경\n'); },
      () => assert.throws(() => fresh(f).resolveCanvasConflict(f.id,body),{code:'note_reconciliation_required'}));
    else assert.throws(() => fresh(f).resolveCanvasConflict(f.id,body),{code:'note_reconciliation_required'});
  } finally { child.execFileSync = exec;fs.openSync = open; }
  assert.ok(injected);assert.deepEqual(preserved(f,state).files,before.files);
  assert.throws(() => fresh(f).canvas(f.id),{code:'note_reconciliation_required'});
  const after = fresh(f).canvasConflict(f.id);
  assert.notEqual(after.recoveryID,state.recoveryID);assert.equal(after.history.length,1);
  assert.notEqual(after.expected.historySha256,state.expected.historySha256);
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,body),{code:'note_reconciliation_required'});
  const decision = failure === 'late-external' ? 'useDisplaced' : 'keepCurrent';
  if (failure === 'late-external') assert.match(Buffer.from(after.materials.displaced.markdownBase64,'base64').toString(),/조정 전환의 외부 변경/);
  assert.equal(fresh(f).resolveCanvasConflict(f.id,request(after,decision)).resolved,true);
  assert.throws(() => fresh(f).canvasConflict(f.id),{status:404});
  if (failure === 'late-external') assert.match(fresh(f).note(f.first.path).text,/조정 전환의 외부 변경/);
});

test('최종 기록 fsync 실패도 기록을 미확정 자료로 보존하고 held를 유지한다',t => {
  const f = fixture(t),state = makeConflict(f),sync = fs.fsyncSync,open = fs.openSync;let injected = false,resolutionFD;
  fs.openSync = function(file,flags) {
    const fd = open.apply(this,arguments);
    if (String(file).endsWith('/resolution.json') && flags === 'wx') resolutionFD = fd;
    return fd;
  };
  fs.fsyncSync = function(fd) {
    if (!injected && fd === resolutionFD) { injected = true;throw new Error('fixture fsync failure'); }
    return sync.apply(this,arguments);
  };
  try { assert.throws(() => fresh(f).resolveCanvasConflict(f.id,request(state)),{code:'note_reconciliation_required'}); }
  finally { fs.fsyncSync = sync;fs.openSync = open; }
  assert.ok(injected);
  const after = fresh(f).canvasConflict(f.id);
  assert.notEqual(after.recoveryID,state.recoveryID);
  assert.equal(fresh(f).resolveCanvasConflict(f.id,request(after)).resolved,true);
});

test('receipt 전 중단된 durable intent도 재시작에서 held로 읽는다',t => {
  const f = fixture(t),state = makeConflict(f),{folder} = preserved(f,state);
  fs.renameSync(path.join(folder,'receipt.json'),path.join(folder,'receipt-interrupted.json'));
  assert.throws(() => fresh(f).canvas(f.id),{code:'note_reconciliation_required',recoveryID:state.recoveryID});
  assert.equal(fresh(f).resolveCanvasConflict(f.id,request(fresh(f).canvasConflict(f.id))).resolved,true);
});

test('복구 경로와 asset의 symlink·손상된 PNG는 재열기로 수용하지 않는다',t => {
  const f = fixture(t),state = makeConflict(f),{folder} = preserved(f,state);
  const asset = path.join(f.root,'CCR Canvas/Assets',`${f.id}-${state.materials.active.canvas.imageSha256}.png`);
  fs.writeFileSync(asset,'invalid PNG');
  const damaged = fresh(f).canvasConflict(f.id);
  assert.equal(damaged.materials.active.validCanvas,false);
  assert.throws(() => fresh(f).resolveCanvasConflict(f.id,request(damaged)),{code:'reconciliation_candidate_invalid'});
  fs.renameSync(path.join(folder,'proposal.md'),path.join(folder,'proposal-original.md'));
  fs.symlinkSync(f.file,path.join(folder,'proposal.md'));
  assert.throws(() => fresh(f).canvasConflict(f.id),{status:409});
});

test('일반 저장의 최종 영수증 fsync 실패도 성공 원장으로 오인하지 않는다',t => {
  const f = fixture(t),sync = fs.fsyncSync,open = fs.openSync;let injected = false,receiptFD;
  fs.openSync = function(file,flags) {
    const fd = open.apply(this,arguments);
    if (String(file).endsWith('/receipt.json') && flags === 'wx') receiptFD = fd;
    return fd;
  };
  fs.fsyncSync = function(fd) {
    if (!injected && fd === receiptFD) { injected = true;throw new Error('fixture receipt fsync failure'); }
    return sync.apply(this,arguments);
  };
  try { assert.throws(() => fresh(f).saveCanvas(f.id,2,Buffer.from(JSON.stringify({...f.scene,revision:2})),png,f.first.noteSha256),
    {code:'note_reconciliation_required'}); }
  finally { fs.fsyncSync = sync;fs.openSync = open; }
  assert.ok(injected);
  assert.throws(() => fresh(f).canvas(f.id),{code:'note_reconciliation_required'});
  const state = fresh(f).canvasConflict(f.id);
  assert.equal(fresh(f).resolveCanvasConflict(f.id,request(state)).resolved,true);
});

test('socket 없는 서버 경로 검사는 기존 인증·typed GET 거부·명시 PUT·재저장을 같은 계약으로 처리한다',async t => {
  const f = fixture(t),{createServer} = require('./server'),{PassThrough} = require('node:stream');
  const token = 'synthetic-reconciliation-only',store = path.join(f.root,'packets');
  const server = createServer({store,vaultRoot:f.root,token,deliveryReady:() => false,
    snapshotPath:path.join(f.root,'absent'),hiddenPath:path.join(f.root,'absent'),
    deliver:() => assert.fail('실제 발송 금지')});
  t.after(() => server.close());
  const call = (url,method='GET',body,authorized=true) => new Promise(resolve => {
    const req = new PassThrough();Object.assign(req,{url,method,headers:authorized ? {'x-canvas-token':token} : {}});
    server.emit('request',req,{writeHead(status) { this.status = status; },end(value) { resolve({status:this.status,body:JSON.parse(value)}); }});
    req.end(body === undefined ? '' : JSON.stringify(body));
  });
  const state = makeConflict(f),url = '/vault/canvas/conflict?id='+f.id;
  assert.equal((await call(url,'GET',undefined,false)).status,401);
  assert.equal((await call(url,'PUT',request(state),false)).status,401);
  for (const route of ['/vault/canvas?id='+f.id,'/vault/note?path='+encodeURIComponent(f.first.path)]) {
    const held = await call(route);assert.equal(held.status,409);assert.equal(held.body.code,'note_reconciliation_required');
    assert.equal(held.body.recoveryID,state.recoveryID);assert.equal(held.body.reconciliationRequired,true);
    assert.equal(held.body.publicationAttempted,true);
  }
  const read = await call(url);assert.equal(read.status,200);assert.deepEqual(read.body.expected,state.expected);
  const denied = await call('/vault/note?path='+encodeURIComponent(f.first.path),'PUT',{baseSha256:state.expected.activeSha256,text:'unsafe'});
  assert.equal(denied.status,409);assert.equal(denied.body.code,'note_reconciliation_required');
  assert.equal((await call('/vault/canvas/conflict?id='+encodeURIComponent('../bad'))).status,400);
  assert.equal((await call(url+'&path='+encodeURIComponent('/tmp/forbidden'))).status,400);
  const resolved = await call(url,'PUT',request(state,'useDisplaced'));
  assert.equal(resolved.status,200);assert.equal(resolved.body.resolved,true);
  assert.deepEqual((await call(url,'PUT',request(state,'useDisplaced'))).body,resolved.body);
  const reopened = await call('/vault/canvas?id='+f.id);assert.equal(reopened.status,200);
  const saved = await call('/vault/canvas?id='+f.id,'PUT',{baseSha256:reopened.body.noteSha256,revision:3,
    sceneJSONBase64:Buffer.from(JSON.stringify({...f.scene,revision:3})).toString('base64'),imagePNGBase64:png.toString('base64')});
  assert.equal(saved.status,200);assert.equal((await call('/vault/canvas?id='+f.id)).body.noteSha256,saved.body.noteSha256);
});

test('같은 실제 노트의 대소문자 별칭 경로도 미조정 상태를 우회하지 않는다',t => {
  const f = fixture(t),state = makeConflict(f),alias = f.first.path.toUpperCase().replace(/\.MD$/,'.md');
  if (!fs.existsSync(path.join(f.root,alias))) { t.skip('대소문자를 구분하는 파일시스템');return; }
  assert.equal(fs.statSync(path.join(f.root,alias)).ino,fs.statSync(f.file).ino);
  assert.throws(() => fresh(f).note(alias),{code:'note_reconciliation_required',recoveryID:state.recoveryID});
  assert.throws(() => fresh(f).save(alias,state.expected.activeSha256,'같은 경로의 우회 저장'),{code:'note_reconciliation_required'});
  const result = fresh(f).resolveCanvasConflict(f.id,request(state));
  assert.equal(fresh(f).note(alias).sha256,result.noteSha256);
  assert.equal(fresh(f).save(alias,result.noteSha256,fresh(f).note(alias).text+'\n별칭 경로의 명시 조정 후 메모\n').path,alias);
});
