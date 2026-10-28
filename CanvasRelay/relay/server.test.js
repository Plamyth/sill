'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const {createServer} = require('./server');
const {deliverPacket,deliverQueuedPacket} = require('./codex-delivery');

const threadId = '11111111-1111-4111-8111-111111111111';
const sessionId = 'realtime-session-1';
const sceneId = '22222222-2222-4222-8222-222222222222';
const queuedId = '55555555-5555-4555-8555-555555555555';
const activeTurnId = '66666666-6666-4666-8666-666666666666';
const token = 'test-secret-with-at-least-24-characters';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function alternatePNG() {
  const data = Buffer.concat([Buffer.from('IDAT'),zlib.deflateSync(Buffer.from([0,255,0,0]))]);
  let crc = -1;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
  length.writeUInt32BE(data.length-4);
  checksum.writeUInt32BE((crc ^ -1) >>> 0);
  return Buffer.concat([png.subarray(0,33),length,data,checksum,png.subarray(-12)]);
}

const scene = {schemaVersion:1,id:sceneId,revision:1,width:2048,height:1536,
  drawingBase64:'',nodes:[],links:[],strokes:[],annotations:[]};
function input(overrides = {}) {
  const bytes = Buffer.from(JSON.stringify(scene));
  return {packetId:crypto.randomUUID(),threadId,sessionId,imageSha256:sha(png),sceneSha256:sha(bytes),
    imagePNGBase64:png.toString('base64'),sceneJSONBase64:bytes.toString('base64'),...overrides};
}
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise,resolve};
}
async function fixture(t, mode = 'legacy-queue', deliveryReady = () => false) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-relay-'));
  const snapshotPath = path.join(dir,'snapshot.json'), hiddenPath = path.join(dir,'hidden-threads.json');
  fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids:[]}),{mode:0o600});
  const store = path.join(dir,'store');
  const hooks = {}, calls = [];
  const selected = mode.startsWith('selected-');
  const inbox = mode.startsWith('inbox-');
  const steering = mode === 'steer' || mode === 'selected-active' || mode === 'inbox-active';
  const snapshot = (overrides = {}) => {
    const now = new Date().toISOString();
    fs.writeFileSync(snapshotPath,JSON.stringify({generatedAt:now,activeVoiceId:threadId,
      activeVoiceSession:{threadId,sessionId,observedAt:now},
      ...(selected ? {activeVoiceId:null,activeVoiceSession:null,
        threads:[{id:threadId,slotIndex:2,available:true,source:'codex'}],
        catalog:[{id:threadId,available:true,source:'codex',hostId:'local',
          forkedFromId:null,forkLineageVerified:true}]} : {}),...overrides}),{mode:0o600});
  };
  snapshot();
  const rpc = async (method,params) => {
    calls.push({method,params});
    if (method === 'thread/read') {
      if (hooks.read) return hooks.read(params);
      if (steering) return {thread:{id:threadId,status:{type:'active',activeFlags:[]},canAcceptDirectInput:true}};
      if (mode === 'inbox-unloaded') return {thread:{id:threadId,status:{type:'notLoaded'},canAcceptDirectInput:null}};
      if (selected || inbox) return {thread:{id:threadId,status:{type:'idle'},canAcceptDirectInput:true}};
      return {thread:{id:threadId,status:{type:'notLoaded'}}};
    }
    if (steering && method === 'thread/turns/list')
      return hooks.turns ? hooks.turns(params) : {data:[{id:activeTurnId,status:'inProgress'}]};
    if (steering && method === 'turn/steer') {
      const saved = JSON.parse(fs.readFileSync(path.join(store,params.clientUserMessageId,'receipt.json')));
      assert.equal(saved.state,'dispatching');
      assert.equal(saved.deliveryScope,'active-turn-steer');
      if (selected || inbox) assert.equal(saved.targetMode,selected ? 'selected-chat' : 'inbox');
      return hooks.steer ? hooks.steer(params) : {turnId:activeTurnId};
    }
    if ((selected || inbox) && method === 'turn/start') {
      const saved = JSON.parse(fs.readFileSync(path.join(store,params.clientUserMessageId,'receipt.json')));
      assert.equal(saved.state,'dispatching');
      assert.equal(saved.deliveryScope,'exact-chat-start');
      assert.equal(saved.targetMode,selected ? 'selected-chat' : 'inbox');
      return hooks.start ? hooks.start(params) : {turn:{id:activeTurnId,status:'inProgress'}};
    }
    if (method === 'thread/queue/add') {
      const saved = JSON.parse(fs.readFileSync(path.join(store,params.clientUserMessageId,'receipt.json')));
      assert.equal(saved.state,'dispatching');
      if (inbox) assert.equal(saved.sessionId,`inbox:${threadId}`);
      else assert.equal(saved.sessionId,JSON.parse(fs.readFileSync(snapshotPath)).activeVoiceSession.sessionId);
      if (hooks.add) return hooks.add(params);
      return {queuedSubmission:{id:queuedId,clientUserMessageId:params.clientUserMessageId}};
    }
    if (method === 'thread/queue/list') {
      if (hooks.list) return hooks.list(params);
      return {data:[{id:queuedId,clientUserMessageId:calls.filter(c => c.method === 'thread/queue/add').at(-1).params.clientUserMessageId}]};
    }
    throw new Error('Unexpected RPC');
  };
  let server;
  let root;
  async function stop() {
    if (!server) return;
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
  async function start() {
    server = createServer({snapshotPath,hiddenPath,store,token,
      inboxThreadId:inbox ? threadId : '',
      deliveryReady,
      deliveryScope:mode === 'legacy-queue' ? 'exact-chat-queue-only' : 'active-turn-steer',
      deliver:(packet,before) => (mode === 'legacy-queue' ? deliverQueuedPacket : deliverPacket)(packet,rpc,before)});
    await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
    root = `http://127.0.0.1:${server.address().port}`;
  }
  const call = (route,method='GET',body,signal) => fetch(root+route,{method,signal,
    headers:{'x-canvas-token':token,'content-type':'application/json'},
    body:body === undefined ? undefined : JSON.stringify(body)});
  const receipt = async id => (await call(`/packets/${id}/receipt`)).json();
  await start();
  t.after(async () => { await stop(); fs.rmSync(dir,{recursive:true,force:true}); });
  const hide = ids => fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids}),{mode:0o600});
  return {snapshot,store,snapshotPath,hiddenPath,hide,hooks,calls,call,receipt,stop,start,
    addCount:() => calls.filter(c => c.method === 'thread/queue/add').length};
}

test('delivery readiness tells the iPad when no shared desktop socket exists without reserving a packet', async t => {
  const unavailable = await fixture(t);
  assert.deepEqual(await (await unavailable.call(`/delivery/ready?threadId=${threadId}&targetMode=voice`)).json(),
    {available:false});
  assert.equal(fs.readdirSync(unavailable.store).filter(name => /^[0-9a-f-]{36}$/.test(name)).length,0);
  const available = await fixture(t,'legacy-queue',(id,mode) => id === threadId && mode === 'voice');
  assert.deepEqual(await (await available.call(`/delivery/ready?threadId=${threadId}&targetMode=voice`)).json(),
    {available:true});
  assert.deepEqual(await (await available.call('/delivery/ready')).json(),{available:false});
  assert.deepEqual(await (await available.call(`/delivery/ready?threadId=${sceneId}&targetMode=voice`)).json(),
    {available:false});
});

test('active delivery records the exact steered turn without queueing', async t => {
  const f = await fixture(t,'steer'), packet = input();
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'steered');
  assert.equal(receipt.deliveryScope,'active-turn-steer');
  assert.equal(receipt.turnId,activeTurnId);
  assert.equal(receipt.queuedId,null);
  assert.equal(receipt.clientUserMessageId,packet.packetId);
  assert.equal(f.addCount(),0);
  assert.deepEqual(f.calls.map(call=>call.method),['thread/read','thread/turns/list','turn/steer']);
  assert.equal(f.calls[2].params.expectedTurnId,activeTurnId);
  assert.deepEqual(await f.receipt(packet.packetId),receipt);
});

function selectedInput(overrides = {}) {
  return input({targetMode:'selected-chat',sessionId:`manual:${threadId}`,...overrides});
}

function inboxInput(overrides = {}) {
  return input({targetMode:'inbox',sessionId:`inbox:${threadId}`,...overrides});
}

for (const [mode,method,state,scope] of [
  ['inbox-active','turn/steer','steered','active-turn-steer'],
  ['inbox-idle','turn/start','started','exact-chat-start']
]) {
  test(`${mode} receives without a voice session or visible grid card`, async t => {
    const f = await fixture(t,mode), packet = inboxInput();
    f.snapshot({activeVoiceId:null,activeVoiceSession:null,threads:[],catalog:[]});
    const target = await (await f.call('/inbox/target')).json();
    assert.deepEqual(target,{threadId,sessionId:`inbox:${threadId}`,targetMode:'inbox',title:'고정 그림 수신함'});
    const receipt = await (await f.call('/packets','POST',packet)).json();
    assert.equal(receipt.state,state);
    assert.equal(receipt.deliveryScope,scope);
    assert.equal(receipt.sessionContinuity.status,'fixed-inbox-bound');
    assert.equal(receipt.sessionContinuity.before,null);
    assert.equal(receipt.sessionContinuity.after,null);
    assert.equal(receipt.turnId,activeTurnId);
    assert.equal(receipt.queuedId,null);
    assert.equal(f.calls.at(-1).method,method);
    assert.equal(f.calls.at(-1).params.threadId,threadId);
    assert.match(f.calls.at(-1).params.input[0].text,/고정 수신함/);
    assert.deepEqual(await (await f.call('/packets','POST',packet)).json(),receipt);
    assert.equal(f.calls.filter(call => call.method === method).length,1);
  });
}

test('inbox rejects a forged target or session before persistence and dispatch', async t => {
  const f = await fixture(t,'inbox-idle');
  for (const packet of [inboxInput({threadId:sceneId}),
    inboxInput({sessionId:`inbox:${sceneId}`}),inboxInput({targetMode:'selected-chat'})]) {
    const response = await f.call('/packets','POST',packet);
    assert.equal(response.status,409);
  }
  assert.equal(f.calls.length,0);
  assert.equal(fs.readdirSync(f.store).filter(name => /^[0-9a-f-]{36}$/.test(name)).length,0);
  assert.deepEqual(await (await f.call(`/delivery/ready?threadId=${sceneId}&targetMode=inbox`)).json(),{available:false});
});

test('unloaded fixed inbox reports queued and deduplicates a repeated packet', async t => {
  const f=await fixture(t,'inbox-unloaded',() => true),packet=inboxInput();
  f.snapshot({activeVoiceId:null,activeVoiceSession:null,threads:[],catalog:[]});
  assert.deepEqual(await (await f.call(`/delivery/ready?threadId=${threadId}&targetMode=inbox`)).json(),{available:true});
  const receipt=await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'queued');
  assert.equal(receipt.deliveryScope,'exact-chat-queue-only');
  assert.equal(receipt.queuedId,queuedId);
  assert.equal(receipt.turnId,null);
  assert.equal(receipt.sessionContinuity.status,'fixed-inbox-bound');
  assert.equal(f.addCount(),1);
  assert.deepEqual(await (await f.call('/packets','POST',packet)).json(),receipt);
  assert.equal(f.addCount(),1);
});

test('unloaded inbox keeps an ambiguous queue result unknown without a second dispatch', async t => {
  const f=await fixture(t,'inbox-unloaded',() => true),packet=inboxInput();
  f.snapshot({activeVoiceId:null,activeVoiceSession:null,threads:[],catalog:[]});
  f.hooks.add=() => ({queuedSubmission:{id:queuedId,clientUserMessageId:sceneId}});
  const receipt=await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'unknown');
  assert.equal(receipt.deliveryScope,'exact-chat-queue-only');
  assert.equal((await f.call('/packets','POST',packet)).status,200);
  assert.equal((await f.receipt(packet.packetId)).state,'unknown');
  assert.equal(f.addCount(),1);
});

test('unconfigured inbox stays unavailable and cannot accept packets', async t => {
  const f = await fixture(t,'steer',() => true);
  assert.equal((await f.call('/inbox/target')).status,503);
  assert.deepEqual(await (await f.call(`/delivery/ready?threadId=${threadId}&targetMode=inbox`)).json(),
    {available:false});
  assert.equal((await f.call('/packets','POST',inboxInput())).status,409);
  assert.equal(f.calls.length,0);
});

for (const [mode,method,state,scope] of [
  ['selected-active','turn/steer','steered','active-turn-steer'],
  ['selected-idle','turn/start','started','exact-chat-start']
]) {
  test(`${mode} delivers image and scene to the exact visible chat without voice or queue`, async t => {
    const f = await fixture(t,mode), packet = selectedInput();
    const receipt = await (await f.call('/packets','POST',packet)).json();
    assert.equal(receipt.state,state);
    assert.equal(receipt.deliveryScope,scope);
    assert.equal(receipt.targetMode,'selected-chat');
    assert.equal(receipt.turnId,activeTurnId);
    assert.equal(receipt.queuedId,null);
    assert.equal(receipt.sessionContinuity.status,'observed-same');
    assert.equal(receipt.sessionContinuity.atomic,false);
    const dispatch = f.calls.at(-1);
    assert.equal(dispatch.method,method);
    assert.equal(dispatch.params.threadId,threadId);
    assert.equal(dispatch.params.clientUserMessageId,packet.packetId);
    assert.deepEqual(dispatch.params.input[1],{type:'localImage',path:path.join(f.store,packet.packetId,'image.png')});
    assert.ok(dispatch.params.input[0].text.includes(path.join(f.store,packet.packetId,'scene.json')));
    assert.deepEqual(f.calls.map(c => c.method),mode === 'selected-active' ?
      ['thread/read','thread/turns/list','turn/steer'] : ['thread/read','turn/start']);
    assert.deepEqual(await f.receipt(packet.packetId),receipt);
    await f.stop(); await f.start();
    f.snapshot({threads:[]});
    assert.deepEqual(await (await f.call('/packets','POST',packet)).json(),receipt);
    const alias = await (await f.call('/packets','POST',{...packet,packetId:crypto.randomUUID()})).json();
    assert.equal(alias.state,state);
    assert.equal(alias.canonicalPacketId,packet.packetId);
    assert.equal(alias.targetMode,'selected-chat');
    assert.equal(alias.deliveryScope,scope);
    assert.equal(f.calls.filter(c => c.method === method).length,1);
  });

  test(`${mode} concurrent duplicates and equivalent packets dispatch once`, async t => {
    const f = await fixture(t,mode), packet = selectedInput(), entered = deferred(), finish = deferred();
    f.hooks[method === 'turn/steer' ? 'steer' : 'start'] = async () => {
      entered.resolve(); await finish.promise;
      return method === 'turn/steer' ? {turnId:activeTurnId} : {turn:{id:activeTurnId}};
    };
    const first = f.call('/packets','POST',packet);
    await entered.promise;
    try {
      for (const packetId of [packet.packetId,crypto.randomUUID(),crypto.randomUUID()]) {
        const prior = await (await f.call('/packets','POST',{...packet,packetId})).json();
        assert.equal(prior.state,'dispatching');
        assert.equal(prior.deliveryScope,scope);
      }
    } finally { finish.resolve(); }
    assert.equal((await (await first).json()).state,state);
    assert.equal(f.calls.filter(c => c.method === method).length,1);
    assert.equal(f.addCount(),0);
  });

  for (const outcome of ['lost','malformed']) {
    test(`${mode} ${outcome} dispatch result stays unknown on duplicate and restart`, async t => {
      const f = await fixture(t,mode), packet = selectedInput();
      f.hooks[method === 'turn/steer' ? 'steer' : 'start'] = () => {
        if (outcome === 'lost') throw new Error('Synthetic response lost after dispatch');
        return method === 'turn/steer' ? {turnId:crypto.randomUUID()} : {turn:{id:'invalid'}};
      };
      const receipt = await (await f.call('/packets','POST',packet)).json();
      assert.equal(receipt.state,'unknown');
      assert.equal(receipt.deliveryScope,scope);
      assert.equal(receipt.targetMode,'selected-chat');
      await f.stop(); await f.start();
      assert.deepEqual(await (await f.call('/packets','POST',packet)).json(),receipt);
      const alias = await (await f.call('/packets','POST',{...packet,packetId:crypto.randomUUID()})).json();
      assert.equal(alias.state,'unknown');
      assert.equal(alias.canonicalPacketId,packet.packetId);
      assert.equal(f.calls.filter(c => c.method === method).length,1);
      assert.equal(f.addCount(),0);
    });
  }

  for (const change of ['stale','hidden','removed','tampered']) {
    test(`${mode} rechecks ${change} target or bytes at final dispatch boundary`, async t => {
      const f = await fixture(t,mode), packet = selectedInput();
      const mutate = () => {
        if (change === 'stale') f.snapshot({generatedAt:'2020-01-01T00:00:00Z'});
        if (change === 'hidden') f.hide([threadId]);
        if (change === 'removed') f.snapshot({threads:[]});
        if (change === 'tampered') fs.writeFileSync(path.join(f.store,packet.packetId,'image.png'),'changed');
      };
      if (mode === 'selected-active') f.hooks.turns = () => {
        mutate(); return {data:[{id:activeTurnId,status:'inProgress'}]};
      };
      else f.hooks.read = () => { mutate(); return {thread:{id:threadId,status:{type:'idle'}}}; };
      const receipt = await (await f.call('/packets','POST',packet)).json();
      assert.equal(receipt.state,'rejected');
      assert.equal(f.calls.some(c => c.method.startsWith('turn/')),false);
    });
  }

  test(`${mode} target removal after dispatch does not erase the native success receipt`, async t => {
    const f = await fixture(t,mode), packet = selectedInput();
    f.hooks[method === 'turn/steer' ? 'steer' : 'start'] = () => {
      f.snapshot({threads:[]});
      return method === 'turn/steer' ? {turnId:activeTurnId} : {turn:{id:activeTurnId}};
    };
    const receipt = await (await f.call('/packets','POST',packet)).json();
    assert.equal(receipt.state,state);
    assert.equal(receipt.turnId,activeTurnId);
    assert.equal(receipt.sessionContinuity.status,'changed-or-unavailable');
    assert.equal(receipt.sessionContinuity.after,null);
    assert.equal(receipt.sessionContinuity.before.threadId,threadId);
  });
}

for (const [name,change] of Object.entries({
  stale:{generatedAt:'2020-01-01T00:00:00Z'}, future:{generatedAt:'2099-01-01T00:00:00Z'},
  historyOnly:{threads:[],mobile:{threads:[{id:threadId,source:'codex',available:true}]}},
  savedOnly:{threads:[],mobile:{workspaces:[{id:'saved',slots:[{threadId}]}]}},
  hidden:{threads:[{id:threadId,slotIndex:2,source:'codex',available:true,hidden:true}]},
  unavailable:{catalog:[{id:threadId,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,available:false}]},
  archived:{catalog:[{id:threadId,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true,available:true,archived:true}]},
  staleCard:{threads:[{id:threadId,slotIndex:2,source:'codex',available:true,stale:true}]},
  missingSource:{catalog:[{id:threadId,source:'codex',available:true,sourceMissing:true}]},
  chatgpt:{catalog:[{id:threadId,source:'chatgpt',available:true}]},
  wrongCardSource:{threads:[{id:threadId,slotIndex:2,source:'chatgpt',available:true}]},
  outsideGrid:{threads:[{id:threadId,slotIndex:9,source:'codex',available:true}]},
  duplicateCatalog:{catalog:Array(2).fill({id:threadId,source:'codex',hostId:'local',forkedFromId:null,
    forkLineageVerified:true,available:true})},
  duplicateCard:{threads:[2,3].map(slotIndex => ({id:threadId,slotIndex,source:'codex',available:true}))}
})) {
  test(`selected-chat ${name} cannot authorize delivery`, async t => {
    const f = await fixture(t,'selected-idle');
    f.snapshot(change);
    const receipt = await (await f.call('/packets','POST',selectedInput())).json();
    assert.equal(receipt.state,'rejected');
    assert.equal(receipt.targetMode,'selected-chat');
    assert.equal(receipt.deliveryScope,'exact-chat-start');
    assert.deepEqual(f.calls,[]);
  });
}

test('selected-chat hidden file and unreadable hidden policy fail closed', async t => {
  const f = await fixture(t,'selected-idle');
  f.hide([threadId]);
  assert.equal((await (await f.call('/packets','POST',selectedInput())).json()).state,'rejected');
  fs.chmodSync(f.hiddenPath,0o644);
  assert.equal((await (await f.call('/packets','POST',selectedInput())).json()).state,'rejected');
  assert.deepEqual(f.calls,[]);
});

test('manual binding requires selected-chat mode and the lowercase exact thread UUID', async t => {
  const f = await fixture(t,'selected-idle');
  const id = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
  for (const packet of [input({targetMode:'other'}),selectedInput({sessionId}),
    selectedInput({sessionId:`manual:${crypto.randomUUID()}`}),selectedInput({sessionId:'manual:bad'}),
    selectedInput({threadId:id,sessionId:`manual:${id.toUpperCase()}`}),
    selectedInput({targetMode:null}),selectedInput({targetMode:undefined})]) {
    assert.equal((await f.call('/packets','POST',packet)).status,409);
  }
  assert.deepEqual(f.calls,[]);
  assert.deepEqual(fs.readdirSync(f.store),['.equivalent']);
});

test('legacy null target mode retains voice delivery and old receipt shape', async t => {
  const f = await fixture(t,'steer'), packet = input({targetMode:null});
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'steered');
  assert.equal(receipt.targetMode,undefined);
  assert.deepEqual(await (await f.call('/packets','POST',{...packet,targetMode:undefined})).json(),receipt);
});

test('selected-chat normalizes Swift UUID casing without weakening its manual session binding', async t => {
  const f = await fixture(t,'selected-idle'), id = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
  f.snapshot({threads:[{id,slotIndex:0,source:'codex',available:true}],catalog:[{id,source:'codex',hostId:'local',
    forkedFromId:null,forkLineageVerified:true,available:true}]});
  f.hooks.read = params => ({thread:{id:params.threadId,status:{type:'idle'}}});
  const packet = selectedInput({threadId:id.toUpperCase(),sessionId:`manual:${id}`,packetId:crypto.randomUUID().toUpperCase()});
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'started');
  assert.equal(receipt.threadId,id);
  assert.equal(receipt.packetId,packet.packetId.toLowerCase());
  assert.equal(f.calls.at(-1).params.threadId,id);
});

test('packet ID cannot cross target modes even with identical hashes', async t => {
  const f = await fixture(t,'selected-idle'), packet = selectedInput();
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'started');
  const response = await f.call('/packets','POST',{...packet,targetMode:null,sessionId});
  assert.equal(response.status,409);
  assert.match((await response.json()).error,/Packet ID already binds/);
  assert.equal(f.calls.filter(c => c.method === 'turn/start').length,1);
});

test('selected-chat native read must return the exact idle or verifiable active thread', async t => {
  const f = await fixture(t,'selected-active');
  for (const thread of [{id:crypto.randomUUID(),status:{type:'idle'}},
    {id:threadId,status:{type:'notLoaded'}},{id:threadId,status:{type:'systemError'}},
    {id:threadId,status:{type:'active',activeFlags:[]},canAcceptDirectInput:false},
    {id:threadId,status:{type:'active'},canAcceptDirectInput:true},
    {id:threadId,status:{type:'active',activeFlags:['waitingOnApproval']},canAcceptDirectInput:true}]) {
    f.hooks.read = () => ({thread});
    const receipt = await (await f.call('/packets','POST',selectedInput())).json();
    assert.equal(receipt.state,'rejected');
  }
  assert.equal(f.calls.some(c => c.method.startsWith('turn/')),false);
});

test('selected-chat refuses an unverified active turn without starting or queueing', async t => {
  const f = await fixture(t,'selected-active');
  for (const data of [[],[{id:activeTurnId,status:'completed'}],[{id:'bad',status:'inProgress'}],
    [{id:activeTurnId,status:'inProgress'},{id:crypto.randomUUID(),status:'inProgress'}]]) {
    f.hooks.turns = () => ({data});
    assert.equal((await (await f.call('/packets','POST',selectedInput())).json()).state,'rejected');
  }
  assert.equal(f.calls.some(c => c.method.startsWith('turn/')),false);
});

test('unloaded desktop turn rejects a new packet without queue fallback', async t => {
  const f = await fixture(t,'steer'), packet = input();
  f.hooks.read = () => ({thread:{id:threadId,status:{type:'notLoaded'},canAcceptDirectInput:null}});
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'rejected');
  assert.equal(receipt.deliveryScope,'active-turn-steer');
  assert.equal(receipt.turnId,null);
  assert.equal(f.addCount(),0);
  assert.deepEqual(f.calls.map(call=>call.method),['thread/read']);
});

test('a hidden PC voice card cannot authorize an iPad packet', async t => {
  const f = await fixture(t), packet = input();
  f.hide([threadId]);
  assert.equal((await (await f.call('/voice/projection')).json()).activeVoiceSession,null);
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'rejected');
  assert.equal((await f.receipt(packet.packetId)).state,'rejected');
  assert.equal(f.addCount(),0);
});

for (const source of ['catalog','current row']) {
  test(`snapshot hidden flag in ${source} refuses voice projection and packet enqueue`, async t => {
    const f = await fixture(t), id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    const packet = input({threadId:id});
    const card = {id:id.toUpperCase(),available:true,source:'codex',hidden:true};
    f.snapshot({activeVoiceId:id,
      activeVoiceSession:{threadId:id,sessionId,observedAt:new Date().toISOString()},
      ...(source === 'catalog' ? {catalog:[card]} : {threads:[card]})});
    assert.equal((await (await f.call('/voice/projection')).json()).activeVoiceSession,null);
    assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'rejected');
    assert.equal(f.addCount(),0);
  });
}

test('fresh projection requires a session pair; activeVoiceId alone cannot authorize', async t => {
  const f = await fixture(t);
  assert.equal((await f.call('/voice/projection')).status,200);
  f.snapshot({activeVoiceSession:null});
  assert.equal((await (await f.call('/voice/projection')).json()).activeVoiceSession,null);
  assert.equal((await (await f.call('/packets','POST',input())).json()).state,'rejected');
  assert.equal(f.addCount(),0);
  assert.equal((await f.call('/targets')).status,404);
  assert.equal((await f.call('/target?index=0&threadId='+threadId)).status,404);
});

for (const [name,change] of Object.entries({
  stale:{generatedAt:new Date(Date.now()-60000).toISOString()},
  future:{generatedAt:new Date(Date.now()+60000).toISOString()},
  closed:{activeVoiceSession:null},
  switched:{activeVoiceSession:{threadId,sessionId:'replacement',observedAt:new Date().toISOString()}},
  wrongThread:{activeVoiceId:crypto.randomUUID()},
  staleObservation:{activeVoiceSession:{threadId,sessionId,observedAt:'2020-01-01T00:00:00Z'}},
  malformed:{activeVoiceSession:{threadId,sessionId:'',observedAt:new Date().toISOString()}}
})) {
  test(`${name} projection refuses a new packet without enqueue`, async t => {
    const f = await fixture(t);
    f.snapshot(change);
    const packet = input();
    assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'rejected');
    assert.equal((await f.receipt(packet.packetId)).state,'rejected');
    assert.deepEqual(fs.readdirSync(path.join(f.store,'.equivalent')),[]);
    assert.equal(f.addCount(),0);
  });
  test(`${name} at last native preflight persists rejected receipt without enqueue`, async t => {
    const f = await fixture(t), packet = input();
    f.hooks.read = () => {
      f.snapshot(change);
      return {thread:{id:threadId,status:{type:'notLoaded'}}};
    };
    const response = await f.call('/packets','POST',packet);
    assert.equal((await response.json()).state,'rejected');
    assert.equal((await f.receipt(packet.packetId)).state,'rejected');
    assert.equal(f.addCount(),0);
  });
}

test('immutable bytes, pair, queue and separate continuity receipt survive restart; revision path remains', async t => {
  const f = await fixture(t), packet = input();
  const response = await f.call('/packets','POST',packet);
  assert.equal(response.status,201);
  const receipt = await response.json();
  for (const key of ['packetId','threadId','sessionId','imageSha256','sceneSha256'])
    assert.equal(receipt[key],packet[key]);
  assert.equal(receipt.state,'queued');
  assert.equal(receipt.queuedId,queuedId);
  assert.equal(receipt.deliveryScope,'exact-chat-queue-only');
  assert.equal(receipt.sessionContinuity.atomic,false);
  assert.equal(receipt.sessionContinuity.status,'observed-same');
  const directory = path.join(f.store,packet.packetId);
  assert.deepEqual(fs.readFileSync(path.join(directory,'image.png')),png);
  assert.deepEqual(fs.readFileSync(path.join(directory,'scene.json')),Buffer.from(packet.sceneJSONBase64,'base64'));
  assert.equal(fs.statSync(directory).mode & 0o777,0o700);
  for (const file of ['image.png','scene.json','packet.json','receipt.json'])
    assert.equal(fs.statSync(path.join(directory,file)).mode & 0o777,0o600);
  const revision = {sceneId,baseRevision:1,annotations:[],proposedNodes:[]};
  assert.equal((await f.call(`/packets/${packet.packetId}/revision`,'PUT',revision)).status,200);
  assert.deepEqual(await (await f.call(`/packets/${packet.packetId}/revision`)).json(),revision);
  assert.equal((await f.call(`/packets/${packet.packetId}/revision`,'PUT',{...revision,baseRevision:2})).status,409);
  assert.equal(fs.statSync(path.join(directory,'revision.json')).mode & 0o777,0o600);
  await f.stop(); await f.start();
  assert.deepEqual(await f.receipt(packet.packetId),receipt);
  f.snapshot({activeVoiceSession:null});
  assert.deepEqual(await (await f.call('/packets','POST',packet)).json(),receipt);
  assert.equal(f.addCount(),1);
});

test('concurrent duplicate POSTs reserve one dispatch, including across relay instances', async t => {
  const f = await fixture(t), packet = input(), entered = deferred(), finish = deferred();
  f.hooks.add = async params => {
    entered.resolve(); await finish.promise;
    return {queuedSubmission:{id:queuedId,clientUserMessageId:params.clientUserMessageId}};
  };
  const first = f.call('/packets','POST',packet);
  await entered.promise;
  const replies = await Promise.all(Array.from({length:12},() => f.call('/packets','POST',packet)));
  for (const response of replies) assert.equal((await response.json()).state,'dispatching');
  const other = createServer({snapshotPath:f.snapshotPath,hiddenPath:f.hiddenPath,store:f.store,token,
    deliver:() => { throw new Error('Duplicate dispatch'); }});
  await new Promise(resolve => other.listen(0,'127.0.0.1',resolve));
  try {
    const response = await fetch(`http://127.0.0.1:${other.address().port}/packets`,{method:'POST',
      headers:{'x-canvas-token':token},body:JSON.stringify(packet)});
    assert.equal((await response.json()).state,'unknown');
  } finally { other.closeAllConnections(); await new Promise(resolve => other.close(resolve)); }
  finish.resolve();
  assert.equal((await (await first).json()).state,'queued');
  assert.equal(f.addCount(),1);
});

test('lost HTTP response reconciles using the original packet ID without another enqueue', async t => {
  const f = await fixture(t), packet = input(), entered = deferred(), finish = deferred();
  f.hooks.add = async params => {
    entered.resolve(); await finish.promise;
    return {queuedSubmission:{id:queuedId,clientUserMessageId:params.clientUserMessageId}};
  };
  const controller = new AbortController();
  const first = f.call('/packets','POST',packet,controller.signal);
  await entered.promise;
  controller.abort();
  await assert.rejects(first,{name:'AbortError'});
  assert.equal((await f.receipt(packet.packetId)).state,'dispatching');
  finish.resolve();
  // Waiting for readback is deterministic; it signals that native processing passed enqueue.
  const listed = deferred();
  f.hooks.list = () => { listed.resolve(); return {data:[{id:queuedId,clientUserMessageId:packet.packetId}]}; };
  await listed.promise;
  assert.equal((await f.receipt(packet.packetId)).state,'queued');
  assert.equal(f.addCount(),1);
});

test('unknown native response stays unknown across duplicate POST and restart', async t => {
  const f = await fixture(t), packet = input();
  f.hooks.add = () => { throw new Error('Native response lost after enqueue'); };
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'unknown');
  assert.equal(receipt.queuedId,null);
  await f.stop(); await f.start();
  assert.deepEqual(await f.receipt(packet.packetId),receipt);
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'unknown');
  assert.equal(f.addCount(),1);
});

test('crash after dispatching or stored never resumes enqueue on restart', async t => {
  for (const state of ['stored','dispatching']) {
    const f = await fixture(t), packet = input();
    await f.call('/packets','POST',packet);
    await f.stop();
    const file = path.join(f.store,packet.packetId,'receipt.json');
    const receipt = JSON.parse(fs.readFileSync(file));
    fs.writeFileSync(file,JSON.stringify({...receipt,state,queuedId:null}));
    f.calls.length = 0;
    await f.start();
    assert.equal((await f.receipt(packet.packetId)).state,'unknown');
    assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'unknown');
    assert.equal(f.addCount(),0);
    await f.stop();
  }
});

test('native read refuses wrong or archived conversation before enqueue', async t => {
  for (const thread of [{id:crypto.randomUUID()},{id:threadId,status:{type:'archived'}}]) {
    const f = await fixture(t);
    f.hooks.read = () => ({thread});
    assert.equal((await (await f.call('/packets','POST',input())).json()).state,'rejected');
    assert.equal(f.addCount(),0);
  }
});

test('queue readback failure retains queue ID as unknown and never retries', async t => {
  const f = await fixture(t), packet = input();
  f.hooks.list = () => ({data:[]});
  const receipt = await (await f.call('/packets','POST',packet)).json();
  assert.equal(receipt.state,'unknown');
  assert.equal(receipt.queuedId,queuedId);
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'unknown');
  assert.equal(f.addCount(),1);
});

test('switch after enqueue is reported separately from exact chat queue success', async t => {
  const f = await fixture(t);
  f.hooks.list = () => {
    f.snapshot({activeVoiceSession:null});
    return {data:[{id:queuedId,clientUserMessageId:f.calls.filter(c => c.method === 'thread/queue/add').at(-1).params.clientUserMessageId}]};
  };
  const receipt = await (await f.call('/packets','POST',input())).json();
  assert.equal(receipt.state,'queued');
  assert.equal(receipt.sessionContinuity.status,'changed-or-unavailable');
  assert.equal(receipt.sessionContinuity.after,null);
  assert.equal(f.calls.find(c => c.method === 'thread/queue/add').params.threadId,threadId);
});

test('same packet ID conflicts on changed PNG, exact scene bytes, or session pair', async t => {
  const f = await fixture(t), packet = input();
  await f.call('/packets','POST',packet);
  const changedScene = Buffer.from(JSON.stringify(scene,null,2));
  const changedPNG = alternatePNG();
  for (const conflict of [
    {...packet,sceneJSONBase64:changedScene.toString('base64'),sceneSha256:sha(changedScene)},
    {...packet,sessionId:'other'},
    {...packet,threadId:crypto.randomUUID()},
    {...packet,imagePNGBase64:changedPNG.toString('base64'),imageSha256:sha(changedPNG)}
  ]) {
    const response = await f.call('/packets','POST',conflict);
    assert.equal(response.status,409);
    assert.match((await response.json()).error,/Packet ID already binds/);
  }
  assert.equal(f.addCount(),1);
});

test('hash mismatch, malformed PNG, invalid scene and payload limits fail without enqueue', async t => {
  const f = await fixture(t);
  for (const bad of [input({imageSha256:'0'.repeat(64)}),input({sceneSha256:'0'.repeat(64)}),
    input({imagePNGBase64:'garbage!'}),input({sceneJSONBase64:'e30=',sceneSha256:sha(Buffer.from('{}'))}),
    input({imagePNGBase64:Buffer.alloc(5*1024*1024+1).toString('base64')}),
    input({sceneJSONBase64:Buffer.alloc(4*1024*1024+1).toString('base64')})])
    assert.equal((await f.call('/packets','POST',bad)).status,409);
  assert.equal(f.addCount(),0);
});

test('stored byte tampering during native read prevents enqueue', async t => {
  const f = await fixture(t), packet = input();
  f.hooks.read = () => {
    fs.writeFileSync(path.join(f.store,packet.packetId,'scene.json'),'{}');
    return {thread:{id:threadId}};
  };
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'rejected');
  assert.equal(f.addCount(),0);
});

test('all endpoints require token; absent receipt is 404 without side effects', async t => {
  const f = await fixture(t);
  assert.equal((await f.call(`/packets/${crypto.randomUUID()}/receipt`)).status,404);
  const server = createServer({snapshotPath:f.snapshotPath,hiddenPath:f.hiddenPath,store:f.store,token});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  try {
    const root = `http://127.0.0.1:${server.address().port}`;
    for (const route of ['/voice/projection','/packets',`/packets/${crypto.randomUUID()}/receipt`])
      assert.equal((await fetch(root+route)).status,401);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  assert.equal(f.addCount(),0);
});

test('new packet IDs with equivalent bytes and pair converge during dispatch and after restart', async t => {
  const f = await fixture(t), packet = input(), entered = deferred(), finish = deferred();
  f.hooks.add = async params => {
    entered.resolve(); await finish.promise;
    return {queuedSubmission:{id:queuedId,clientUserMessageId:params.clientUserMessageId}};
  };
  const first = f.call('/packets','POST',packet);
  await entered.promise;
  const aliasId = crypto.randomUUID();
  const alias = await (await f.call('/packets','POST',{...packet,packetId:aliasId})).json();
  assert.equal(alias.packetId,aliasId);
  assert.equal(alias.canonicalPacketId,packet.packetId);
  assert.equal(alias.clientUserMessageId,packet.packetId);
  assert.equal(alias.state,'dispatching');
  assert.equal(f.addCount(),1);
  finish.resolve();
  assert.equal((await (await first).json()).state,'queued');
  assert.equal((await f.receipt(aliasId)).state,'queued');
  const revision = {sceneId,baseRevision:1,annotations:[],proposedNodes:[]};
  assert.equal((await f.call(`/packets/${packet.packetId}/revision`,'PUT',revision)).status,200);
  assert.deepEqual(await (await f.call(`/packets/${aliasId}/revision`)).json(),revision);
  assert.equal((await f.call(`/packets/${aliasId}/revision`,'PUT',revision)).status,200);
  await f.stop(); await f.start();
  const newId = crypto.randomUUID();
  f.snapshot({activeVoiceSession:null});
  const restored = await (await f.call('/packets','POST',{...packet,packetId:newId})).json();
  assert.equal(restored.state,'queued');
  assert.equal(restored.canonicalPacketId,packet.packetId);
  assert.equal(restored.queuedId,queuedId);
  assert.equal(restored.packetId,newId);
  assert.equal(f.addCount(),1);
});

test('new ID after lost native response and app restart cannot retry an equivalent unknown send', async t => {
  const f = await fixture(t), packet = input();
  f.hooks.add = () => { throw new Error('Native response lost'); };
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'unknown');
  await f.stop(); await f.start();
  const newId = crypto.randomUUID();
  f.snapshot({activeVoiceSession:null});
  const alias = await (await f.call('/packets','POST',{...packet,packetId:newId})).json();
  assert.equal(alias.state,'unknown');
  assert.equal(alias.packetId,newId);
  assert.equal(alias.canonicalPacketId,packet.packetId);
  assert.equal((await f.receipt(newId)).state,'unknown');
  assert.equal(f.addCount(),1);
});

test('queued packets from before equivalent-index creation are indexed without enqueue', async t => {
  const f = await fixture(t), packet = input();
  await f.call('/packets','POST',packet);
  await f.stop();
  fs.rmSync(path.join(f.store,'.equivalent'),{recursive:true,force:true});
  await f.start();
  const alias = await (await f.call('/packets','POST',{...packet,packetId:crypto.randomUUID()})).json();
  assert.equal(alias.state,'queued');
  assert.equal(alias.canonicalPacketId,packet.packetId);
  assert.equal(f.addCount(),1);
});

test('incomplete packet directory claims return 409 or bound unknown and never dispatch', async t => {
  const f = await fixture(t), packet = input();
  const directory = path.join(f.store,packet.packetId);
  fs.mkdirSync(directory,{mode:0o700});
  assert.equal((await f.call(`/packets/${packet.packetId}/receipt`)).status,409);
  assert.equal((await f.call('/packets','POST',packet)).status,409);
  await f.stop(); await f.start();
  assert.equal((await f.call(`/packets/${packet.packetId}/receipt`)).status,409);
  const manifest = {packetId:packet.packetId,threadId,sessionId,
    imageSha256:packet.imageSha256,sceneSha256:packet.sceneSha256,
    clientUserMessageId:packet.packetId,queuedId:null,deliveryScope:'exact-chat-queue-only',
    sessionContinuity:{status:'not-observed',atomic:false,before:null,after:null}};
  fs.writeFileSync(path.join(directory,'packet.json'),JSON.stringify(manifest),{mode:0o600});
  assert.equal((await f.receipt(packet.packetId)).state,'unknown');
  assert.equal((await f.call('/packets','POST',packet)).status,409);
  assert.equal(f.addCount(),0);
});

test('Swift uppercase UUIDs normalize to the exact native thread and packet IDs', async t => {
  const f = await fixture(t);
  const id = 'abcdefab-cdef-4abc-8def-abcdefabcdef';
  f.snapshot({activeVoiceId:id,activeVoiceSession:{threadId:id,sessionId,observedAt:new Date().toISOString()}});
  f.hooks.read = () => ({thread:{id}});
  const upper = input({packetId:crypto.randomUUID().toUpperCase(),threadId:id.toUpperCase()});
  const receipt = await (await f.call('/packets','POST',upper)).json();
  assert.equal(receipt.packetId,upper.packetId.toLowerCase());
  assert.equal(receipt.threadId,id);
  assert.equal(receipt.state,'queued');
  assert.equal(f.calls.find(c => c.method === 'thread/queue/add').params.threadId,id);
});

for (const crash of [
  {name:'legacy dispatch',scope:'active-turn-steer',selected:false,dispatch:true},
  {name:'selected steer',scope:'active-turn-steer',selected:true,dispatch:true},
  {name:'selected start',scope:'exact-chat-start',selected:true,dispatch:true},
  {name:'selected stored packet',scope:'exact-chat-start',selected:true,dispatch:false}
]) {
test(`${crash.name} process exit leaves durable unknown and prevents another delivery`, async t => {
  const {spawn} = require('node:child_process');
  const {once} = require('node:events');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-crash-'));
  const snapshotPath = path.join(dir,'snapshot.json'), hiddenPath = path.join(dir,'hidden-threads.json');
  fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids:[]}),{mode:0o600});
  const store = path.join(dir,'store');
  const effects = path.join(dir,'effects');
  const now = new Date().toISOString(), packet = crash.selected ? selectedInput() : input();
  fs.writeFileSync(snapshotPath,JSON.stringify({generatedAt:now,activeVoiceId:threadId,
    activeVoiceSession:{threadId,sessionId,observedAt:now},
    ...(crash.selected ? {activeVoiceId:null,activeVoiceSession:null,
      threads:[{id:threadId,slotIndex:1,available:true,source:'codex'}],
      catalog:[{id:threadId,available:true,source:'codex',hostId:'local',
        forkedFromId:null,forkLineageVerified:true}]} : {})}));
  const script = `
    const fs = require('node:fs');
    const {createServer} = require(${JSON.stringify(require.resolve('./server'))});
    const options = JSON.parse(process.argv[1]);
    const server = createServer({...options,deliver:async (packet,before) => {
      if (options.dispatch) {
        before(options.scope); fs.appendFileSync(options.effects,'dispatched\\n');
      }
      process.exit(73);
    }});
    server.listen(0,'127.0.0.1',() => process.stdout.write(String(server.address().port)+'\\n'));
  `;
  const child = spawn(process.execPath,['-e',script,JSON.stringify({snapshotPath,hiddenPath,store,token,effects,
    scope:crash.scope,dispatch:crash.dispatch})],
    {stdio:['ignore','pipe','pipe']});
  const exited = once(child,'exit');
  t.after(() => { child.kill(); fs.rmSync(dir,{recursive:true,force:true}); });
  const port = await new Promise((resolve,reject) => {
    child.once('error',reject);
    child.stdout.once('data',data => resolve(Number(String(data).trim())));
    child.once('exit',code => reject(new Error('Test relay exited before listening: '+code)));
  });
  await assert.rejects(fetch(`http://127.0.0.1:${port}/packets`,{method:'POST',
    headers:{'x-canvas-token':token},body:JSON.stringify(packet)}));
  assert.equal((await exited)[0],73);
  const saved = JSON.parse(fs.readFileSync(path.join(store,packet.packetId,'receipt.json')));
  assert.equal(saved.state,crash.dispatch ? 'dispatching' : 'stored');
  if (crash.dispatch) assert.equal(saved.deliveryScope,crash.scope);
  if (crash.selected) assert.equal(saved.targetMode,'selected-chat');
  let deliveries = 0;
  const restarted = createServer({snapshotPath,hiddenPath,store,token,deliver:async () => { deliveries++; }});
  await new Promise(resolve => restarted.listen(0,'127.0.0.1',resolve));
  try {
    const root = `http://127.0.0.1:${restarted.address().port}`;
    const receipt = await (await fetch(root+`/packets/${packet.packetId}/receipt`,{headers:{'x-canvas-token':token}})).json();
    assert.equal(receipt.state,'unknown');
    const alias = await (await fetch(root+'/packets',{method:'POST',headers:{'x-canvas-token':token},
      body:JSON.stringify({...packet,packetId:crypto.randomUUID()})})).json();
    assert.equal(alias.state,'unknown');
    assert.equal(alias.canonicalPacketId,packet.packetId);
    assert.equal(deliveries,0);
    assert.equal(fs.existsSync(effects) ? fs.readFileSync(effects,'utf8') : '',crash.dispatch ? 'dispatched\n' : '');
  } finally { restarted.closeAllConnections(); await new Promise(resolve => restarted.close(resolve)); }
});
}

test('a stale first send cannot poison equivalent content for a later fresh session', async t => {
  const f = await fixture(t), packet = input();
  f.snapshot({activeVoiceSession:null});
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'rejected');
  assert.deepEqual(fs.readdirSync(path.join(f.store,'.equivalent')),[]);
  await f.stop(); await f.start();
  assert.deepEqual(fs.readdirSync(path.join(f.store,'.equivalent')),[]);
  f.snapshot();
  const next = {...packet,packetId:crypto.randomUUID()};
  assert.equal((await (await f.call('/packets','POST',next)).json()).state,'queued');
  assert.equal(f.addCount(),1);
});

test('definite pre-enqueue rejection permits a new authorized attempt without racing two enqueues', async t => {
  const f = await fixture(t), packet = input();
  f.hooks.read = () => {
    f.snapshot({activeVoiceSession:null});
    return {thread:{id:threadId}};
  };
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'rejected');
  assert.equal(f.addCount(),0);
  delete f.hooks.read;
  f.snapshot();
  const attempts = await Promise.all(Array.from({length:8},() =>
    f.call('/packets','POST',{...packet,packetId:crypto.randomUUID()})));
  for (const response of attempts) {
    const receipt = await response.json();
    assert.equal(['queued','stored','dispatching'].includes(receipt.state),true);
  }
  assert.equal(f.addCount(),1);
  assert.equal((await f.receipt(packet.packetId)).state,'rejected');
});


test('a deliberate unchanged scene send to a newly observed session has its own queue effect', async t => {
  const f = await fixture(t), packet = input();
  assert.equal((await (await f.call('/packets','POST',packet)).json()).state,'queued');
  const nextSession = 'replacement-realtime-session';
  f.snapshot({activeVoiceSession:{threadId,sessionId:nextSession,observedAt:new Date().toISOString()}});
  const next = {...packet,packetId:crypto.randomUUID(),sessionId:nextSession};
  const receipt = await (await f.call('/packets','POST',next)).json();
  assert.equal(receipt.state,'queued');
  assert.equal(receipt.packetId,next.packetId);
  assert.equal(receipt.sessionId,nextSession);
  assert.equal(receipt.canonicalPacketId,undefined);
  assert.equal(f.addCount(),2);
});
