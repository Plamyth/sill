'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const crypto = require('node:crypto');
const {EventEmitter} = require('node:events');
const {watchPrivacyPolicy} = require('./vendor/mobile-control/control-privacy-policy');
const {ControlEventsClient} = require('./vendor/control-events/control-events-client');
const {ControlRoomEvents,MAX_JSON_BYTES} = require('./control-room-events');
const {createServer} = require('./server');
const {controlRoomProjection} = require('./control-room-projection');
const {SCHEMA,encode,reduceEvent} = require('./vendor/control-events/control-events');
const fixture = require('./vendor/control-events/control-events-v1.json');

const time = '2026-10-23T00:00:00.000Z';
const now = () => Date.parse(time);
const token = 'isolated-relay-test-token-only';
const voiceId = '33333333-3333-4333-8333-333333333333';
const hiddenId = '44444444-4444-4444-8444-444444444444';

class Inbox extends EventEmitter {
  constructor() { super(); this.items = []; }
  push(value) { this.items.push(value); this.emit('item'); }
  wait(predicate, after = 0) {
    return new Promise((resolve,reject) => {
      const check = () => {
        const value = this.items.slice(after).find(predicate);
        if (value) { clearTimeout(timer); this.off('item',check); resolve(value); }
      };
      const timer = setTimeout(() => {
        this.off('item',check); reject(new Error('격리 이벤트 대기 시간 초과'));
      },3000);
      this.on('item',check);
      check();
    });
  }
}

function upstreamSnapshot() {
  const card = {...fixture.events[0].snapshot.threads[0],id:'11111111-1111-4111-8111-111111111111',
    source:'codex',hostId:'local',
    forkedFromId:null,forkLineageVerified:true,slotIndex:0,available:true,
    capabilities:{read:true,send:false}};
  const voice = {id:voiceId,hostId:'local',forkedFromId:null,forkLineageVerified:true,
    slotIndex:2,available:true,source:'codex',voiceCard:true};
  const hidden = {id:hiddenId,hostId:'local',forkedFromId:null,forkLineageVerified:true,
    slotIndex:5,available:true,source:'codex',title:'숨김 원문'};
  return {...fixture.events[0].snapshot,generatedAt:time,workspace:'all',
    activeVoiceId:voiceId,activeVoiceSession:{threadId:voiceId,sessionId:'fixture-voice',observedAt:time},
    threads:[card,voice,hidden],catalog:[card,voice,hidden],
    projects:[{id:'project-a',label:'프로젝트',projectKind:'codex'}],
    unifiedControl:{privateRaw:'원본 비공개'},
    mobile:{workspaces:[{id:'all',label:'전체',slots:[{threadId:card.id},null,{threadId:voiceId}]}],
      brainTrinity:{schema:'control-room-bt-mobile-feed/v1',available:true,writable:false,
        source:'braintrinity',ownerInstanceId:'bt-ledger:goal_becdf9909850486b:fixture',
        revision:1,epoch:0,observedAt:time,mode:'stopped',reason:null,
        activities:[],reviewRequests:[]}}};
}

async function fakeUDS(t, eventOptions = {}) {
  const root = path.resolve(__dirname,'../../..');
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(root,'.e')));
  fs.chmodSync(dir,0o700);
  const socketPath = path.join(dir,'s');
  assert.ok(Buffer.byteLength(socketPath) < 104,'Mac UDS 주소 길이');
  const subscriptions = new Inbox(), peers = new Set();
  const uds = net.createServer(socket => {
    peers.add(socket);
    let input = '';
    socket.on('error',() => {});
    socket.on('close',() => peers.delete(socket));
    socket.on('data',chunk => {
      input += chunk.toString('utf8');
      const end = input.indexOf('\n');
      if (end < 0) return;
      const request = JSON.parse(input.slice(0,end));
      input = input.slice(end+1);
      assert.equal(request.schema,SCHEMA);
      assert.equal(request.type,'subscribe');
      subscriptions.push({request,socket});
    });
  });
  await new Promise(resolve => uds.listen(socketPath,resolve));
  fs.chmodSync(socketPath,0o600);
  const hiddenPath = path.join(dir,'hidden.json');
  fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids:[hiddenId]}),{mode:0o600});
  let effects = 0;
  const server = createServer({token,hiddenPath,store:path.join(dir,'store'),
    snapshotPath:path.join(dir,'snapshot-must-not-be-read.json'),
    controlEvents:{projectSources:() => ({}),socketPath,now,retryMs:1,maxRetryMs:2,heartbeatMs:60000,...eventOptions},
    deliver:() => { effects++; throw new Error('외부 실행 금지'); },
    deliveryReady:() => { effects++; throw new Error('provider 조회 금지'); }});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const port = server.address().port;
  const streams = new Set();
  t.after(async () => {
    for (const stream of streams) stream.destroy();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => uds.close(resolve));
    fs.rmSync(dir,{recursive:true,force:true});
    assert.equal(effects,0);
  });
  async function connect(headers = {'x-canvas-token':token}) {
    const inbox = new Inbox();
    const response = await new Promise((resolve,reject) => {
      const request = http.get({host:'127.0.0.1',port,path:'/control-room/events',headers},resolve);
      request.on('error',reject);
    });
    streams.add(response);
    response.on('error',() => {});
    response.setEncoding('utf8');
    let pending = '';
    response.on('data',chunk => {
      pending += chunk;
      let end;
      while ((end = pending.indexOf('\n\n')) >= 0) {
        const fields = Object.fromEntries(pending.slice(0,end).split('\n').map(line => {
          const colon = line.indexOf(':'); return [line.slice(0,colon),line.slice(colon+2)];
        }));
        pending = pending.slice(end+2);
        const event = JSON.parse(fields.data);
        assert.equal(fields.id,`${event.generation}:${event.revision}`);
        assert.equal(fields.event,event.type);
        inbox.push(event);
      }
    });
    return {response,inbox};
  }
  return {dir,socketPath,hiddenPath,subscriptions,connect,port,server};
}

test('공통 모듈과 fixture의 고정 SHA가 출처 기록과 일치한다',() => {
  const provenance = require('./vendor/control-events/provenance.json');
  assert.equal(provenance.commit,'a6e3047135e296223b88471344720ba5bfdb829e');
  assert.equal(provenance.tree,'975534c73b332ad13b80f974e12d922d708a0927');
  assert.deepEqual(provenance.files,{
    "bridge/control-events.js": "803f6d4399ff1b9ccdf7bdcff45efe8a678873f0a517d90d41fbbb11fa5d5266",
    "bridge/control-events-client.js": "5774b4264afdd51ead498a78dfe8b5169dd984714a2173128ce9ebf7cdcd8cb9",
    "bridge/control-events-server.js": "b030979f74c8a9a4881c1f1562c2e238a362b7e5978abbc314658e38ab29b149",
    "tests/fixtures/control-events-v1.json": "a026a9f697a88ebe2838e02c24b980774572683e35189962f4900eb059609454",
    "tests/fixtures/control-events-fields-v1.json": "a17cad702852a0c884fc5f0af081924a9c34b22be710ee525ad7c6f60f832a53"
});
  for (const [source,expected] of Object.entries(provenance.files))
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,'..',provenance.locations[source])))
      .digest('hex'),expected);
});

test('인증 뒤 UDS snapshot·patch·중복·단절·재연결·누락·세대 교체를 SSE로 투영한다',async t => {
  const f = await fakeUDS(t);
  for (const headers of [{},{'x-canvas-token':'wrong'}]) {
    const response = await fetch(`http://127.0.0.1:${f.port}/control-room/events`,{headers});
    assert.equal(response.status,401);
    assert.deepEqual(await response.json(),{error:'Unauthorized'});
  }
  assert.equal(f.subscriptions.items.length,0);
  const stream = await f.connect();
  assert.equal(stream.response.headers['content-type'],'text/event-stream; charset=utf-8');
  assert.equal(stream.response.headers['cache-control'],'no-store');
  let event = await stream.inbox.wait(e => e.type === 'snapshot');
  let state = reduceEvent(null,event).state;
  assert.deepEqual(state.snapshot.connection,{connected:false,state:'unavailable'});
  const subscribed = await f.subscriptions.wait(() => true);
  assert.equal(subscribed.request.cursor,null);
  const raw = upstreamSnapshot();
  const first = {...fixture.events[0],snapshot:raw};
  for (const byte of Buffer.from(encode(first))) subscribed.socket.write(Buffer.from([byte]));
  event = await stream.inbox.wait(e => e.type === 'snapshot' && e.revision > 0);
  state = reduceEvent(state,event).state;
  const projected = controlRoomProjection(raw,now(),new Set([hiddenId]));
  assert.deepEqual(state.snapshot,{...projected,threads:[],catalog:[],sourceObservedAt:time,
    connection:{connected:true,state:'connected'}});
  assert.equal(state.snapshot.currentGrid.length,9);
  assert.equal(state.snapshot.currentGrid[5].kind,'hidden');
  assert.equal(state.snapshot.workspaces[0].slots[2].threadId,voiceId);
  assert.equal(state.snapshot.activeVoiceSession.sessionId,'fixture-voice');
  assert.equal(state.snapshot.brainTrinity.available,true);
  assert.equal(state.snapshot.brainTrinity.writable,false);
  assert.ok(!JSON.stringify(state.snapshot).includes('원본 비공개'));
  assert.notEqual(state.generation,first.generation);

  const patch = structuredClone(fixture.events[1]);
  patch.threads.upsert[0] = {...raw.threads[0],...patch.threads.upsert[0],id:raw.threads[0].id};
  subscribed.socket.write(encode(patch));
  event = await stream.inbox.wait(e => e.type === 'patch' && e.revision > state.revision);
  assert.equal(event.baseRevision,state.revision);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.currentGrid[0].card.activeTurnId,'test-turn');
  const checkpoint = structuredClone(state);
  subscribed.socket.write(encode(patch));
  subscribed.socket.write(encode({...fixture.events[2],sourceObservedAt:'2099-01-01',capabilities:{send:true}}));
  const next = {...patch,revision:2,baseRevision:1,threads:{upsert:[],remove:[]},set:{workspace:'next'}};
  subscribed.socket.write(encode(next));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  assert.equal(event.revision,checkpoint.revision+1);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.workspace,'next');
  assert.equal(state.snapshot.sourceObservedAt,checkpoint.snapshot.sourceObservedAt);
  assert.deepEqual(state.snapshot.currentGrid[0].card.capabilities,{read:true,send:false});

  subscribed.socket.destroy();
  event = await stream.inbox.wait(e => e.revision > state.revision);
  const beforeDisconnect = state.snapshot;
  state = reduceEvent(state,event).state;
  assert.deepEqual(state.snapshot,{...beforeDisconnect,connection:{connected:false,state:'stale'}});
  const resumed = await f.subscriptions.wait(() => true,1);
  assert.deepEqual(resumed.request.cursor,{generation:first.generation,revision:2});
  const lastId = `${state.generation}:${state.revision}`;
  const reconnect = await f.connect({'x-canvas-token':token,'last-event-id':lastId});
  const restored = await reconnect.inbox.wait(e => e.type === 'snapshot');
  assert.deepEqual(restored.snapshot,state.snapshot);
  assert.equal(restored.revision,state.revision);
  assert.equal(f.subscriptions.items.length,2,'SSE 구독자는 upstream을 공유한다');

  const resumedRaw = {...raw,workspace:'next',threads:[patch.threads.upsert[0],...raw.threads.slice(1)]};
  resumed.socket.write(encode({...first,revision:2,snapshot:resumedRaw}));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.connection.state,'connected');

  resumed.socket.write(encode({...fixture.gap,revision:4,baseRevision:3}));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.connection.state,'stale');
  const resync = await f.subscriptions.wait(() => true,2);
  assert.equal(resync.request.cursor,null);
  assert.equal(state.snapshot.currentGrid[0].card.activeTurnId,'test-turn');
  resync.socket.write(encode({...first,revision:4,snapshot:resumedRaw}));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.connection.state,'connected');

  resync.socket.write(encode({...fixture.replacement,snapshot:{...raw,workspace:'replacement'}}));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  assert.equal(event.type,'snapshot');
  assert.equal(event.generation,state.generation);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.workspace,'replacement');

  resync.socket.write(encode({...patch,generation:first.generation,revision:5,baseRevision:4}));
  event = await stream.inbox.wait(e => e.revision > state.revision);
  state = reduceEvent(state,event).state;
  assert.equal(state.snapshot.workspace,'replacement');
  assert.equal(state.snapshot.connection.state,'stale');
  const generationResync = await f.subscriptions.wait(() => true,3);
  assert.equal(generationResync.request.cursor,null);
  assert.equal(fs.existsSync(path.join(f.dir,'snapshot-must-not-be-read.json')),false);
});

test('권한이 열린 UDS는 공통 client가 거부하고 unavailable을 유지한다',async t => {
  const f = await fakeUDS(t);
  fs.chmodSync(f.socketPath,0o666);
  const stream = await f.connect();
  const initial = await stream.inbox.wait(() => true);
  assert.equal(initial.snapshot.connection.state,'unavailable');
  const directory = path.dirname(f.socketPath);
  const adapter = new ControlRoomEvents({projectSources:() => ({}),socketPath:f.socketPath,now,readHiddenIds:() => new Set()});
  t.after(() => adapter.close());
  adapter.client.start();
  assert.equal(adapter.client.socket,null);
  assert.equal(f.subscriptions.items.length,0);
  assert.equal(fs.statSync(directory).mode & 0o777,0o700);
});

function response(accept = true) {
  const value = new EventEmitter();
  value.frames = [];
  value.writeHead = () => {};
  value.accept = accept;
  value.write = frame => { value.frames.push(frame); return value.accept; };
  value.destroy = () => { value.destroyed = true; value.emit('close'); };
  return value;
}

test('heartbeat는 관측값을 바꾸지 않고 backpressure는 최신 snapshot 하나로 복구한다',() => {
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => new Set([hiddenId])});
  let starts = 0;
  adapter.client.start = () => { starts++; };
  try {
    const healthy = response();
    adapter.attach(healthy);
    const raw = upstreamSnapshot(), identity = {generation:fixture.events[0].generation,revision:0};
    adapter.apply(raw,identity);
    const before = JSON.stringify(adapter.snapshot), revision = adapter.revision;
    adapter.apply(raw,identity);
    assert.equal(adapter.revision,revision,'같은 snapshot은 중복 발행하지 않는다');
    adapter.heartbeat();
    const heartbeat = JSON.parse(healthy.frames.at(-1).split('\ndata: ')[1]);
    assert.equal(heartbeat.type,'heartbeat');
    assert.equal(heartbeat.revision,revision);
    assert.equal(Object.hasOwn(heartbeat,'sourceObservedAt'),false);
    assert.equal(Object.hasOwn(heartbeat,'capabilities'),false);
    assert.equal(JSON.stringify(adapter.snapshot),before);
    const slow = response(false);
    adapter.attach(slow);
    assert.equal(slow.destroyed,undefined);
    assert.equal(adapter.clients.size,2);
    adapter.apply({...raw,workspace:'intermediate'},identity);
    adapter.apply({...raw,workspace:'latest'},identity);
    adapter.heartbeat();
    assert.equal(slow.frames.length,1,'backpressure 뒤 추가 버퍼를 쌓지 않는다');
    slow.accept = true;
    slow.emit('drain');
    assert.equal(slow.frames.length,2);
    const recovered = JSON.parse(slow.frames.at(-1).split('\ndata: ')[1]);
    assert.equal(recovered.type,'snapshot');
    assert.equal(recovered.snapshot.workspace,'latest');
    assert.equal(recovered.revision,adapter.revision);
    assert.equal(adapter.clients.get(slow).pending,false);
    assert.equal(healthy.destroyed,undefined);
    assert.equal(starts,2);
  } finally { adapter.close(); }
  assert.equal(adapter.clients.size,0);
  assert.equal(adapter.timer,null);
});

test('만료된 snapshot과 숨김 정책 오류는 마지막 화면을 보존하고 stale로 전환한다',() => {
  let hidden = new Set([hiddenId]);
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => {
    if (!hidden) throw new Error('숨김 정책을 읽을 수 없습니다.');
    return hidden;
  }});
  const raw = upstreamSnapshot(), identity = {generation:fixture.events[0].generation,revision:0};
  adapter.apply(raw,identity);
  const last = adapter.snapshot;
  adapter.apply({...raw,generatedAt:'2000-01-01T00:00:00Z'},identity);
  assert.deepEqual(adapter.snapshot,{...last,connection:{connected:false,state:'stale'}});
  adapter.apply(raw,identity);
  hidden = null;
  adapter.apply({...raw,workspace:'must-not-appear'},identity);
  assert.deepEqual(adapter.snapshot,{schemaVersion:1,threads:[],catalog:[],
    sourceObservedAt:last.sourceObservedAt,connection:{connected:false,state:'unavailable'}});
  adapter.close();
});

test('4000개 카드 뒤 Cursor Desktop·Cloud가 큰 snapshot과 patch에서 유지된다',async t => {
  const f = await fakeUDS(t);
  const stream = await f.connect();
  const {socket} = await f.subscriptions.wait(() => true);
  const cards = Array.from({length:4000},(_,index) => ({id:`${index.toString(16).padStart(8,'0')}-0000-4000-8000-000000000000`,
    source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,
    available:true,title:`대화 ${index}`,latestProgress:{text:'관측'.repeat(130)},
    ...(index < 9 ? {slotIndex:index} : {})}));
  cards.push({id:'cursor-desktop-tail',source:'cursor-desktop',available:true,
    title:'Cursor Desktop 마지막 카드',capabilities:{read:true,send:false}},
  {id:'cursor-cloud-tail',source:'cursor-cloud',available:true,
    title:'Cursor Cloud 마지막 카드',capabilities:{read:true,send:false}});
  const workspaces = Array.from({length:Math.ceil(cards.length/9)},(_,index) => ({
    id:`workspace-${index}`,label:`작업공간 ${index}`,
    slots:cards.slice(index*9,index*9+9).map(card => ({kind:'normal',threadId:card.id}))}));
  const raw = {schemaVersion:1,generatedAt:time,threads:cards,catalog:cards,
    mobile:{workspaces},unifiedControl:{secret:'private-large-raw'},sourceConnections:[{private:true}]};
  socket.write(encode({...fixture.events[0],snapshot:raw}));
  let event = await stream.inbox.wait(e => e.type === 'snapshot' && e.revision > 0);
  const snapshotBytes = Buffer.byteLength(JSON.stringify(event));
  assert.ok(snapshotBytes > 3.43*1024*1024);
  assert.ok(snapshotBytes <= MAX_JSON_BYTES);
  let state = reduceEvent(null,event).state;
  const visible = snapshot => snapshot.workspaces.flatMap(workspace => workspace.slots)
    .filter(slot => slot.card).map(slot => slot.card);
  assert.equal(visible(state.snapshot).length,4002);
  assert.deepEqual(visible(state.snapshot).slice(-2).map(card => card.source),['cursor-desktop','cursor-cloud']);
  assert.ok(!JSON.stringify(event).includes('private-large-raw'));
  assert.equal(Object.hasOwn(state.snapshot,'sourceConnections'),false);
  const changed = cards.slice(-2).map(card => ({...card,status:'새 원본 상태',capabilities:{read:true,send:false}}));
  socket.write(encode({...fixture.events[1],threads:{upsert:changed,remove:[]}}));
  event = await stream.inbox.wait(e => e.type === 'patch' && e.revision > state.revision);
  const patchBytes = Buffer.byteLength(JSON.stringify(event));
  assert.ok(patchBytes > 3.43*1024*1024);
  assert.ok(patchBytes <= MAX_JSON_BYTES);
  state = reduceEvent(state,event).state;
  assert.equal(visible(state.snapshot).length,4002);
  assert.deepEqual(visible(state.snapshot).slice(-2).map(card => card.status),['새 원본 상태','새 원본 상태']);
  assert.deepEqual(visible(state.snapshot).slice(-2).map(card => card.capabilities.send),[false,false]);
  t.diagnostic(`4002개 카드의 SSE JSON snapshot ${snapshotBytes} bytes, patch ${patchBytes} bytes`);
});

test('JSON 한도 초과는 행을 자르지 않고 마지막 정상 투영을 stale로 보존한다',() => {
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => new Set()});
  const raw = upstreamSnapshot(), identity = {generation:fixture.events[0].generation,revision:0};
  adapter.apply(raw,identity);
  const last = adapter.snapshot;
  const huge = {...raw,threads:raw.threads.map((card,index) => index === 0 ?
    {...card,title:'x'.repeat(MAX_JSON_BYTES)} : card)};
  adapter.apply(huge,identity);
  assert.deepEqual(adapter.snapshot,{...last,connection:{connected:false,state:'stale'}});
  adapter.close();
});

test('backpressure 제한 시간이 지나면 해당 소비자만 닫는다',t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => new Set()});
  adapter.client.start = () => {};
  try {
    const healthy = response(), slow = response(false);
    adapter.attach(healthy);
    adapter.attach(slow);
    t.mock.timers.tick(30000);
    assert.equal(slow.destroyed,true);
    assert.equal(healthy.destroyed,undefined);
    assert.equal(adapter.clients.size,1);
  } finally { adapter.close(); }
});

test('8 MiB에서 8192bytes를 남긴 JSON 경계와 전체 SSE 크기를 지킨다',() => {
  assert.equal(MAX_JSON_BYTES,8380416);
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => new Set()});
  adapter.client.start = () => {};
  try {
    const consumer = response();
    adapter.attach(consumer);
    const snapshot = {schemaVersion:1,threads:[],catalog:[],sourceObservedAt:time,
      connection:{connected:true,state:'connected'},note:''};
    const overhead = Buffer.byteLength(JSON.stringify(adapter.event('snapshot',{
      revision:adapter.revision+1,snapshot})));
    snapshot.note = 'x'.repeat(MAX_JSON_BYTES-overhead);
    adapter.publish(snapshot,true);
    const wire = consumer.frames.at(-1);
    const json = wire.split('\ndata: ')[1].trimEnd();
    assert.equal(Buffer.byteLength(json),8380416);
    assert.ok(Buffer.byteLength(wire) <= 8388608);
    const revision = adapter.revision;
    assert.throws(() => adapter.publish({...snapshot,note:snapshot.note+'x'},true),/8 MiB/);
    assert.equal(adapter.revision,revision);
    assert.equal(adapter.snapshot,snapshot);
    assert.equal(consumer.frames.length,2);
  } finally { adapter.close(); }
});


test('재구독과 backpressure 복구는 최신 숨김 정책을 적용하고 관측시각을 보존한다',() => {
  let hidden = new Set();
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => {
    if (hidden === null) throw new Error('정책 조회 실패');
    return hidden;
  }});
  adapter.client.start = () => {};
  try {
    const raw = upstreamSnapshot(), identity = {generation:fixture.events[0].generation,revision:0};
    adapter.apply(raw,identity);
    const observed = adapter.snapshot.sourceObservedAt;
    const first = response(); adapter.attach(first); first.destroy();
    hidden = new Set([voiceId]);
    const next = response();adapter.attach(next);
    const state = JSON.parse(next.frames[0].split('\ndata: ')[1]).snapshot;
    assert.equal(state.activeVoiceId,null);
    assert.equal(state.activeVoiceSession,null);
    assert.equal(state.voiceCard,null);
    assert.equal(state.currentGrid[2].card,null);
    assert.equal(state.workspaces[0].slots[2].card,null);
    assert.equal(state.generatedAt,raw.generatedAt);
    assert.equal(state.sourceObservedAt,observed);
    const slow = response(false); adapter.attach(slow);
    adapter.apply({...raw,workspace:'queued'},identity);
    hidden = new Set([raw.threads[0].id,voiceId]);
    slow.accept = true;slow.emit('drain');
    const drained = JSON.parse(slow.frames.at(-1).split('\ndata: ')[1]).snapshot;
    assert.equal(drained.currentGrid[0].card,null);
    assert.equal(drained.sourceObservedAt,observed);
    hidden = null;
    const denied = response();adapter.attach(denied);
    const blocked = JSON.parse(denied.frames[0].split('\ndata: ')[1]).snapshot;
    assert.equal(blocked.currentGrid,undefined);
    assert.equal(blocked.voiceCard,undefined);
    assert.equal(blocked.connection.state,'unavailable');
    assert.equal(blocked.sourceObservedAt,observed);
  } finally {adapter.close();}
});

test('활성 SSE가 있어도 closeAllConnections 없이 server.close가 완료된다',async t => {
  const f = await fakeUDS(t);
  const stream = await f.connect();
  await stream.inbox.wait(event => event.type === 'snapshot');
  let timer;
  try {
    await Promise.race([
      new Promise((resolve,reject) => f.server.close(error => error ? reject(error) : resolve())),
      new Promise((_,reject) => {timer = setTimeout(() => reject(Error('SSE 종료 대기 시간 초과')),500);})
    ]);
  } finally {clearTimeout(timer);}
});

test('숨김 해제로 캐시가 한도를 넘으면 drain 예외 없이 내용을 차단한다',() => {
  const raw = upstreamSnapshot();
  raw.threads[0].title = 'x'.repeat(MAX_JSON_BYTES);
  let hidden = new Set([raw.threads[0].id]);
  const adapter = new ControlRoomEvents({projectSources:() => ({}),now,readHiddenIds:() => hidden});
  adapter.client.start = () => {};
  try {
    const identity = {generation:fixture.events[0].generation,revision:0};
    adapter.apply(raw,identity);
    const observed = adapter.snapshot.sourceObservedAt;
    const slow = response(false);adapter.attach(slow);
    adapter.apply({...raw,workspace:'queued'},identity);
    hidden = new Set();slow.accept = true;
    assert.doesNotThrow(() => slow.emit('drain'));
    const state = JSON.parse(slow.frames.at(-1).split('\ndata: ')[1]).snapshot;
    assert.equal(state.connection.state,'unavailable');
    assert.equal(state.currentGrid,undefined);
    assert.equal(state.sourceObservedAt,observed);
    assert.equal(adapter.clients.get(slow).blocked,false);
    assert.equal(adapter.clients.get(slow).pending,false);
  } finally {adapter.close();}
});

const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
test('첫 snapshot은 감시 등록 중 바뀐 정책을 반영하며 초기 patch를 보내지 않는다',() => {
  let hidden = new Set();
  const adapter = new ControlRoomEvents({now,projectSources:() => ({}),readHiddenIds:() => hidden,
    subscribePolicy:() => { hidden = new Set([voiceId,hiddenId]); return () => {}; }});
  adapter.client.start = () => {};
  try {
    adapter.apply(upstreamSnapshot(),{generation:fixture.events[0].generation,revision:0});
    const consumer = response();adapter.attach(consumer);
    const events = consumer.frames.map(value => JSON.parse(value.split('\ndata: ')[1]));
    assert.equal(events.length,1);
    assert.equal(events[0].type,'snapshot');
    assert.equal(events[0].snapshot.currentGrid[2].card,null);
    assert.equal(adapter.snapshot.currentGrid[2].card,null);
    adapter.heartbeat();
    assert.equal(consumer.frames.length,2);
  } finally { adapter.close(); }
});
for (const boundary of ['response-close','relay-close']) test(`첫 snapshot 전송 중 ${boundary} 뒤에는 client를 시작하지 않는다`,() => {
  let starts = 0;
  const adapter = new ControlRoomEvents({now,projectSources:() => ({}),readHiddenIds:() => new Set()});
  adapter.client.start = () => { starts++; };
  const consumer = response();
  const write = consumer.write;
  consumer.write = data => {
    const result = write.call(consumer,data);
    if (boundary === 'relay-close') adapter.close();
    else consumer.destroy();
    return result;
  };
  try {
    adapter.attach(consumer);
    assert.equal(starts,0);
    assert.equal(adapter.clients.size,0);
    assert.equal(adapter.timer,null);
    assert.equal(adapter.policySubscription,null);
  } finally { adapter.close(); }
});
async function until(predicate) {
  const end = Date.now()+3000;
  while (!predicate()) {
    if (Date.now() > end) throw Error('격리 상태 확인 시간 초과');
    await delay(10);
  }
}
function replacePolicy(file, ids) {
  fs.writeFileSync(file+'.next',JSON.stringify({version:1,ids}),{mode:0o600});
  fs.renameSync(file+'.next',file);
}

test('quiet loopback SSE는 atomic 정책 변경만 재투영하고 마지막 소비자·서버 종료에서 감시를 해제한다',async t => {
  let f,subscriptions=0,unsubscriptions=0,invalidations=0,clock=now();
  const clocks=[];
  f=await fakeUDS(t,{now:()=>clock,projectSources:(raw,ids,at)=>{clocks.push(at);return {};},
    subscribePolicy:callbacks=>{
      subscriptions++;
      const unsubscribe=watchPrivacyPolicy({file:f.hiddenPath,...callbacks,
        onInvalidate(){invalidations++;callbacks.onInvalidate();}});
      return ()=>{unsubscriptions++;unsubscribe();};
    }});
  assert.equal(subscriptions,0);
  const stream=await f.connect(),second=await f.connect();
  const {socket}=await f.subscriptions.wait(()=>true);
  const raw=upstreamSnapshot(),original=JSON.stringify(raw);
  socket.write(encode({...fixture.events[0],snapshot:raw}));
  const first=await stream.inbox.wait(e=>e.type==='snapshot'&&e.revision>0);
  await second.inbox.wait(e=>e.type==='snapshot'&&e.revision>0);
  let state=reduceEvent(null,first).state;
  assert.equal(subscriptions,1);
  const check=()=>{
    assert.equal(state.generation,first.generation);
    assert.notEqual(state.generation,fixture.events[0].generation);
    assert.equal(state.snapshot.generatedAt,raw.generatedAt);
    assert.equal(state.snapshot.sourceObservedAt,raw.generatedAt);
    assert.deepEqual(state.snapshot.connection,{connected:true,state:'connected'});
    assert.equal(JSON.stringify(raw),original);
    assert(clocks.every(at=>at===now()),'정책 변경은 최초 평가시각을 재사용한다');
    assert.equal(f.subscriptions.items.length,1,'quiet 원본 구독은 바뀌지 않는다');
  };
  clock+=600000;
  replacePolicy(f.hiddenPath,[voiceId,hiddenId]);
  let event=await stream.inbox.wait(e=>e.revision>state.revision);
  assert.equal(event.type,'patch');assert.equal(event.baseRevision,state.revision);
  state=reduceEvent(state,event).state;check();
  assert.equal(state.snapshot.currentGrid[2].card,null);
  assert.equal(state.snapshot.activeVoiceSession,null);
  assert.equal(state.snapshot.voiceCard,null);
  const checkpoint=stream.inbox.items.length;
  const before=invalidations;
  replacePolicy(f.hiddenPath,[voiceId,hiddenId]);
  await until(()=>invalidations>before);await delay(60);
  assert.equal(stream.inbox.items.length,checkpoint,'동일 투영은 중복 발행하지 않는다');
  fs.writeFileSync(path.join(f.dir,'unrelated.json'),'{}');await delay(60);
  assert.equal(stream.inbox.items.length,checkpoint);
  replacePolicy(f.hiddenPath,[hiddenId]);
  event=await stream.inbox.wait(e=>e.revision>state.revision);
  state=reduceEvent(state,event).state;check();
  assert.equal(state.snapshot.activeVoiceSession.sessionId,'fixture-voice');
  assert.equal(state.snapshot.currentGrid[0].card.capabilities.send,false);
  stream.response.destroy();await delay(30);assert.equal(unsubscriptions,0);
  second.response.destroy();await until(()=>unsubscriptions===1);
  await until(()=>socket.destroyed);
  const renewed=await f.connect();
  await renewed.inbox.wait(e=>e.type==='snapshot');
  const resumed=await f.subscriptions.wait(()=>true,1);
  assert.deepEqual(resumed.request.cursor,{generation:fixture.events[0].generation,revision:0});
  assert.equal(subscriptions,2);
  await new Promise(resolve=>f.server.close(resolve));
  await until(()=>unsubscriptions===2);
});

for (const failure of ['malformed','delete','watcherror']) test(`quiet SSE의 ${failure}는 내용을 제거하고 단절 뒤에도 unavailable이다`,async t=>{
  let f,watcher,unsubscriptions=0;
  f=await fakeUDS(t,{subscribePolicy:callbacks=>{
    const unsubscribe=watchPrivacyPolicy({file:f.hiddenPath,...callbacks,
      watch:(dir,callback)=>(watcher=fs.watch(dir,callback))});
    return ()=>{unsubscriptions++;unsubscribe();};
  }});
  const stream=await f.connect(),{socket}=await f.subscriptions.wait(()=>true);
  socket.write(encode({...fixture.events[0],snapshot:upstreamSnapshot()}));
  const first=await stream.inbox.wait(e=>e.type==='snapshot'&&e.revision>0);
  if(failure==='malformed')fs.writeFileSync(f.hiddenPath,'{');
  else if(failure==='delete')fs.unlinkSync(f.hiddenPath);
  else watcher.emit('error',Error('합성 감시 오류'));
  const cleared=await stream.inbox.wait(e=>e.revision>first.revision);
  let state=reduceEvent(reduceEvent(null,first).state,cleared).state;
  assert.deepEqual(state.snapshot,{schemaVersion:1,threads:[],catalog:[],sourceObservedAt:time,
    connection:{connected:false,state:'unavailable'}});
  if(failure==='malformed'){
    socket.destroy();
    await until(()=>f.subscriptions.items.length>1);
    assert.equal(stream.inbox.items.at(-1).revision,cleared.revision,'단절은 불완전 stale을 발행하지 않는다');
    stream.response.destroy();
  }
  await until(()=>unsubscriptions===1);
  replacePolicy(f.hiddenPath,[voiceId,hiddenId]);
  const renewed=await f.connect();
  const initial=await renewed.inbox.wait(e=>e.type==='snapshot');
  assert.equal(initial.snapshot.currentGrid[2].card,null);
  assert.equal(initial.snapshot.connection.connected,false,'정책 복구가 원본 연결을 승격하지 않는다');
  assert.equal(initial.snapshot.sourceObservedAt,time);
  const resumed=await f.subscriptions.wait(()=>true,failure==='malformed'?2:1);
  resumed.socket.write(encode({...fixture.events[0],snapshot:upstreamSnapshot()}));
  const recovered=await renewed.inbox.wait(e=>e.revision>initial.revision);
  state=reduceEvent(reduceEvent(null,initial).state,recovered).state;
  assert.equal(state.snapshot.connection.state,'connected');
  assert.equal(state.snapshot.currentGrid[2].card,null);
  assert.equal(state.generation,first.generation);
});

test('정책 차단 뒤 마지막 SSE close와 추가 disconnect도 unavailable과 빈 내용을 유지한다',()=>{
  let hidden=new Set();
  const adapter=new ControlRoomEvents({now,projectSources:()=>({}),readHiddenIds:()=>{
    if(hidden===null)throw Error('정책 읽기 실패');return hidden;
  }});
  adapter.client.start=()=>{};
  const consumer=response();adapter.attach(consumer);
  adapter.apply(upstreamSnapshot(),{generation:fixture.events[0].generation,revision:0});
  hidden=null;adapter.refreshPolicy();
  const snapshot=structuredClone(adapter.snapshot),revision=adapter.revision;
  consumer.destroy();adapter.disconnect();
  assert.deepEqual(adapter.snapshot,snapshot);assert.equal(adapter.revision,revision);
  assert.equal(adapter.snapshot.generatedAt,undefined);assert.equal(adapter.snapshot.currentGrid,undefined);
  adapter.close();
});

for(const boundary of ['error','throw','relay-close','response-close']) test(`동기 ${boundary} 구독 콜백 뒤 client.start가 진행되지 않는다`,()=>{
  let adapter,consumer,starts=0,unsubscribes=0;
  adapter=new ControlRoomEvents({now,readHiddenIds:()=>new Set(),subscribePolicy:({onError})=>{
    if(boundary==='error')onError(Error('동기 감시 실패'));
    if(boundary==='throw')throw Error('동기 구독 실패');
    if(boundary==='relay-close')adapter.close();
    if(boundary==='response-close')consumer.destroy();
    return ()=>{unsubscribes++;};
  }});
  adapter.client.start=()=>{starts++;};consumer=response();
  adapter.attach(consumer);
  assert.equal(starts,0);assert.equal(adapter.timer,null);assert.equal(adapter.policySubscription,null);
  assert.equal(unsubscribes,boundary==='throw'?0:1);
  assert.equal(adapter.snapshot.connection.state,'unavailable');adapter.close();
});

test('원본 전 정책 변경과 파일 부재는 빈 unavailable이며 UDS를 시작하지 않는다',async t=>{
  const f=await fakeUDS(t);
  fs.unlinkSync(f.hiddenPath);
  const stream=await f.connect();
  const initial=await stream.inbox.wait(e=>e.type==='snapshot');
  assert.equal(initial.snapshot.sourceObservedAt,null);
  assert.equal(initial.snapshot.currentGrid,undefined);
  await delay(60);assert.equal(f.subscriptions.items.length,0);
  replacePolicy(f.hiddenPath,[hiddenId]);
  const next=await f.connect();await next.inbox.wait(e=>e.type==='snapshot');
  await f.subscriptions.wait(()=>true);
});

test('공통 watcher는 정확한 basename과 Buffer/null·atomic rename·오류·해제를 처리한다',()=>{
  let callback,invalidations=0,errors=0,closes=0,available=true;
  const watcher=new EventEmitter();watcher.close=()=>{closes++;watcher.emit('close');};
  const unsubscribe=watchPrivacyPolicy({file:'/synthetic/hidden.json',
    watch:(directory,cb)=>{assert.equal(directory,'/synthetic');callback=cb;return watcher;},
    stat:file=>{assert.equal(file,'/synthetic/hidden.json');if(!available)throw Error('없음');return {isFile:()=>true};},
    onInvalidate:()=>{invalidations++;},onError:()=>{errors++;}});
  callback('rename','other-hidden.json');callback('change',Buffer.from('hidden.json'));callback('rename',null);
  callback('rename','hidden.json');assert.equal(invalidations,3);
  available=false;callback('rename','hidden.json');
  assert.equal(errors,1);assert.equal(closes,1);
  callback('change',null);watcher.emit('error',Error('종료 후 오류'));unsubscribe();unsubscribe();
  assert.equal(errors,1);assert.equal(closes,1);assert.equal(invalidations,3);
});

test('공통 client의 초기 idle/absolute deadline과 기본 5초/20초 값을 그대로 사용한다',async t=>{
  const defaults=new ControlEventsClient();
  assert.equal(defaults.initialTimeoutMs,5000);assert.equal(defaults.initialMaxMs,20000);
  const f=await fakeUDS(t);
  const client=new ControlEventsClient({socketPath:f.socketPath,retryMs:1,maxRetryMs:2,initialTimeoutMs:60,initialMaxMs:180,
    onSnapshot:()=>assert.fail('미완성 초기 프레임은 수용하지 않는다')});
  t.after(()=>client.close());client.start();
  const idle=await f.subscriptions.wait(()=>true);
  await until(()=>idle.socket.destroyed);
  const absolute=await f.subscriptions.wait(()=>true,1);
  const pulse=setInterval(()=>absolute.socket.write(' '),15);
  try{await until(()=>absolute.socket.destroyed);}finally{clearInterval(pulse);client.close();}
  assert.equal(client.state,null);
});
