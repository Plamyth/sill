'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {withAppServer,readinessForThread,deliverPacket,deliverQueuedPacket} = require('./codex-delivery');

const sampleScene = () => ({schemaVersion:1,id:'44444444-4444-4444-8444-444444444444',revision:3,
  width:2048,height:1536,drawingBase64:'private-pencil-bytes',
  strokes:[{id:'55555555-5555-4555-8555-555555555555',createdAt:'2026-10-16T00:00:00Z',
    points:[{x:127.25,y:280.5,pressure:0.4},{x:131.75,y:290.5,pressure:0.7}]}],
  nodes:[{id:'66666666-6666-4666-8666-666666666666',kind:'note',
    frame:{x:100,y:200,width:260,height:120},text:'음성 설명 확인',confidence:'confirmed',
    sourceStrokeIds:['55555555-5555-4555-8555-555555555555']}],
  links:[{id:'77777777-7777-4777-8777-777777777777',
    from:'66666666-6666-4666-8666-666666666666',
    to:'66666666-6666-4666-8666-666666666666',label:'다음 단계'}],
  annotations:[{id:'88888888-8888-4888-8888-888888888888',
    nodeId:'66666666-6666-4666-8666-666666666666',text:'수정 후보',author:'agent'}]});

async function captureSceneDelivery(t,scene) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-vector-'));
  t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image');
  fs.writeFileSync(scenePath,JSON.stringify(scene));
  const threadId='11111111-1111-4111-8111-111111111111';
  let text;
  await deliverPacket({threadId,packetId:'22222222-2222-4222-8222-222222222222',
    imagePath,scenePath,targetMode:'selected-chat',sessionId:`manual:${threadId}`},async (method,params) => {
    if (method === 'thread/read') return {thread:{id:threadId,status:{type:'idle'}}};
    assert.equal(method,'turn/start');
    assert.deepEqual(params.input[1],{type:'localImage',path:imagePath});
    text = params.input[0].text;
    return {turn:{id:'33333333-3333-4333-8333-333333333333'}};
  },() => {});
  const json = text.split('\n구조 데이터(JSON): ')[1];
  return {text,json,structure:JSON.parse(json),scenePath};
}

test('readiness requires the exact loaded chat and a steerable turn or selected idle chat', async () => {
  const id='11111111-1111-4111-8111-111111111111';
  const turn='22222222-2222-4222-8222-222222222222';
  const loaded = async method => method === 'thread/read' ?
    {thread:{id,status:{type:'active',activeFlags:[]},canAcceptDirectInput:true}} :
    {data:[{id:turn,status:'inProgress'}]};
  assert.equal(await readinessForThread(id,'voice',loaded),true);
  assert.equal(await readinessForThread(id,'selected-chat',loaded),true);
  assert.equal(await readinessForThread(id,'voice',async () =>
    ({thread:{id,status:{type:'notLoaded'},canAcceptDirectInput:null}})),false);
  const queueCalls=[];
  assert.equal(await readinessForThread(id,'inbox',async method => {
    queueCalls.push(method);
    return method === 'thread/read' ? {thread:{id,status:{type:'notLoaded'},canAcceptDirectInput:null}} : {data:[]};
  }),true);
  assert.deepEqual(queueCalls,['thread/read','thread/queue/list']);
  assert.equal(await readinessForThread(id,'inbox',async method => method === 'thread/read' ?
    {thread:{id,status:{type:'notLoaded'}}} : {data:null}),false);
  assert.equal(await readinessForThread(id,'selected-chat',async () =>
    ({thread:{id,status:{type:'idle'}}})),true);
  assert.equal(await readinessForThread(id,'voice',async () =>
    ({thread:{id,status:{type:'idle'}}})),false);
  assert.equal(await readinessForThread(id,'voice',async method => method === 'thread/read' ?
    {thread:{id,status:{type:'active',activeFlags:[]},canAcceptDirectInput:false}} :
    {data:[{id:turn,status:'inProgress'}]}),false);
  assert.equal(await readinessForThread(id,'voice',async method => method === 'thread/read' ?
    {thread:{id,status:{type:'active',activeFlags:[]},canAcceptDirectInput:true}} :
    {data:[{id:turn,status:'completed'}]}),false);
  assert.equal(await readinessForThread(id,'selected-chat',async method => method === 'thread/read' ?
    {thread:{id,status:{type:'active'},canAcceptDirectInput:true}} :
    {data:[{id:turn,status:'inProgress'}]}),false);
  assert.equal(await readinessForThread(id,'voice',async () =>
    ({thread:{id:'33333333-3333-4333-8333-333333333333',status:{type:'idle'}}})),false);
  assert.equal(await readinessForThread('invalid','voice',async () => assert.fail('invalid id reached RPC')),false);
});

test('no shared desktop socket fails closed without starting an independent app-server', async () => {
  const missing = path.join(os.tmpdir(),`absent-canvas-socket-${process.pid}`);
  await assert.rejects(withAppServer(() => { throw new Error('unexpected'); },{socketPath:missing}),
    /전송하지 않았습니다/);
});

test('canvas delivery queues the exact image and stable packet id with readback', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-delivery-'));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,JSON.stringify(sampleScene()));
  const threadId='11111111-1111-4111-8111-111111111111';
  const packetId='22222222-2222-4222-8222-222222222222';
  const queuedId='33333333-3333-4333-8333-333333333333';
  const calls=[];
  try {
    const result=await deliverQueuedPacket({threadId,packetId,imagePath,scenePath},async(method,params)=>{
      calls.push({method,params});
      if(method==='thread/read')return {thread:{id:threadId,status:{type:'notLoaded'}}};
      if(method==='thread/queue/add')return {queuedSubmission:{id:queuedId,clientUserMessageId:packetId}};
      if(method==='thread/queue/list')return {data:[{id:queuedId,clientUserMessageId:packetId}]};
    },() => calls.push({method:'pre-enqueue'}));
    assert.deepEqual(result,{queuedId,clientUserMessageId:packetId});
    assert.deepEqual(calls.map(call=>call.method),['thread/read','pre-enqueue','thread/queue/add','thread/queue/list']);
    assert.equal(calls[2].params.clientUserMessageId,packetId);
    assert.deepEqual(calls[2].params.input[1],{type:'localImage',path:imagePath});
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test('an active CanvasBridge send steers its exact turn instead of entering the queue', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-steer-'));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,JSON.stringify(sampleScene()));
  const threadId='11111111-1111-4111-8111-111111111111';
  const packetId='22222222-2222-4222-8222-222222222222';
  const turnId='33333333-3333-4333-8333-333333333333';
  const calls=[];
  try {
    const result=await deliverPacket({threadId,packetId,imagePath,scenePath},async(method,params)=>{
      calls.push(method);
      if(method==='thread/read') return {thread:{id:threadId,status:{type:'active',activeFlags:[]},canAcceptDirectInput:true}};
      if(method==='thread/turns/list') return {data:[{id:turnId,status:'inProgress'}]};
      if(method==='turn/steer') return {turnId};
      if(method==='thread/queue/add') return {queuedSubmission:{id:turnId,clientUserMessageId:packetId}};
      if(method==='thread/queue/list') return {data:[{id:turnId,clientUserMessageId:packetId}]};
    },() => calls.push('pre-dispatch'));
    assert.deepEqual(result,{turnId,clientUserMessageId:packetId});
    assert.deepEqual(calls,['thread/read','thread/turns/list','pre-dispatch','turn/steer']);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test('an unloaded desktop turn refuses delivery before any dispatch', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-unloaded-'));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,JSON.stringify(sampleScene()));
  const threadId='11111111-1111-4111-8111-111111111111';
  const packetId='22222222-2222-4222-8222-222222222222';
  const calls=[];
  try {
    await assert.rejects(deliverPacket({threadId,packetId,imagePath,scenePath},async method => {
      calls.push(method);
      return {thread:{id:threadId,status:{type:'notLoaded'},canAcceptDirectInput:null}};
    },() => calls.push('pre-dispatch')), /전송하지 않았습니다/);
    assert.deepEqual(calls,['thread/read']);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test('unloaded fixed inbox queues the exact packet once with readback', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-inbox-queue-'));
  t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const imagePath=path.join(dir,'image.png'),scenePath=path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,JSON.stringify(sampleScene()));
  const threadId='11111111-1111-4111-8111-111111111111';
  const packetId='22222222-2222-4222-8222-222222222222';
  const queuedId='33333333-3333-4333-8333-333333333333';
  const calls=[];
  const packet={threadId,packetId,imagePath,scenePath,targetMode:'inbox',sessionId:`inbox:${threadId}`};
  const result=await deliverPacket(packet,async(method,params) => {
    calls.push(method);
    if (method === 'thread/read') return {thread:{id:threadId,status:{type:'notLoaded'},canAcceptDirectInput:null}};
    if (method === 'thread/queue/add') {
      assert.equal(params.clientUserMessageId,packetId);
      assert.deepEqual(params.input[1],{type:'localImage',path:imagePath});
      assert.ok(params.input[0].text.includes(scenePath));
      assert.match(params.input[0].text,/고정 수신함/);
      return {queuedSubmission:{id:queuedId,clientUserMessageId:packetId}};
    }
    if (method === 'thread/queue/list') return {data:[{id:queuedId,clientUserMessageId:packetId}]};
    assert.fail(`Unexpected ${method}`);
  },scope => { assert.equal(scope,'exact-chat-queue-only'); calls.push('pre-dispatch'); });
  assert.deepEqual(result,{queuedId,clientUserMessageId:packetId,deliveryScope:'exact-chat-queue-only'});
  assert.deepEqual(calls,['thread/read','pre-dispatch','thread/queue/add','thread/queue/list']);
});

for (const status of ['active','idle']) {
  test(`selected-chat ${status} dispatches only after the durable boundary with exact thread and image`, async t => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-selected-'));
    t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
    const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
    fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,JSON.stringify(sampleScene()));
    const threadId='11111111-1111-4111-8111-111111111111';
    const packetId='22222222-2222-4222-8222-222222222222';
    const turnId='33333333-3333-4333-8333-333333333333';
    const method = status === 'active' ? 'turn/steer' : 'turn/start';
    const deliveryScope = status === 'active' ? 'active-turn-steer' : 'exact-chat-start';
    const calls=[];
    let dispatched = false;
    const packet = {threadId,packetId,imagePath,scenePath,targetMode:'selected-chat',sessionId:`manual:${threadId}`};
    const result = await deliverPacket(packet,async (name,params) => {
      calls.push(name);
      assert.equal(params.threadId,threadId);
      if (name === 'thread/read') return {thread:{id:threadId,status:{type:status,activeFlags:[]},canAcceptDirectInput:true}};
      if (name === 'thread/turns/list') return {data:[{id:turnId,status:'inProgress'}]};
      assert.equal(name,method);
      assert.equal(dispatched,true);
      assert.equal(params.clientUserMessageId,packetId);
      assert.deepEqual(params.input[1],{type:'localImage',path:imagePath});
      assert.ok(params.input[0].text.includes(scenePath));
      assert.match(params.input[0].text,/음성 설명 확인/);
      assert.match(params.input[0].text,/다음 단계/);
      assert.match(params.input[0].text,/수정 후보/);
      assert.match(params.input[0].text,/"pointCount":2/);
      const structure = JSON.parse(params.input[0].text.split('\n구조 데이터(JSON): ')[1]);
      assert.deepEqual(structure.strokes[0],{id:sampleScene().strokes[0].id,
        createdAt:sampleScene().strokes[0].createdAt,pointCount:2,
        bounds:{minX:127.25,minY:280.5,maxX:131.75,maxY:290.5},points:sampleScene().strokes[0].points});
      assert.deepEqual(structure.nodes,sampleScene().nodes);
      assert.deepEqual(structure.links,sampleScene().links);
      assert.deepEqual(structure.annotations,sampleScene().annotations);
      assert.doesNotMatch(params.input[0].text,/private-pencil-bytes|drawingBase64|structureOmitted/);
      if (status === 'active') assert.equal(params.expectedTurnId,turnId);
      else assert.equal(params.expectedTurnId,undefined);
      return status === 'active' ? {turnId} : {turn:{id:turnId,status:'inProgress'}};
    },scope => { assert.equal(scope,deliveryScope); dispatched = true; calls.push('pre-dispatch'); });
    assert.deepEqual(result,{turnId,clientUserMessageId:packetId,deliveryScope});
    assert.deepEqual(calls,status === 'active' ? ['thread/read','thread/turns/list','pre-dispatch',method] :
      ['thread/read','pre-dispatch',method]);
    await assert.rejects(deliverPacket({...packet,sessionId:`manual:${packetId}`},
      () => assert.fail('Malformed binding reached app-server'),() => assert.fail('Malformed binding dispatched')),
    /target binding invalid/);
  });
}

test('inline geometry preserves stroke and point order, precision, zero pressure and empty strokes', async t => {
  const scene = sampleScene();
  scene.strokes[0].points = [
    {x:-12.3456789012345,y:42.00000000000001,pressure:0},
    {x:0,y:-0.125,pressure:0.123456789012345},
    {x:-12.3456789012345,y:42.00000000000001,pressure:1}
  ];
  scene.strokes.push({id:'99999999-9999-4999-8999-999999999999',createdAt:scene.strokes[0].createdAt,points:[]});
  const {text,structure} = await captureSceneDelivery(t,scene);
  assert.deepEqual(structure.strokes.map(stroke => stroke.points),scene.strokes.map(stroke => stroke.points));
  assert.deepEqual(structure.strokes.map(stroke => stroke.pointCount),[3,0]);
  assert.deepEqual(structure.strokes[0].bounds,
    {minX:-12.3456789012345,minY:-0.125,maxX:0,maxY:42.00000000000001});
  assert.equal(structure.strokes[1].bounds,null);
  assert.match(text,/획의 x\/y\/pressure 좌표를 정확히 포함했습니다/);
  assert.doesNotMatch(text,/drawingBase64|private-pencil-bytes/);
});

test('vector overflow omits all geometry and semantic structure instead of sending a partial drawing', async t => {
  const scene = sampleScene();
  scene.strokes[0].points = Array.from({length:3000},(_,i) => ({x:i,y:-i,pressure:0.5}));
  const {text,json,structure,scenePath} = await captureSceneDelivery(t,scene);
  assert.ok(Buffer.byteLength(json,'utf8') <= 64 * 1024);
  assert.deepEqual(structure,{schemaVersion:1,id:scene.id,revision:3,width:2048,height:1536,
    counts:{strokes:1,nodes:1,links:1,annotations:1},structureOmitted:true});
  assert.match(text,/의도를 확정하기 전에 원본 장면 전체를 읽으세요/);
  assert.ok(text.includes(scenePath));
  assert.doesNotMatch(text,/"points"|"bounds"|"pointCount"|음성 설명 확인|다음 단계|수정 후보|drawingBase64|private-pencil-bytes/);
});

test('inline limit includes exact geometry and uses UTF-8 bytes with an inclusive 64 KiB boundary', async t => {
  const scene = sampleScene();
  scene.nodes[0].text = '한';
  const baseline = await captureSceneDelivery(t,scene);
  scene.nodes[0].text += 'a'.repeat(64 * 1024 - Buffer.byteLength(baseline.json,'utf8'));
  const atLimit = await captureSceneDelivery(t,scene);
  assert.equal(Buffer.byteLength(atLimit.json,'utf8'),64 * 1024);
  assert.deepEqual(atLimit.structure.strokes[0].points,scene.strokes[0].points);
  assert.equal(atLimit.structure.nodes[0].text,scene.nodes[0].text);
  assert.equal(atLimit.structure.structureOmitted,undefined);
  scene.nodes[0].text += 'a';
  const overflow = await captureSceneDelivery(t,scene);
  assert.equal(overflow.structure.structureOmitted,true);
  assert.equal(overflow.structure.strokes,undefined);
  assert.equal(overflow.structure.nodes,undefined);
});

test('invalid geometry refuses active and idle delivery before dispatch even in oversized scenes', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-invalid-vector-'));
  t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image');
  const threadId='11111111-1111-4111-8111-111111111111';
  const packet = {threadId,packetId:'22222222-2222-4222-8222-222222222222',
    imagePath,scenePath,targetMode:'selected-chat',sessionId:`manual:${threadId}`};
  const invalidPoints = [null,[],{},'point'];
  for (const field of ['x','y','pressure']) {
    for (const value of [undefined,null,'0.5',true,[],{},NaN,Infinity,-Infinity]) {
      invalidPoints.push({...sampleScene().strokes[0].points[0],[field]:value});
    }
  }
  for (const status of ['active','idle']) {
    const reject = async (raw,error) => {
      fs.writeFileSync(scenePath,raw);
      const calls=[];
      await assert.rejects(deliverPacket(packet,async method => {
        calls.push(method);
        assert.equal(method,'thread/read');
        return {thread:{id:threadId,status:{type:status,activeFlags:[]},canAcceptDirectInput:true}};
      },() => assert.fail('invalid geometry crossed durable dispatch boundary')),error);
      assert.deepEqual(calls,['thread/read']);
    };
    for (const point of invalidPoints) {
      const scene = sampleScene();
      scene.nodes[0].text = 'a'.repeat(70 * 1024);
      scene.strokes[0].points.push(point);
      await reject(JSON.stringify(scene),/stroke point invalid/);
    }
    for (const field of ['x','y','pressure']) {
      const scene = sampleScene();
      scene.strokes[0].points[1][field] = 'nonfinite';
      await reject(JSON.stringify(scene).replace('"nonfinite"','1e400'),/stroke point invalid/);
    }
    for (const stroke of [null,{}, {points:null},{points:{}}]) {
      const scene = sampleScene();
      scene.strokes.push(stroke);
      await reject(JSON.stringify(scene),/stroke structure invalid/);
    }
  }
});

test('large structured scene explicitly defers full interpretation to the original scene file', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-large-scene-'));
  t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  const scene = sampleScene();
  scene.nodes[0].text = 'a'.repeat(70 * 1024);
  fs.writeFileSync(imagePath,'image');
  fs.writeFileSync(scenePath,JSON.stringify(scene));
  const threadId='11111111-1111-4111-8111-111111111111';
  const packetId='22222222-2222-4222-8222-222222222222';
  let text;
  await deliverPacket({threadId,packetId,imagePath,scenePath,targetMode:'selected-chat',
    sessionId:`manual:${threadId}`},async (method,params) => {
    if (method === 'thread/read') return {thread:{id:threadId,status:{type:'idle'}}};
    assert.equal(method,'turn/start');
    text = params.input[0].text;
    return {turn:{id:'33333333-3333-4333-8333-333333333333'}};
  },() => {});
  assert.ok(text.length < 3000);
  assert.match(text,/"structureOmitted":true/);
  assert.match(text,/"nodes":1/);
  assert.match(text,/의도를 확정하기 전에 원본 장면 전체를 읽으세요/);
  assert.ok(text.includes(scenePath));
  assert.doesNotMatch(text,/a{100}/);
});

test('invalid scene fails before durable dispatch', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-invalid-scene-'));
  t.after(() => fs.rmSync(dir,{recursive:true,force:true}));
  const imagePath = path.join(dir,'image.png'), scenePath = path.join(dir,'scene.json');
  fs.writeFileSync(imagePath,'image'); fs.writeFileSync(scenePath,'{}');
  const threadId='11111111-1111-4111-8111-111111111111';
  await assert.rejects(deliverPacket({threadId,
    packetId:'22222222-2222-4222-8222-222222222222',imagePath,scenePath,
    targetMode:'selected-chat',sessionId:`manual:${threadId}`},async method => {
    assert.equal(method,'thread/read');
    return {thread:{id:threadId,status:{type:'idle'}}};
  },() => assert.fail('invalid scene crossed durable boundary')),/scene structure invalid/);
});
