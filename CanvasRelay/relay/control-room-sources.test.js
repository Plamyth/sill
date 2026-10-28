'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {controlRoomSources}=require('./control-room-sources');
const {ControlRoomEvents}=require('./control-room-events');
const fixture=require('./vendor/mobile-control/mobile-control-events-v1.json');
const {projectControl}=require('./vendor/mobile-control/mobile-control');
const first=fixture.events[0].snapshot;
const now=()=>Date.parse(first.generatedAt);
const generation='11111111-1111-4111-8111-111111111111';
const empty={schemaVersion:1,generatedAt:first.generatedAt,threads:[],catalog:[],mobile:{workspaces:[]}};
const normalized=()=>first.unifiedControl.rows.map(row=>({...row,native:row.source==='codex'?
  {id:row.externalId,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,
    activeTurnId:row.activeTurnId,sourceConnection:row.sourceConnection}:undefined}));

test('모바일 투영과 예제는 exact Android 계약 바이트다',()=>{
 const directory=path.join(__dirname,'vendor/mobile-control');
 const provenance=require('./vendor/mobile-control/provenance');
 assert.equal(provenance.commit,'9a91483f5e054ad8f30e9a1d43d8e7fd91740c6a');
 assert.equal(provenance.tree,'4f7581661680f466a363ad7199ae1db54874163e');
 assert.deepEqual(provenance.files.map(item=>item.sha256),[
  '376a68815e29f8b936ae0b09f5f4c7833ad7f84c78760533bf0c66a2e38b13bc',
  '9fb6288d6ac3d68f4d743d8703b091f263664d239248b53e6ba82d8cb554b319',
  '6c7ab01210c7e1dbaddf0b85e9b23555626019b750e03b0436cb4ebef4f22700']);
 assert.equal(provenance.commandsExposed,false);
 for(const item of provenance.files)assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(directory,item.file))).digest('hex'),item.sha256);
});

test('정규화행을 명시 주입하면 공통 allowlist와 같은 결과이며 비공개 값은 빠진다',()=>{
 const raw={...empty,sourceConnections:first.sourceConnections,privateRaw:'제외해야 하는 값'};
 const rows=()=>normalized().map(row=>({...row,privateRaw:'행 비공개 값'}));
 const result=controlRoomSources(raw,new Set(),now(),rows);
 assert.deepEqual(result,projectControl(raw,{hidden:new Set(),workspace:'all',rows}));
 assert.equal(result.unifiedControl.rows.length,first.unifiedControl.rows.length);
 assert.ok(!JSON.stringify(result).includes('제외해야 하는 값'));
 assert.ok(!JSON.stringify(result).includes('행 비공개 값'));
 assert.ok(result.unifiedControl.rows.every(row=>row.source===row.provider));
});

test('읽기 정규화 실패는 오류와 빈 행이며 명령을 발행하지 않는다',()=>{
 const result=controlRoomSources(empty,new Set(),now(),()=>{throw Error('합성 정규화 미지원');});
 assert.deepEqual(result.unifiedControl.rows,[]);
 assert.equal(typeof result.unifiedControl.error,'string');
 assert.equal(result.unifiedControl.truncated,false);
});

test('4000 Codex 뒤 Cursor 두 출처를 보존하고 소유자 숨김을 적용한다',()=>{
 const rows=Array.from({length:4000},(_,i)=>{
  const id=i === 0 ? normalized()[0].externalId : `${i.toString(16).padStart(8,'0')}-0000-4000-8000-000000000000`;
  return {key:'codex:'+id,source:'codex',externalId:id,ownerThreadId:id,ownerVerified:true,
   title:'동일한 제목',fresh:true,capabilities:{read:true,send:false},native:{id,source:'codex',hostId:'local',
    forkedFromId:null,forkLineageVerified:true}};
 });
 rows.push(...normalized().filter(row=>row.source!=='codex'));
 const result=controlRoomSources(empty,new Set(),now(),()=>rows);
 assert.equal(result.unifiedControl.rows.length,rows.length);
 assert.ok(result.unifiedControl.rows.some(row=>row.source==='cursor-desktop'));
 assert.ok(result.unifiedControl.rows.some(row=>row.source==='cursor-cloud'));
 const hidden=new Set([rows.at(-1).ownerThreadId,rows[0].externalId].filter(Boolean));
 const filtered=controlRoomSources(empty,hidden,now(),()=>rows);
 assert.ok(!filtered.unifiedControl.rows.some(row=>hidden.has(row.externalId)||hidden.has(row.ownerThreadId)));
});

test('SSE의 소스목록은 같은 공통투영을 쓰고 정책 차단으로 제거된다',()=>{
 let hidden=new Set();
 const adapter=new ControlRoomEvents({now,readHiddenIds:()=>hidden,
  projectSources:(raw,concealed)=>controlRoomSources(raw,concealed,now(),normalized)});
 try{
  adapter.apply(empty,{generation,revision:0});
  assert.equal(adapter.snapshot.unifiedControl.rows.length,first.unifiedControl.rows.length);
  const observed=adapter.snapshot.sourceObservedAt;
  const revision=adapter.revision;
  adapter.heartbeat();assert.equal(adapter.revision,revision);
  assert.equal(adapter.snapshot.sourceObservedAt,observed);
  hidden=null;
  adapter.readHiddenIds=()=>{throw Error('정책 확인 실패');};
  adapter.refreshPolicy();
  assert.equal(adapter.snapshot.unifiedControl,undefined);
  assert.equal(adapter.snapshot.sourceConnections,undefined);
  assert.equal(adapter.snapshot.connection.state,'unavailable');
  assert.equal(adapter.snapshot.sourceObservedAt,observed);
 }finally{adapter.close();}
});

test('기본 읽기 어댑터는 본체 rows에 null binding과 원래 평가시각을 전달한다',()=>{
 const directory=fs.mkdtempSync(path.join(__dirname,'..','.s'));
 fs.chmodSync(directory,0o700);
 const previous=process.env.CCR_BRIDGE_HELPER;
 try {
  fs.writeFileSync(path.join(directory,'unified-control.js'),`'use strict';
const assert=require('node:assert/strict');
exports.rows=(snapshot,bindings,clock,hidden)=>{
 assert.equal(bindings,null);assert.equal(clock,snapshot.expectedClock);
 assert.equal(hidden.has('hidden-owner'),true);return [];
};\n`,{mode:0o600});
  process.env.CCR_BRIDGE_HELPER=path.join(directory,'bridge.js');
  const result=controlRoomSources({...empty,expectedClock:1234},new Set(['hidden-owner']),1234);
  assert.equal(result.unifiedControl.error,null);
  assert.deepEqual(result.unifiedControl.rows,[]);
 }finally{
  if(previous===undefined)delete process.env.CCR_BRIDGE_HELPER;
  else process.env.CCR_BRIDGE_HELPER=previous;
  delete require.cache[path.join(directory,'unified-control.js')];
  fs.rmSync(directory,{recursive:true,force:true});
 }
});

test('출처 요약이 연결 중이어도 개별 Codex 실행 결박 불일치는 전송 가능이 아니다',()=>{
 const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 const native={id,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,
  activeTurnId:'run-new',sourceConnection:{provider:'codex',
  sessionId:id,runId:'run-old',sourceRevision:1,owner:'owner-a',connected:true,state:'connected'}};
 const row={source:'codex',key:'codex:'+id,externalId:id,ownerVerified:true,ownerThreadId:id,
  fresh:true,capabilities:{read:true,send:true},native};
 const result=controlRoomSources({...empty,sourceConnections:[{provider:'codex',connected:true,state:'connected'}]},new Set(),now(),()=>[row]);
 const projected=result.unifiedControl.rows[0];
 assert.equal(projected.stale,true);assert.equal(projected.fresh,false);
 assert.equal(projected.readOnly,true);assert.equal(projected.capabilities.send,false);
 assert.equal(projected.sourceConnection.connected,false);
 assert.equal(projected.runId,'run-new');assert.equal(projected.sourceConnection.runId,'run-old');
});

test('snapshot 자체 hidden:true와 대문자 원본 ID도 소스목록에서 제외한다',()=>{
 const id='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
 const row={source:'codex',key:'codex:'+id,externalId:id,ownerVerified:true,ownerThreadId:id,native:{id},title:'숨긴 원문'};
 const raw={...empty,catalog:[{id,hidden:true}]};
 const result=controlRoomSources(raw,new Set(),now(),()=>[row]);
 assert.deepEqual(result.unifiedControl.rows,[]);
});

test('숨긴 세션 provider 요약에 원담당·run·reason 식별자를 남기지 않는다',()=>{
 const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 const raw={...empty,sourceConnections:[{provider:'codex',connected:true,state:'connected',
  sessionId:id.toUpperCase(),owner:'private-owner',runId:'private-run',reason:'private-detail',
  sourceRevision:12,observedAt:first.generatedAt,connectedAt:first.generatedAt,readOnly:false,capabilities:{read:true,send:true}}]};
 const result=controlRoomSources(raw,new Set([id]),now(),()=>[]);
 const connection=result.sourceConnections[0];
 assert.equal(connection.provider,'codex');assert.equal(connection.state,'unavailable');
 for(const key of ['sessionId','owner','runId','sourceRevision','observedAt','connectedAt'])assert.equal(connection[key],null);
 assert.equal(connection.connected,false);assert.equal(connection.readOnly,true);
 assert.deepEqual(connection.capabilities,{read:false,send:false});
 assert.ok(!JSON.stringify(result).includes('private-'));
});

test('UUID만 case 정규화하며 opaque ID·공개 공유 runtime owner의 case와 권한을 보존한다',()=>{
 const {controlHiddenIds,controlIdentity}=require('./vendor/mobile-control/mobile-control');
 assert.equal(controlIdentity('Opaque-A'),'Opaque-A');
 assert.equal(controlIdentity('AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
 const connection=(sessionId,runId,provider='codex')=>({provider,sessionId,runId,owner:'Shared-Runtime',sourceRevision:7,
  connected:true,state:'connected',capabilities:{read:true,send:false}});
 const secret={id:'Hidden-A',source:'cursor-desktop',hidden:true,
  sourceConnection:connection('Hidden-A','Hidden-Run','cursor-desktop')};
 const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 const visible={id,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,
  activeTurnId:'Visible-Run',sourceConnection:connection(id,'Visible-Run')};
 const variant={id:'hidden-a',source:'cursor-desktop',activeTurnId:'hidden-run',
  sourceConnection:connection('hidden-a','hidden-run','cursor-desktop')};
 const raw={...empty,threads:[secret,visible,variant],catalog:[secret,visible,variant],sourceConnections:[
  secret.sourceConnection,visible.sourceConnection,connection(null,null,'cursor-desktop'),variant.sourceConnection]};
 const rows=[secret,visible,variant].map(native=>({key:native.source+':'+native.id,source:native.source,externalId:native.id,
  ownerThreadId:native.id,ownerVerified:true,fresh:true,capabilities:{read:true,send:false},native}));
 const projected=controlRoomSources(raw,new Set(),now(),()=>rows);
 assert.deepEqual(projected.unifiedControl.rows.map(row=>row.externalId),[id,'hidden-a']);
 assert.equal(projected.sourceConnections[0].owner,null);
 assert.equal(projected.sourceConnections[1].owner,'Shared-Runtime');
 assert.equal(projected.sourceConnections[1].sessionId,id);
 assert.equal(projected.sourceConnections[2].owner,null,'공개 binding 없는 owner 단독 요약은 감춘다');
 assert.equal(projected.sourceConnections[3].owner,'Shared-Runtime','opaque case를 임의 병합하지 않는다');
 assert.equal(projected.unifiedControl.rows[0].sourceConnection.owner,'Shared-Runtime');
 assert.equal(projected.unifiedControl.rows[0].fresh,true);
 assert.equal(projected.unifiedControl.rows[0].capabilities.send,false);
 assert.equal(controlHiddenIds({mobile:{threads:[{id:'mobile-only',hidden:true}]}},new Set()).has('mobile-only'),true);
});

test('정규화 전에 사라진 숨긴 Cloud도 raw items/sessions 관계로 provider 요약을 소거한다',()=>{
 const id='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
 for(const key of ['items','sessions']){
  const raw={...empty,mobile:{threads:[{id,hidden:true}]},
   unifiedControl:{[key]:[{source:'cursor-cloud',externalId:'Cloud-Private',ownerThreadId:id,
    runId:'Cloud-Private-Run',sourceConnection:{provider:'cursor-cloud',owner:'Cloud-Private-Owner',
     sessionId:'Cloud-Private',runId:'Cloud-Private-Run'}}]},sourceConnections:[{provider:'cursor-cloud',
    connected:true,state:'connected',sessionId:'Cloud-Private',runId:'Cloud-Private-Run',
    owner:'Cloud-Private-Owner',reason:'Cloud-Private-Reason',sourceRevision:7}]};
  const original=JSON.stringify(raw);
  const view=controlRoomSources(raw,new Set(),now(),()=>[]);
  assert.deepEqual(view.unifiedControl.rows,[]);
  const source=view.sourceConnections[0];
  for(const field of ['sessionId','runId','owner','reason','sourceRevision'])assert.equal(source[field],null,key+':'+field);
  assert.equal(source.connected,false);assert.equal(source.state,'unavailable');
  assert(!JSON.stringify(view).includes('Cloud-Private'));assert.equal(JSON.stringify(raw),original);
 }
});

test('공개 native row가 숨긴 세션을 가리켜도 root grid·saved·source rows에 비공개 연결이 남지 않는다',()=>{
 const {controlRoomProjection}=require('./control-room-projection');
 const hiddenId='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
 const publicId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
 const sourceConnection={provider:'codex',sessionId:hiddenId.toLowerCase(),runId:'private-run',owner:'private-owner',
  reason:'private-detail',sourceRevision:8,connected:true,state:'connected',capabilities:{read:true,send:true}};
 const hidden={id:hiddenId,hidden:true,available:true,source:'codex',hostId:'local',forkedFromId:null,
  forkLineageVerified:true,slotIndex:1,sourceConnection};
 const visible={id:publicId,available:true,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,
  slotIndex:0,activeTurnId:'public-run',sourceConnection,title:'공개 작업'};
 const raw={...empty,threads:[visible,hidden],catalog:[visible,hidden],sourceConnections:[sourceConnection],
  mobile:{workspaces:[{id:'saved',slots:[{threadId:publicId}]}]}};
 const original=JSON.stringify(raw);
 const view=controlRoomProjection(raw,now());
 const sources=controlRoomSources(raw,new Set(),now(),()=>[{source:'codex',key:'codex:'+publicId,
  externalId:publicId,title:visible.title,native:visible,ownerVerified:true,capabilities:{read:true,send:true}}]);
 for(const row of [view.currentGrid[0].card,view.workspaces[0].slots[0].card,sources.unifiedControl.rows[0]]){
  assert.equal(row.title,'공개 작업');assert.equal(row.stale,true);
  for(const field of ['owner','sessionId','runId','reason','sourceRevision'])assert.equal(row.sourceConnection[field],null);
 }
 assert.equal(sources.unifiedControl.rows[0].capabilities.send,false);
 assert(!JSON.stringify({...view,...sources}).includes('private-'));
 assert.equal(JSON.stringify(raw),original);
});
