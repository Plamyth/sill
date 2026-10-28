'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const child = require('node:child_process');
const {ObsidianVault} = require('./obsidian-vault');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
function fixture(t,relative='Notes/발췌 e\u0301.md') {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'vault-save-boundary-note-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  fs.mkdirSync(path.join(root,'Notes'));
  const vault=new ObsidianVault(root),base='\uFEFF# PDF 원문\r\n\r\n원문 인용 e\u0301 📝 ^excerpt\r\n',proposal=base+'\r\niPad 미전송 초안\r\n';
  const first=vault.save(relative,null,base),file=path.join(root,relative);
  return {root,vault,relative,base,proposal,first,file,external:base+'\r\n외부 작성자의 유일한 메모\r\n'};
}
const fresh=f=>new ObsidianVault(f.root);
function atExchange(f,write,operation) {
  const original=child.execFileSync;let called=false;
  child.execFileSync=function(program,args) {
    if (!called && args?.[0]?.endsWith('vault-note-exchange.py') && args[2]===f.file) { called=true;write(); }
    return original.apply(this,arguments);
  };
  try { operation();assert.ok(called,'실제 교환 지점 도달'); }
  finally {child.execFileSync=original;}
}
function makeConflict(f,bytes=Buffer.from(f.external)) {
  atExchange(f,()=>child.execFileSync(process.execPath,[path.join(__dirname,'test-input/vault-external-writer.cjs'),
    f.file,bytes.toString('base64'),'atomic-replace']),()=>assert.throws(()=>fresh(f).save(f.relative,f.first.sha256,f.proposal),{status:409,code:'note_reconciliation_required'}));
  return fresh(f).noteConflict(f.relative);
}
const request=(state,decision='keepCurrent')=>({recoveryID:state.recoveryID,expected:state.expected,decision});
function files(f,state) {
  const folder=path.join(path.dirname(f.file),'.ccr-save-'+state.recoveryID);
  return Object.fromEntries(['base','displaced','proposal'].map(kind=>[kind,fs.readFileSync(path.join(folder,kind+'.md'))]));
}
for (const decision of ['keepCurrent','useDisplaced']) test(`일반노트 ${decision}: GET→명시PUT→새 note재열기→일반쓰기 복귀 및 원문3종 보존`,t=>{
  const f=fixture(t),state=makeConflict(f),before=files(f,state),body=request(state,decision);
  assert.equal(state.schema,'ccr.note-conflict/v1');assert.equal(state.path,f.relative);
  assert.equal(state.materials.active.validNote,true);assert.equal(state.materials.displaced.validNote,true);
  assert.equal(state.materials.active.sha256,state.materials.proposal.sha256);
  for (const kind of ['base','displaced','proposal']) assert.deepEqual(Buffer.from(state.materials[kind].markdownBase64,'base64'),before[kind]);
  assert.throws(()=>fresh(f).note(f.relative),{code:'note_reconciliation_required',recoveryID:state.recoveryID});
  assert.throws(()=>fresh(f).save(f.relative,state.expected.activeSha256,'새 초안'),{code:'note_reconciliation_required'});
  const result=fresh(f).resolveNoteConflict(f.relative,body),selected=state.materials[decision==='keepCurrent'?'active':'displaced'];
  assert.deepEqual(result,{path:f.relative,sha256:selected.sha256,recoveryID:state.recoveryID,decision,resolved:true,reconciliationRequired:false});
  assert.equal(fresh(f).note(f.relative).sha256,selected.sha256);
  assert.deepEqual(fs.readFileSync(f.file),Buffer.from(selected.markdownBase64,'base64'),'BOM/CRLF/NFD/한글/이모지 바이트 유지');
  const count=fs.readdirSync(path.dirname(f.file)).length;
  assert.deepEqual(fresh(f).resolveNoteConflict(f.relative,body),result);
  assert.equal(fs.readdirSync(path.dirname(f.file)).length,count,'동일요청 재게시0');
  assert.deepEqual(files(f,state),before);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,{...body,decision:decision==='keepCurrent'?'useDisplaced':'keepCurrent'}),{status:409});
  assert.throws(()=>fresh(f).noteConflict(f.relative),{status:404});
  const read=fresh(f).note(f.relative),saved=fresh(f).save(f.relative,read.sha256,read.text+'\r\n명시조정 뒤 정상 입력');
  assert.equal(fresh(f).note(f.relative).sha256,saved.sha256);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,body),{status:409});
  if (process.env.CCR_NOTE_EXAMPLE && decision==='useDisplaced') fs.writeFileSync(process.env.CCR_NOTE_EXAMPLE,JSON.stringify({get:state,put:body,result},null,2)+'\n');
});

test('서로 다른 note/복구ID와 새 expected·직접text/path·대문자 ID·잘못된 종류는 거부한다',t=>{
  const f=fixture(t),state=makeConflict(f),body=request(state);
  fresh(f).save('Notes/other.md',null,'다른 문서');
  assert.throws(()=>fresh(f).resolveNoteConflict('Notes/other.md',body),{status:409});
  for (const mutation of [{...body,text:'무검증덮기'},{...body,path:'/tmp/else'},{...body,recoveryID:body.recoveryID.toUpperCase()},
    {...body,decision:'automatic'},{...body,expected:{...body.expected,extra:true}}])
    assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,mutation),{status:400});
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,{...body,expected:{...body.expected,activeSha256:'0'.repeat(64)}}),{code:'note_reconciliation_required'});
  fs.appendFileSync(f.file,'새 외부 변경');
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,body),{code:'note_reconciliation_required'});
  const newer=fresh(f).noteConflict(f.relative),folder=path.join(path.dirname(f.file),'.ccr-save-'+state.recoveryID);
  fs.appendFileSync(path.join(folder,'displaced.md'),'보존 원본 추가 변경');
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(newer)),{code:'note_reconciliation_required'});
  for (const relative of ['../outside.md','/tmp/out.md','Notes/.hidden.md','Notes/a.pdf','Notes//a.md','Notes/../a.md'])
    assert.throws(()=>fresh(f).noteConflict(relative),{status:400});
});

test('일반노트 resolved R 재시도도 active SHA가 같은 새 독립 J의 typed409를 먼저 반환한다',t=>{
  const f=fixture(t),r=makeConflict(f),body=request(r),result=fresh(f).resolveNoteConflict(f.relative,body);
  f.first=fresh(f).note(f.relative);f.proposal=f.first.text;f.external=f.first.text+'새 독립 J의 외부 메모';
  const j=makeConflict(f);assert.notEqual(j.recoveryID,r.recoveryID);assert.equal(j.expected.activeSha256,result.sha256);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,body),{code:'note_reconciliation_required',recoveryID:j.recoveryID});
  fresh(f).resolveNoteConflict(f.relative,request(j,'useDisplaced'));
  assert.equal(fresh(f).note(f.relative).text,f.external);
});

for (const failure of ['external','exchange','resolution-fsync']) test(`일반노트 조정 중 ${failure} 실패는 새 원장·이전3종 유지 후 명시 복귀`,t=>{
  const f=fixture(t),state=makeConflict(f),before=files(f,state),open=fs.openSync,sync=fs.fsyncSync,exec=child.execFileSync;
  let resolutionFD,called=false;
  if (failure==='exchange') child.execFileSync=function(program,args){if(args?.[0]?.endsWith('vault-note-exchange.py')){called=true;throw Error('fixture no exchange');}return exec.apply(this,arguments);};
  if (failure==='resolution-fsync') {
    fs.openSync=function(file,flags){const fd=open.apply(this,arguments);if(String(file).endsWith('/resolution.json')&&flags==='wx')resolutionFD=fd;return fd;};
    fs.fsyncSync=function(fd){if(!called&&fd===resolutionFD){called=true;throw Error('fixture fsync failed');}return sync.apply(this,arguments);};
  }
  try {
    if(failure==='external')atExchange(f,()=>{called=true;fs.appendFileSync(f.file,'\r\n조정 중 새 외부 메모');},()=>assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(state)),{code:'note_reconciliation_required'}));
    else assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(state)),{code:'note_reconciliation_required'});
  }finally{child.execFileSync=exec;fs.openSync=open;fs.fsyncSync=sync;}
  assert.ok(called);assert.deepEqual(files(f,state),before);
  const latest=fresh(f).noteConflict(f.relative);assert.notEqual(latest.recoveryID,state.recoveryID);assert.equal(latest.history.length,1);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(state)),{code:'note_reconciliation_required',recoveryID:latest.recoveryID});
  const decision=failure==='external'?'useDisplaced':'keepCurrent';
  if(failure==='external')assert.match(Buffer.from(latest.materials.displaced.markdownBase64,'base64').toString(),/조정 중 새 외부 메모/);
  assert.equal(fresh(f).resolveNoteConflict(f.relative,request(latest,decision)).resolved,true);
  assert.throws(()=>fresh(f).noteConflict(f.relative),{status:404});
});

for(const damaged of ['invalid-utf8','too-large','symlink'])test(`일반노트 ${damaged} 후보는 재작성·성공 처리 없이 보존한다`,t=>{
  const f=fixture(t),state=makeConflict(f),folder=path.join(path.dirname(f.file),'.ccr-save-'+state.recoveryID),file=path.join(folder,'displaced.md');
  let bytes=Buffer.from([0xff,0xfe,0xc0]);
  if(damaged==='invalid-utf8'){
    fs.writeFileSync(file,bytes);const read=fresh(f).noteConflict(f.relative);
    assert.equal(read.materials.displaced.validNote,false);assert.deepEqual(Buffer.from(read.materials.displaced.markdownBase64,'base64'),bytes);
    assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(read,'useDisplaced')),{code:'reconciliation_candidate_invalid'});
    assert.deepEqual(fs.readFileSync(file),bytes);assert.equal(fresh(f).resolveNoteConflict(f.relative,request(read)).resolved,true);
  }else{
    if(damaged==='too-large'){bytes=Buffer.alloc(1024*1024+1,65);fs.writeFileSync(file,bytes);}
    else {fs.renameSync(file,file+'.original');fs.symlinkSync(f.file,file);}
    assert.throws(()=>fresh(f).noteConflict(f.relative),{status:409});
    assert.throws(()=>fresh(f).note(f.relative),{code:'note_reconciliation_required'});
    if(damaged==='too-large')assert.deepEqual(fs.readFileSync(file),bytes);else assert.ok(fs.lstatSync(file).isSymbolicLink());
  }
});

test('managed Canvas 경로·대소문자·inode별칭·managed 선택본은 일반노트 복구로 우회하지 못한다',t=>{
  const f=fixture(t),id=crypto.randomUUID(),scene={schemaVersion:2,id,revision:1,width:100,height:100,drawingBase64:'',strokes:[],nodes:[],links:[],annotations:[]};
  const saved=f.vault.saveCanvas(id,1,Buffer.from(JSON.stringify(scene)),png,null),alias='Notes/canvas-alias.md';
  fs.linkSync(path.join(f.root,saved.path),path.join(f.root,alias));
  for(const relative of [saved.path,saved.path.replace('CCR Canvas','ccr canvas'),alias])assert.throws(()=>fresh(f).noteConflict(relative),{status:409});
  const state=makeConflict(f),folder=path.join(path.dirname(f.file),'.ccr-save-'+state.recoveryID),selected=path.join(folder,'displaced.md');
  const managed=fs.readFileSync(path.join(f.root,saved.path));fs.writeFileSync(selected,managed);
  const read=fresh(f).noteConflict(f.relative);assert.equal(read.materials.displaced.validNote,false);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(read,'useDisplaced')),{code:'reconciliation_candidate_invalid'});
  assert.deepEqual(fs.readFileSync(selected),managed);
  assert.equal(fresh(f).canvas(id).noteSha256,saved.noteSha256);
});

test('파일 소유자 조건과 일반 파일 경로의 symlink 거부를 note 복구에도 적용한다',t=>{
  const f=fixture(t),state=makeConflict(f),folder=path.join(path.dirname(f.file),'.ccr-save-'+state.recoveryID),target=path.join(folder,'displaced.md');
  const open=fs.openSync,stat=fs.fstatSync;let foreign;
  fs.openSync=function(file){const fd=open.apply(this,arguments);if(file===target)foreign=fd;return fd;};
  fs.fstatSync=function(fd){const value=stat.apply(this,arguments);if(fd===foreign)value.uid+=1;return value;};
  try{assert.throws(()=>fresh(f).noteConflict(f.relative),{status:409});}finally{fs.openSync=open;fs.fstatSync=stat;}
  fs.symlinkSync(f.file,path.join(f.root,'Notes/symlink.md'));
  assert.throws(()=>fresh(f).noteConflict('Notes/symlink.md'),{status:400});
  assert.equal(fresh(f).resolveNoteConflict(f.relative,request(state)).resolved,true);
});

test('socket 없는 note/conflict route는 기존 인증·자료GET·명시PUT·PDF발췌 block 일반쓰기 복귀를 처리한다',async t=>{
  const f=fixture(t,'Notes/excerpt.md'),{createServer}=require('./server'),{PassThrough}=require('node:stream');
  const token='synthetic-note-reconciliation-token-only';
  const server=createServer({store:path.join(f.root,'packets'),vaultRoot:f.root,token,snapshotPath:path.join(f.root,'absent'),hiddenPath:path.join(f.root,'absent'),deliveryReady:()=>false});
  t.after(()=>server.close());
  const call=(url,method='GET',body,authorized=true)=>new Promise(resolve=>{
    const req=new PassThrough();Object.assign(req,{url,method,headers:authorized?{'x-canvas-token':token}:{}});
    server.emit('request',req,{writeHead(status){this.status=status;},end(bytes){resolve({status:this.status,body:JSON.parse(bytes)});}});req.end(body===undefined?'':JSON.stringify(body));
  });
  const state=makeConflict(f),url='/vault/note/conflict?path='+encodeURIComponent(f.relative);
  assert.equal((await call(url,'GET',undefined,false)).status,401);
  assert.equal((await call(url,'PUT',request(state),false)).status,401);
  assert.equal((await call(url+'&path=x.md')).status,400);assert.equal((await call(url+'&text=no')).status,400);
  const read=await call(url);assert.equal(read.status,200);assert.equal(read.body.schema,'ccr.note-conflict/v1');
  assert.equal((await call('/vault/note?path='+encodeURIComponent(f.relative))).body.code,'note_reconciliation_required');
  assert.equal((await call('/vault/block?path='+encodeURIComponent(f.relative)+'&blockID=excerpt')).body.code,'note_reconciliation_required');
  const resolved=await call(url,'PUT',request(read.body,'useDisplaced'));assert.equal(resolved.status,200);assert.equal(resolved.body.resolved,true);
  const note=await call('/vault/note?path='+encodeURIComponent(f.relative));assert.equal(note.status,200);assert.equal(note.body.text,f.external);
  const block=await call('/vault/block?path='+encodeURIComponent(f.relative)+'&blockID=excerpt');assert.equal(block.status,200);
  const edited=await call('/vault/block?path='+encodeURIComponent(f.relative)+'&blockID=excerpt','PUT',{
    schemaVersion:1,operationId:crypto.randomUUID(),baseSha256:note.body.sha256,baseQuoteSha256:block.body.quoteSha256,replacementText:'원문 대조 후 발췌 수정'});
  assert.equal(edited.status,200);assert.match(fresh(f).note(f.relative).text,/원문 대조 후 발췌 수정/);
});

test('일반노트 정확 1MiB와 빈 선택본도 원문 그대로 복구하고 8MiB 응답 한도 안에 있다',t=>{
  const f=fixture(t,'Notes/limit.md'),large='한'.repeat(Math.floor((1024*1024-1)/3))+'X';
  f.first=fresh(f).save(f.relative,f.first.sha256,large);f.proposal=large.slice(0,-1)+'Y';
  atExchange(f,()=>fs.writeFileSync(f.file,large.slice(0,-1)+'Z'),()=>assert.throws(()=>fresh(f).save(f.relative,f.first.sha256,f.proposal),{code:'note_reconciliation_required'}));
  const state=fresh(f).noteConflict(f.relative);assert.ok(Buffer.byteLength(JSON.stringify(state))<8*1024*1024);
  assert.equal(fresh(f).resolveNoteConflict(f.relative,request(state,'useDisplaced')).sha256,sha(Buffer.from(large.slice(0,-1)+'Z')));
  f.first=fresh(f).note(f.relative);f.proposal='';
  atExchange(f,()=>fs.writeFileSync(f.file,large.slice(0,-1)+'Q'),()=>assert.throws(()=>fresh(f).save(f.relative,f.first.sha256,''),{code:'note_reconciliation_required'}));
  const empty=fresh(f).noteConflict(f.relative);assert.equal(empty.materials.active.validNote,true);assert.equal(empty.materials.active.markdownBase64,'');
  fresh(f).resolveNoteConflict(f.relative,request(empty));assert.equal(fresh(f).note(f.relative).text,'');
});

test('삭제된 active는 자료GET의 null로 남고 useDisplaced의 독점생성으로만 복구한다',t=>{
  const f=fixture(t),state=makeConflict(f),before=files(f,state);fs.renameSync(f.file,f.file+'.external-preserved');
  const read=fresh(f).noteConflict(f.relative);assert.equal(read.materials.active,null);assert.equal(read.expected.activeSha256,null);
  assert.throws(()=>fresh(f).resolveNoteConflict(f.relative,request(read)),{code:'reconciliation_candidate_invalid'});
  fresh(f).resolveNoteConflict(f.relative,request(read,'useDisplaced'));
  assert.deepEqual(fs.readFileSync(f.file),before.displaced);assert.deepEqual(files(f,state),before);
});

test('자료 read의 부모 경로가 마지막 open에서 symlink로 바뀌면 FD 식별자 검사로 거부한다',t=>{
  const f=fixture(t),state=makeConflict(f),other=path.join(f.root,'other');fs.mkdirSync(other);
  fs.writeFileSync(path.join(other,path.basename(f.file)),'반환하면 안 되는 다른 경로 원문');
  const open=fs.openSync;let changed=false;
  fs.openSync=function(file,flags){
    if(!changed && file===f.file){changed=true;fs.renameSync(path.join(f.root,'Notes'),path.join(f.root,'Notes-original'));fs.symlinkSync(other,path.join(f.root,'Notes'));}
    return open.apply(this,arguments);
  };
  try{assert.throws(()=>fresh(f).noteConflict(f.relative),{status:409});}finally{fs.openSync=open;}
  assert.ok(changed);assert.equal(fs.readFileSync(path.join(other,path.basename(f.file)),'utf8'),'반환하면 안 되는 다른 경로 원문');
  fs.renameSync(path.join(f.root,'Notes'),path.join(f.root,'Notes-rejected-link'));
  fs.renameSync(path.join(f.root,'Notes-original'),path.join(f.root,'Notes'));
  assert.equal(fresh(f).resolveNoteConflict(f.relative,request(state)).resolved,true);
});
