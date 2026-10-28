'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const {EventEmitter,once} = require('node:events');
const {setTimeout:delay} = require('node:timers/promises');
const {ControlRoomEvents} = require('./control-room-events');
const {controlRoomProjection} = require('./control-room-projection');
const {controlRoomSources} = require('./control-room-sources');
const {SCHEMA,encode,createDecoder,reduceEvent} = require('./vendor/control-events/control-events');
const pin = require('./vendor/control-events/provenance.json');
const fields = require('./vendor/control-events/control-events-fields-v1.json');
const mobile = require('./vendor/mobile-control/mobile-control-events-v1.json');
const time = '2026-10-23T00:00:00.000Z';
const now = () => Date.parse(time);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

async function until(predicate) {
  const deadline = Date.now()+4000;
  while (!predicate()) {
    if (Date.now()>deadline) throw Error('자체 UDS 경계 검사 대기 시간 초과');
    await delay(5);
  }
}

function normalized(snapshot) {
  return snapshot.syntheticRows;
}
const projectSources = (snapshot,hidden,clock) => controlRoomSources(snapshot,hidden,clock,normalized);

function sourceSnapshot() {
  const rows = structuredClone(mobile.events[0].snapshot.unifiedControl.rows).map(row => ({...row,
    ...(row.source === 'codex' ? {native:{id:row.externalId,source:'codex',hostId:'local',
      forkedFromId:null,forkLineageVerified:true,activeTurnId:row.activeTurnId,
      sourceConnection:row.sourceConnection}} : {})}));
  const card = {id:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',source:'codex',hostId:'local',
    forkedFromId:null,forkLineageVerified:true,slotIndex:0,
    available:true,title:'원본 제목',status:'대기',observedAt:time,
    capabilities:{read:true,send:false},artifacts:[{name:'보존할 산출물'}]};
  const opaque = {id:'Opaque-A',source:'cursor-desktop',slotIndex:1,available:true,title:'opaque 원문'};
  const hidden = {id:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',source:'codex',slotIndex:2,
    available:true,hidden:true,title:'숨긴 비공개 원문'};
  return {schemaVersion:1,generatedAt:time,workspace:'all',threads:[card,opaque,hidden],
    catalog:[card,opaque,hidden],syntheticRows:rows,
    sourceConnections:structuredClone(mobile.events[0].snapshot.sourceConnections),
    projects:[],mobile:{workspaces:[{id:'all',label:'전체',slots:[{threadId:card.id},{threadId:opaque.id},{threadId:hidden.id}]}],
      threads:[],marker:'투영에 포함하지 않는 원본 값'},privateRaw:'비공개 최상위 원문'};
}

function expected(snapshot,hidden = new Set()) {
  const projection = controlRoomProjection(snapshot,now(),hidden);
  return {...projection,...projectSources(snapshot,hidden,now()),threads:[],catalog:[],
    sourceObservedAt:projection.generatedAt,connection:{connected:true,state:'connected'}};
}

function response() {
  const stream = new EventEmitter();
  stream.frames = [];
  stream.writeHead = () => {};
  stream.write = raw => { stream.frames.push(raw); return true; };
  stream.destroy = () => { if (!stream.destroyed) { stream.destroyed = true; stream.emit('close'); } };
  return stream;
}

function exportSession(output,name,stream,states,steps,normalizer = {mode:'explicit-synthetic-rows',installedModuleRead:false,bindings:null}) {
  if (!output) return;
  fs.mkdirSync(output,{recursive:true});
  const raw = stream.frames.join('');
  const documents = states.map(state => state.snapshot);
  const files = {[name+'.sse.txt']:raw,[name+'.expected.json']:JSON.stringify({documents,states},null,2)+'\n'};
  for (const [file,content] of Object.entries(files)) fs.writeFileSync(path.join(output,file),content);
  fs.writeFileSync(path.join(output,name+'.metadata.json'),JSON.stringify({schema:'ipad-relay-sse-boundary/v1',
    session:name,frameCount:stream.frames.length,steps,upstream:pin,
    normalizer,
    nativeValidation:{owner:'parent',requiredProductionHead:'4b3147cea39fabb616fb40f3ff56003a4abdde3f',
      requiredProductionTree:'89487f4f571560480047386d7b0a9c99f0901283',executedHere:false},
    files:Object.fromEntries(Object.entries(files).map(([file,content]) => [file,{sha256:sha(content),bytes:Buffer.byteLength(content)}]))},null,2)+'\n');
}

test('필드 fixture의 full snapshot 복원은 정확한 공통 codec을 사용한다',() => {
  let state = null;
  for (const event of fields.events) state = reduceEvent(state,event).state;
  assert.deepEqual(state.snapshot,fields.expectedSnapshot);
  assert.equal(sha(fs.readFileSync(path.join(__dirname,'vendor/control-events/control-events-fields-v1.json'))),
    'a17cad702852a0c884fc5f0af081924a9c34b22be710ee525ad7c6f60f832a53');
});

test('실제 공통 server와 client의 필드 차분·replay·gap·세대 복구를 iPad SSE 원문으로 보존한다',async t => {
  const directory = fs.realpathSync(fs.mkdtempSync(path.resolve(__dirname,'../../..','.if-')));
  fs.chmodSync(directory,0o700);
  const socketPath = path.join(directory,'s');
  const output = process.env.CCR_INCREMENTAL_OUTPUT;
  const codec = fs.readFileSync(path.join(__dirname,'vendor/control-events/control-events.js'));
  const serverCode = fs.readFileSync(path.join(__dirname,'test-input/control-events-server.js'));
  assert.equal(sha(serverCode),pin.files['bridge/control-events-server.js']);
  fs.writeFileSync(path.join(directory,'control-events.js'),codec);
  fs.writeFileSync(path.join(directory,'control-events-server.js'),serverCode);
  const {ControlEventsServer} = require(path.join(directory,'control-events-server.js'));
  let server = new ControlEventsServer({socketPath,clock:() => time});
  const servers = [server],rawClients = [],wire = [],requests = [],deliveries = [],sessions = [];
  let adapter,hidden = new Set();
  const cleanup = async () => {
    adapter?.close();
    for (const socket of rawClients) socket.destroy();
    for (const item of servers) await item.close();
    const absent = !fs.existsSync(socketPath);
    assert.equal(absent,true);
    for (const name of ['control-events.js','control-events-server.js']) delete require.cache[path.join(directory,name)];
    fs.rmSync(directory,{recursive:true,force:true});
    assert.equal(fs.existsSync(directory),false);
    if (output) fs.writeFileSync(path.join(output,'cleanup.json'),JSON.stringify({socketPath,directory,
      socketAbsent:absent,inputDirectoryAbsent:!fs.existsSync(directory),serverCount:servers.length,
      serverClosed:servers.every(item => item.closed && !item.server.listening),
      clientClosed:adapter?.client.closed,clientSocketNull:adapter?.client.socket === null,
      clientTimerNull:adapter?.client.timer === null,relayTimerNull:adapter?.timer === null,
      policyReleased:adapter?.policySubscription === null,
      actualServiceAccess:0,actualCCRSocketAccess:0,deviceAccess:0,audioAccess:0,keyAccess:0,
      externalEffects:0},null,2)+'\n');
  };
  t.after(cleanup);
  const instrument = item => {
    const accept = item.accept.bind(item);
    item.accept = socket => {
      let input = '';
      const receive = chunk => {
        input += chunk.toString('utf8');
        if (!input.includes('\n')) return;
        socket.off('data',receive);
        requests.push({server:item.generation,request:JSON.parse(input.split('\n')[0])});
      };
      socket.on('data',receive);accept(socket);
    };
    const send = item.send.bind(item);
    item.send = (socket,raw) => { wire.push({server:item.generation,advertised:item.fieldClients.has(socket),raw});send(socket,raw); };
  };
  instrument(server);
  await server.start();
  let raw = sourceSnapshot();
  server.publish(raw);
  async function subscribe(capabilities,cursor = null) {
    const previous = new Set(server.clients);
    const socket = net.connect(socketPath),events = [];
    rawClients.push(socket);
    socket.on('error',() => {});
    socket.on('data',createDecoder(event => events.push(event)));
    await once(socket,'connect');
    socket.write(JSON.stringify({schema:SCHEMA,type:'subscribe',cursor,
      ...(capabilities ? {capabilities} : {})})+'\n');
    await until(() => events.length>0);
    return {socket,events,peer:[...server.clients].find(item => !previous.has(item))};
  }
  const legacy = await subscribe(null);
  const advertised = await subscribe(['incremental-fields-v1']);
  adapter = new ControlRoomEvents({socketPath,now,retryMs:30,maxRetryMs:30,heartbeatMs:60000,
    readHiddenIds:() => hidden,projectSources});
  const receive = adapter.client.onSnapshot;
  adapter.client.onSnapshot = (snapshot,identity) => {
    deliveries.push({snapshot:structuredClone(snapshot),identity:{...identity}});
    receive(snapshot,identity);
  };
  let stream,states,steps,state,consumed;
  function open(name) {
    stream = response();states = [];steps = [];state = null;consumed = 0;
    sessions.push({name,stream,states,steps});adapter.attach(stream);
  }
  function record(label,document = adapter.snapshot) {
    const before = consumed;
    for (const frame of stream.frames.slice(consumed)) {
      const match = /^id: (.+)\nevent: (snapshot|patch|heartbeat)\ndata: (.+)\n\n$/.exec(frame);
      assert.ok(match,'실제 frame 출력의 id/event/data 형식');
      const event = JSON.parse(match[3]);
      assert.equal(match[1],event.generation+':'+event.revision);
      assert.equal(match[2],event.type);
      assert.equal(Object.hasOwn(event,'changes'),false,'모바일 SSE root에 raw changes가 없어야 한다');
      const reduced = reduceEvent(state,event);
      assert.notEqual(reduced.status,'resync');
      state = reduced.state;
      states.push(structuredClone(state));consumed++;
    }
    assert.deepEqual(state.snapshot,document,label);
    steps.push({label,firstFrame:before,frameCount:consumed-before,
      upstream:deliveries.at(-1)?.identity ?? null,relay:{generation:state.generation,revision:state.revision}});
  }
  async function publish(next,label,quiet = false) {
    const count = deliveries.length,frames = stream.frames.length;
    server.publish(next);
    await until(() => deliveries.length>count);
    await until(() => legacy.events.at(-1)?.revision === server.revision && advertised.events.at(-1)?.revision === server.revision);
    raw = next;
    assert.deepEqual(deliveries.at(-1).snapshot,raw,'공통 client는 fields를 full snapshot으로 복원한다');
    record(label,expected(raw,hidden));
    if (quiet) assert.equal(stream.frames.length,frames,'투영이 같은 원본 변경은 추가 SSE가 없다');
    let left = null,right = null;
    for (const event of legacy.events) left = reduceEvent(left,event).state;
    for (const event of advertised.events) right = reduceEvent(right,event).state;
    assert.deepEqual(left.snapshot,right.snapshot);
    assert.deepEqual(left.snapshot,raw);
    assert.ok(legacy.events.every(event => !Object.hasOwn(event,'changes')));
    assert.ok(advertised.events.filter(event => event.type === 'patch').every(event => Object.hasOwn(event,'changes')));
  }
  open('01-fields');
  await until(() => deliveries.length === 1);
  record('초기 연결',expected(raw));
  assert.equal(fs.statSync(directory).mode&0o777,0o700);
  assert.equal(fs.statSync(socketPath).mode&0o777,0o600);
  assert.notEqual(adapter.generation,server.generation);
  assert.equal(adapter.revision,1);assert.equal(server.revision,0);
  const stable = structuredClone(expected(raw));
  const next = structuredClone(raw);next.threads[0].status='진행 중';next.catalog[0].status='진행 중';
  await publish(next,'필드 상태 변경');
  const changed = expected(raw);
  for (const key of ['unifiedControl','sourceConnections','sourceObservedAt','generatedAt']) assert.deepEqual(changed[key],stable[key]);
  for (const row of changed.unifiedControl.rows) {
    const before = stable.unifiedControl.rows.find(item => item.key === row.key);
    for (const key of ['source','provider','sourceRevision','ownerThreadId','ownerVerified','observedAt','capabilities'])
      assert.deepEqual(row[key],before[key]);
  }
  assert.equal(changed.currentGrid[0].threadId,'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA');
  assert.equal(changed.currentGrid[1].threadId,'Opaque-A');
  assert.equal(changed.currentGrid[2].kind,'hidden');
  assert.ok(!JSON.stringify(changed).includes('비공개'));
  const quiet = structuredClone(raw);quiet.mobile.marker='원본만 변경';
  await publish(quiet,'투영 동일 변경',true);
  const count = stream.frames.length;adapter.heartbeat();record('heartbeat');
  assert.equal(stream.frames.length,count+1);
  assert.equal(state.snapshot.sourceObservedAt,time);
  hidden = new Set(['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']);
  adapter.refreshPolicy();record('UUID 숨김 정책',expected(raw,hidden));
  assert.equal(state.snapshot.currentGrid[0].kind,'hidden');
  hidden = new Set();adapter.refreshPolicy();record('정책 복구',expected(raw));
  const wireBeforeReplay = wire.length;
  stream.destroy();
  open('02-replay');record('SSE 재연결의 stale 초기 상태');
  const offline = structuredClone(raw);offline.threads[0].status='오프라인 변경';offline.catalog[0].status='오프라인 변경';
  server.publish(offline);raw = offline;
  const beforeReplay = deliveries.length;
  await until(() => deliveries.length>beforeReplay);
  record('상류 cursor replay 복원',expected(raw));
  assert.equal(deliveries.at(-1).identity.revision,server.revision);
  assert.deepEqual(requests.at(-1).request.cursor,{generation:server.generation,revision:2});
  assert.deepEqual(requests.at(-1).request.capabilities,['incremental-fields-v1']);
  assert.ok(wire.slice(wireBeforeReplay).every(item => JSON.parse(item.raw).type === 'patch'),
    '재연결은 full snapshot 대체가 아니라 보존된 patch replay여야 한다');
  const legacyReplay = await subscribe(null,{generation:server.generation,revision:0});
  const fieldReplay = await subscribe(['incremental-fields-v1'],{generation:server.generation,revision:0});
  await until(() => legacyReplay.events.at(-1)?.revision === server.revision && fieldReplay.events.at(-1)?.revision === server.revision);
  let legacyState = legacy.events[0],fieldState = advertised.events[0];
  legacyState = reduceEvent(null,legacyState).state;fieldState = reduceEvent(null,fieldState).state;
  for (const event of legacyReplay.events) { assert.equal(Object.hasOwn(event,'changes'),false);legacyState=reduceEvent(legacyState,event).state; }
  for (const event of fieldReplay.events) { assert.equal(Object.hasOwn(event,'changes'),true);fieldState=reduceEvent(fieldState,event).state; }
  assert.deepEqual(legacyState.snapshot,raw);assert.deepEqual(fieldState.snapshot,raw);
  const adapterPeer = [...server.clients].find(socket => ![legacy.peer,advertised.peer,legacyReplay.peer,fieldReplay.peer].includes(socket));
  assert.ok(adapterPeer);
  const duplicateDeliveries = deliveries.length,duplicateFrames = stream.frames.length;
  server.send(adapterPeer,server.history.at(-1).fieldEncoded);
  await delay(20);
  assert.equal(deliveries.length,duplicateDeliveries,'중복 patch는 full snapshot 콜백을 반복하지 않는다');
  assert.equal(stream.frames.length,duplicateFrames,'중복 patch는 SSE를 반복하지 않는다');
  record('중복 replay 무시',expected(raw));
  const fieldsWire = wire.filter(item => item.advertised).map(item => JSON.parse(item.raw));
  assert.ok(fieldsWire.some(event => event.type === 'patch' && Object.hasOwn(event,'changes')));
  const reconnectSnapshotCount = fieldsWire.filter(event => event.type === 'snapshot').length;
  const gap = {...fields.events[1],generation:server.generation,
    baseRevision:server.revision+1,revision:server.revision+2};
  server.send(adapterPeer,encode(gap));
  await until(() => adapter.snapshot.connection.state === 'stale');
  record('gap에서 stale 보존');
  const beforeGap = deliveries.length;
  await until(() => deliveries.length>beforeGap);
  record('gap의 snapshot 재수신',expected(raw));
  assert.equal(requests.at(-1).request.cursor,null,'gap 다음 구독은 snapshot을 요구한다');
  assert.ok(wire.filter(item => item.advertised && JSON.parse(item.raw).type === 'snapshot').length>reconnectSnapshotCount);
  assert.equal(deliveries.at(-1).identity.revision,server.revision);
  const previousGeneration = server.generation;
  await server.close();
  await until(() => adapter.snapshot.connection.state === 'stale');record('상류 종료');
  const relayRevisionBeforeGeneration=adapter.revision;
  server = new ControlEventsServer({socketPath,clock:() => time});servers.push(server);instrument(server);
  await server.start();
  const replacement = structuredClone(raw);replacement.workspace='replacement';server.publish(replacement);raw=replacement;
  const beforeGeneration = deliveries.length;
  await until(() => deliveries.length>beforeGeneration);
  record('새 generation snapshot 복구',expected(raw));
  assert.notEqual(server.generation,previousGeneration);
  assert.equal(state.generation,adapter.generation);
  assert.notEqual(state.generation,server.generation);
  assert.equal(deliveries.at(-1).identity.revision,0);
  assert.equal(state.revision,relayRevisionBeforeGeneration+1);
  assert.equal(adapter.client.state.generation,server.generation);
  for (const session of sessions) exportSession(output,session.name,session.stream,session.states,session.steps);
  if (output) {
    fs.writeFileSync(path.join(output,'upstream-wire.json'),JSON.stringify(wire,null,2)+'\n');
    fs.writeFileSync(path.join(output,'subscriptions.json'),JSON.stringify(requests,null,2)+'\n');
    fs.writeFileSync(path.join(output,'full-deliveries.json'),JSON.stringify(deliveries,null,2)+'\n');
    fs.writeFileSync(path.join(output,'manifest.json'),JSON.stringify({schema:'ipad-relay-sse-export/v1',
      sessions:sessions.map(({name,stream}) => ({id:name,rawText:name+'.sse.txt',expectedJSON:name+'.expected.json',
        metadataJSON:name+'.metadata.json',frameCount:stream.frames.length})),
      coreCommit:pin.commit,coreTree:pin.tree,mobileControlCommit:require('./vendor/mobile-control/provenance.json').commit,
      productionSwiftValidation:'부모 확정 HEAD에서 수행할 후속 경계',actualServiceAccess:0},null,2)+'\n');
  }
});

test('정확한 core 정규화와 null bindings를 사용하는 실제 iPad source DTO 경계를 보존한다',async t => {
  const directory = fs.realpathSync(fs.mkdtempSync(path.resolve(__dirname,'../../..','.in-')));
  fs.chmodSync(directory,0o700);
  const socketPath = path.join(directory,'s'),output = process.env.CCR_INCREMENTAL_OUTPUT;
  const coreRoot = path.join(__dirname,'test-input/core-a6');
  const normalizerPin = require('./test-input/core-a6/provenance.json');
  for (const [file,hash] of Object.entries(normalizerPin.files))
    assert.equal(sha(fs.readFileSync(path.join(coreRoot,file))),hash);
  for (const name of ['control-events.js','control-events-server.js']) fs.copyFileSync(
    path.join(__dirname,name.endsWith('server.js') ? 'test-input' : 'vendor/control-events',name),path.join(directory,name));
  const {ControlEventsServer} = require(path.join(directory,'control-events-server.js'));
  const upstream = new ControlEventsServer({socketPath,clock:() => time});
  const originalHelper = process.env.CCR_BRIDGE_HELPER;
  process.env.CCR_BRIDGE_HELPER = path.join(coreRoot,'plugin/bridge.js');
  const normalizer = require(path.join(coreRoot,'plugin/unified-control.js'));
  const originalRows = normalizer.rows;
  let calls = 0,hidden = new Set(),adapter;
  normalizer.rows = (raw,bindings,clock,concealed) => {
    calls++;assert.equal(bindings,null);assert.equal(clock,now());
    return originalRows(raw,bindings,clock,concealed);
  };
  t.after(async () => {
    adapter?.close();await upstream.close();normalizer.rows=originalRows;
    if (originalHelper === undefined) delete process.env.CCR_BRIDGE_HELPER;
    else process.env.CCR_BRIDGE_HELPER=originalHelper;
    for (const name of ['control-events.js','control-events-server.js']) delete require.cache[path.join(directory,name)];
    const socketAbsent = !fs.existsSync(socketPath);fs.rmSync(directory,{recursive:true,force:true});
    assert.equal(socketAbsent,true);assert.equal(fs.existsSync(directory),false);
    if (output) fs.writeFileSync(path.join(output,'03-source-dto.cleanup.json'),JSON.stringify({socketPath,directory,
      socketAbsent,inputDirectoryAbsent:!fs.existsSync(directory),serverClosed:!upstream.server.listening,
      clientClosed:adapter.client.closed,clientSocketNull:adapter.client.socket === null,
      clientTimerNull:adapter.client.timer === null,relayTimerNull:adapter.timer === null,
      normalizerCalls:calls,bindings:null,installedModuleRead:false,secretReads:0,actualServiceAccess:0},null,2)+'\n');
  });
  await upstream.start();
  let raw = structuredClone(require('./test-input/control-room-source-dto.json'));
  upstream.publish(raw);
  adapter = new ControlRoomEvents({socketPath,now,retryMs:30,maxRetryMs:30,heartbeatMs:60000,
    readHiddenIds:() => hidden});
  const stream = response(),states = [],steps = [],deliveries = [];
  let state = null,consumed = 0;
  const receive = adapter.client.onSnapshot;
  adapter.client.onSnapshot = (value,identity) => {
    deliveries.push({snapshot:structuredClone(value),identity});receive(value,identity);
  };
  adapter.attach(stream);
  function record(label) {
    for (const rawFrame of stream.frames.slice(consumed)) {
      const match = /^id: (.+)\nevent: (snapshot|patch|heartbeat)\ndata: (.+)\n\n$/.exec(rawFrame);
      assert.ok(match);const event=JSON.parse(match[3]);
      assert.equal(match[1],event.generation+':'+event.revision);assert.equal(match[2],event.type);
      assert.equal(Object.hasOwn(event,'changes'),false);
      const result = reduceEvent(state,event);assert.notEqual(result.status,'resync');state=result.state;
      states.push(structuredClone(state));consumed++;
    }
    const projection = controlRoomProjection(raw,now(),hidden);
    const sources = controlRoomSources(raw,hidden,now());
    assert.equal(sources.unifiedControl.error,null);
    assert.deepEqual(state.snapshot,{...projection,...sources,threads:[],catalog:[],sourceObservedAt:time,
      connection:{connected:true,state:'connected'}});
    assert.notEqual(state.generation,upstream.generation);
    assert.equal(state.revision,adapter.revision);
    steps.push({label,frameIndex:consumed-1,upstream:deliveries.at(-1).identity,
      relay:{generation:state.generation,revision:state.revision}});
  }
  await until(() => deliveries.length === 1);record('실제 raw DTO의 최초 정규화');
  assert.equal(state.revision,1);assert.equal(upstream.revision,0);
  const baseline = structuredClone(state.snapshot);
  const rows = baseline.unifiedControl.rows;
  assert.deepEqual(rows.map(row => row.source).sort(),['codex','cursor-cloud','cursor-cloud','cursor-desktop']);
  const local = rows.find(row => row.source === 'codex');
  assert.equal(local.ownerThreadId,raw.catalog[0].id);assert.equal(local.ownerVerified,true);
  assert.equal(local.sourceConnection.owner,'DTO-Runtime-A');
  assert.equal(local.sourceConnection.sourceRevision,11);assert.equal(local.observedAt,time);
  assert.deepEqual(local.capabilities,{read:true,send:true});
  const cloud = rows.find(row => row.externalId === 'Opaque-Cloud-A');
  assert.equal(cloud.ownerThreadId,raw.unifiedControl.items[0].ownerThreadId);assert.equal(cloud.ownerVerified,true);
  assert.equal(cloud.sourceRevision,'dto-revision-7');assert.equal(cloud.observedAt,time);
  assert.equal(cloud.title,'공개 Cloud 원본');assert.equal(cloud.executionStatus,'FINISHED');
  assert.deepEqual(cloud.capabilities,{read:true,send:false},'null bindings는 원본의 send 요청을 권한으로 승격하지 않는다');
  assert.equal(Object.hasOwn(cloud,'native'),false);
  assert.ok(rows.some(row => row.externalId === 'opaque-cloud-a' && row.ownerVerified === false));
  assert.ok(!JSON.stringify(baseline).includes('비공개'));assert.ok(!JSON.stringify(baseline).includes('DTO 값'));
  const next = structuredClone(raw);next.catalog[0].status='진행 중';next.threads[0].status='진행 중';
  const initialSourceRevision=upstream.revision,initialProjectionRevision=adapter.revision;
  const count=deliveries.length;upstream.publish(next);raw=next;
  await until(() => deliveries.length>count);record('실제 정규화 경로의 상태 차분');
  assert.equal(upstream.revision,initialSourceRevision+1);assert.equal(adapter.revision,initialProjectionRevision+1);
  for (const row of state.snapshot.unifiedControl.rows) {
    const before=rows.find(item => item.key === row.key);
    for (const key of ['source','provider','sourceRevision','observedAt','ownerThreadId','ownerVerified','capabilities','externalId'])
      assert.deepEqual(row[key],before[key]);
  }
  assert.deepEqual(state.snapshot.sourceConnections,baseline.sourceConnections);
  const unchangedFrames=stream.frames.length,unchangedDeliveries=deliveries.length;
  const quiet=structuredClone(raw);quiet.mobile.marker='비투영 변경';upstream.publish(quiet);raw=quiet;
  await until(() => deliveries.length>unchangedDeliveries);record('정규화 경로의 동일 투영');
  assert.equal(stream.frames.length,unchangedFrames);
  const projectionRevision=adapter.revision,sourceRevision=upstream.revision;
  hidden=new Set(['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']);adapter.refreshPolicy();record('정규화 뒤 UUID 숨김');
  assert.ok(!state.snapshot.unifiedControl.rows.some(row => row.externalId === local.externalId || row.externalId === cloud.externalId));
  assert.equal(state.snapshot.currentGrid[0].kind,'hidden');
  assert.equal(upstream.revision,sourceRevision);assert.equal(adapter.revision,projectionRevision+1);
  assert.ok(state.snapshot.unifiedControl.rows.some(row => row.externalId === 'opaque-cloud-a'));
  const hiddenSource=state.snapshot.sourceConnections.find(row => row.provider === 'codex');
  assert.equal(hiddenSource.owner,null);assert.deepEqual(hiddenSource.capabilities,{read:false,send:false});
  if (output) {
    exportSession(output,'03-source-dto',stream,states,steps,{mode:'exact-core-rows',bindings:null,
      installedModuleRead:false,pin:normalizerPin,calls});
    fs.writeFileSync(path.join(output,'03-source-dto.full-deliveries.json'),JSON.stringify(deliveries,null,2)+'\n');
    const manifestPath=path.join(output,'manifest.json');
    const manifest=JSON.parse(fs.readFileSync(manifestPath));
    manifest.sessions.push({id:'03-source-dto',rawText:'03-source-dto.sse.txt',expectedJSON:'03-source-dto.expected.json',
      metadataJSON:'03-source-dto.metadata.json',frameCount:stream.frames.length,normalizer:'exact-core-rows'});
    fs.writeFileSync(manifestPath,JSON.stringify(manifest,null,2)+'\n');
  }
});
