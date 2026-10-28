'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {EventEmitter} = require('node:events');
const {ControlRoomEvents} = require('./control-room-events');
const {controlRoomSources} = require('./control-room-sources');
const {reduceEvent} = require('./vendor/control-events/control-events');
const pin = require('./vendor/mobile-control/provenance.json');
const fixture = require('./test-input/public-relay-lineage-v1.json');

const normalize = raw => raw.catalog.map(native => ({key:'codex:'+native.id,source:'codex',
  externalId:native.id,sessionId:native.id,title:native.title,native,
  capabilities:{read:true,send:false}})).concat(raw.unifiedControl?.items || []);
const normal = fixture.cases[0];
const now = () => Date.parse(normal.raw.generatedAt);
const identity = {generation:'12345678-1234-4234-8234-123456789abc',revision:0};
const projectSources = (raw,hidden,clock) => controlRoomSources(raw,hidden,clock,normalize);
const exported = [];

function checkNativeContract(snapshot) {
  assert.equal(snapshot.schemaVersion,1);
  assert.equal(typeof snapshot.generatedAt,'string');
  assert.equal(snapshot.currentGrid.length,9);
  const event = value => assert.equal(typeof value.id,'string');
  const card = value => {
    if (!value) return;
    assert.equal(typeof value.id,'string');
    for (const item of value.events || []) event(item);
    if (value.latestProgress) event(value.latestProgress);
    if (value.latestUser) event(value.latestUser);
  };
  const slot = value => {
    assert.ok(Number.isInteger(value.index));
    assert.equal(typeof value.kind,'string');
    card(value.card);
  };
  snapshot.currentGrid.forEach(slot);
  for (const layout of snapshot.workspaces) {
    assert.equal(typeof layout.id,'string');
    assert.equal(layout.label,'합성 전체');
    assert.ok(Array.isArray(layout.slots));
    layout.slots.forEach(slot);
  }
  for (const item of [...snapshot.projects,...snapshot.sections]) {
    assert.equal(typeof item.id,'string');
    assert.equal(typeof item.label,'string');
  }
  card(snapshot.voiceCard);
}

function checkPublic(snapshot, input) {
  checkNativeContract(snapshot);
  assert.deepEqual(snapshot.unifiedControl.rows.map(row => row.key),input.expectedKeys,input.name);
  assert.equal(snapshot.unifiedControl.error,null);
  assert.deepEqual(snapshot.threads,[]);
  assert.deepEqual(snapshot.catalog,[]);
  assert.equal(snapshot.connection.state,'connected');
  const cloud = snapshot.unifiedControl.rows.find(row => row.source === 'cursor-cloud');
  if (input.name === normal.name) {
    assert.equal(cloud.result,'SYNTHETIC_DERIVED_BODY');
    assert.deepEqual(cloud.capabilities,{read:true,send:false});
    assert.equal(snapshot.sourceConnections[1].owner,'fixture-cloud-runtime');
  } else {
    assert.equal(cloud,undefined);
    assert.equal(JSON.stringify(snapshot).includes('SYNTHETIC_DERIVED_BODY'),false);
    for (const field of ['sessionId','runId','owner','reason','sourceRevision','observedAt','connectedAt'])
      assert.equal(snapshot.sourceConnections[1][field],null,input.name+':'+field);
    assert.deepEqual(snapshot.sourceConnections[1].capabilities,{read:false,send:false});
    assert.equal(snapshot.sourceConnections[1].connected,false);
    const child = normal.raw.catalog[1].id;
    assert.ok(!snapshot.workspaces.flatMap(layout => layout.slots).some(slot => slot.card?.id === child));
    const slot = snapshot.workspaces[0].slots[1];
    assert.equal(slot.index,1);
    assert.equal(slot.card,null);
    if (input.name === 'missing-current-child') {
      assert.equal(slot.threadId,child);
      assert.equal(slot.unavailableReason,'missing-catalog-member');
    } else {
      assert.equal(slot.kind,'hidden');
      assert.equal(slot.threadId,null);
      assert.equal(slot.unavailableReason,'hidden');
    }
  }
  for (const row of snapshot.unifiedControl.rows) {
    assert.equal(row.capabilities.send,false);
    assert.equal(Object.hasOwn(row,'native'),false);
  }
}

for (const input of fixture.cases) test('공개 relay SSE 계보와 복구 '+input.name,() => {
  assert.equal(fixture.producerCommit,pin.commit);
  assert.equal(fixture.producerTree,pin.tree);
  assert.equal(fixture.sourceFixtureSHA256,'25acf135b9d8cdfa390bb0f1b9d46eca85fc7c8c681201ebb0d7f1de0eb3cc80');
  const before = JSON.stringify(fixture);
  let hidden = new Set(),state = null,starts = 0,consumed = 0;
  const frames = [],checkpoints = [];
  const stream = new EventEmitter();
  stream.writeHead = (status,headers) => {
    assert.equal(status,200);
    assert.equal(headers['content-type'],'text/event-stream; charset=utf-8');
  };
  stream.write = wire => { frames.push(wire);return true; };
  stream.destroy = () => {
    if (!stream.destroyed) {stream.destroyed = true;stream.emit('close');}
  };
  const adapter = new ControlRoomEvents({now,readHiddenIds:() => hidden,projectSources});
  adapter.client.start = () => {starts++;};
  function checkpoint(phase,expected) {
    const firstIndex = consumed;
    for (const wire of frames.slice(consumed)) {
      const match = /^id: (.+)\nevent: (snapshot|patch|heartbeat)\ndata: (.+)\n\n$/.exec(wire);
      assert.ok(match);
      const event = JSON.parse(match[3]);
      assert.equal(match[1],event.generation+':'+event.revision);
      assert.equal(match[2],event.type);
      assert.equal(Object.hasOwn(event,'changes'),false);
      const next = reduceEvent(state,event);
      assert.equal(next.status,'applied');
      state = next.state;
      consumed++;
    }
    assert.ok(consumed > firstIndex,'각 checkpoint는 실제로 새 프레임을 소비한다');
    assert.deepEqual(state.snapshot,JSON.parse(JSON.stringify(adapter.snapshot)));
    checkPublic(state.snapshot,expected);
    assert.equal(state.snapshot.sourceObservedAt,normal.raw.generatedAt);
    assert.equal(state.generation,adapter.generation);
    checkpoints.push({eventIndex:consumed-1,phase,snapshot:structuredClone(state.snapshot)});
  }
  try {
    adapter.attach(stream);
    assert.equal(JSON.parse(frames[0].split('\ndata: ')[1]).snapshot.connection.state,'unavailable');
    adapter.apply(normal.raw,identity);
    checkpoint('normal',normal);
    if (input.name !== normal.name) {
      hidden = new Set(input.hiddenIds);
      if (input.name === 'hidden-ancestor') adapter.refreshPolicy();
      else adapter.apply(input.raw,{...identity,revision:1});
      assert.equal(JSON.parse(frames.at(-1).split('\ndata: ')[1]).type,'patch');
      checkpoint('protected',input);
      hidden = new Set();
      if (input.name === 'hidden-ancestor') adapter.refreshPolicy();
      else adapter.apply(normal.raw,{...identity,revision:2});
      checkpoint('restored',normal);
    }
    assert.equal(starts,1);
    assert.equal(adapter.client.socket,null);
    assert.equal(adapter.client.timer,null);
    assert.equal(JSON.stringify(fixture),before,'입력 계보를 추정하거나 고치지 않는다');
    exported.push({name:input.name,frames:[...frames],checkpoints});
  } finally {
    adapter.close();
    assert.equal(adapter.clients.size,0);
    assert.equal(adapter.timer,null);
    assert.equal(adapter.policySubscription,null);
    assert.equal(adapter.sourceSnapshot,null);
    assert.equal(adapter.client.socket,null);
    assert.equal(adapter.client.timer,null);
    assert.equal(stream.destroyed,true);
  }
});

test('Cloud result는 read true와 UTF-8 12000 bytes 이내에서만 공개한다',() => {
  for (const [result,read,expected] of [
    ['한'.repeat(4000),true,'한'.repeat(4000)],
    ['a'.repeat(12000),true,'a'.repeat(12000)],
    ['한'.repeat(4000)+'a',true,null],['a'.repeat(12001),true,null],
    ['합성 결과',false,null],['합성 결과',undefined,null],['합성 결과','true',null],
    [null,true,null],[7,true,null],[{},true,null],['',true,'']]) {
    const raw = structuredClone(normal.raw);
    Object.assign(raw.unifiedControl.items[0],{result,capabilities:{read,send:false}});
    const before = JSON.stringify(raw);
    const view = projectSources(raw,new Set(),now());
    assert.equal(view.unifiedControl.rows.find(row => row.source === 'cursor-cloud').result,expected);
    assert.equal(JSON.stringify(raw),before);
  }
});

test('알 수 없는 계보와 누락된 root를 정상 fixture로 추정하지 않는다',() => {
  for (const field of ['forkedFromId','forkLineageVerified']) {
    const raw = structuredClone(normal.raw);
    for (const entries of [raw.catalog,raw.threads,raw.mobile.threads]) delete entries[0][field];
    const before = JSON.stringify(raw);
    const view = projectSources(raw,new Set(),now());
    assert.deepEqual(view.unifiedControl.rows.map(row => row.key),['codex:'+raw.catalog[2].id]);
    assert.equal(view.sourceConnections[1].owner,null);
    assert.equal(JSON.stringify(view).includes('SYNTHETIC_DERIVED_BODY'),false);
    assert.equal(JSON.stringify(raw),before);
  }
});

test.after(() => {
  const output = process.env.CCR_PUBLIC_RELAY_FIXTURES;
  if (!output) return;
  assert.equal(exported.length,6);
  const result = {schema:'ccr.ipad-public-relay-fixture/v1',producerCommit:pin.commit,
    producerTree:pin.tree,sourceFixtureSHA256:fixture.sourceFixtureSHA256,
    relayInputSupplements:fixture.relayInputSupplements,
    normalizer:'explicit-synthetic-catalog-and-items',installedReaderAccepted:false,
    clientStart:'stubbed-before-attach',cleanup:{clients:0,heartbeatTimers:0,policySubscriptions:0,
      upstreamSockets:0,upstreamRetryTimers:0},cases:exported};
  fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n');
});
