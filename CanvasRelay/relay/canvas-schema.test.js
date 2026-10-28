'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {PassThrough} = require('node:stream');
const {createServer,parsePacket} = require('./server');
const {deliverPacket} = require('./codex-delivery');

const id = '11111111-1111-4111-8111-111111111111';
const threadId = '22222222-2222-4222-8222-222222222222';
const turnId = '33333333-3333-4333-8333-333333333333';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const settings = () => ({version:1,color:'cyan',width:8});
const style = () => ({version:1,inkType:'com.apple.ink.pen',
  color:{red:0,green:1,blue:1,alpha:1},transform:{a:1,b:0,c:0,d:1,tx:0,ty:0},
  samples:[{width:8,height:7,opacity:0.5}]});
const scene = () => ({schemaVersion:2,id,revision:3,width:2048,height:1536,
  drawingBase64:Buffer.from('opaque fixture, not a PKDrawing').toString('base64'),
  penSettings:settings(),strokes:[{id:turnId,createdAt:814000000,
    points:[{x:10,y:20,pressure:0.5}],style:style(),
    visibility:{kind:'masked',visibleSegments:[{lowerBound:0,upperBound:0,worldPoints:[]}]}}],
  nodes:[],links:[],annotations:[],futureField:{text:'한글 e\u0301 🖊️'}});
function packet(value, bytes = Buffer.from(JSON.stringify(value,null,2))) {
  return {packetId:crypto.randomUUID(),threadId,sessionId:`inbox:${threadId}`,targetMode:'inbox',
    imageSha256:sha(png),sceneSha256:sha(bytes),imagePNGBase64:png.toString('base64'),
    sceneJSONBase64:bytes.toString('base64')};
}
function fixture(t, status = 'idle') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-schema-'));
  const store = path.join(root,'packets'), vaultRoot = path.join(root,'vault');
  fs.mkdirSync(vaultRoot);
  const calls = [], deliveries = [];
  const token = crypto.randomBytes(24).toString('hex');
  const server = createServer({store,vaultRoot,token,inboxThreadId:threadId,
    snapshotPath:path.join(root,'absent-snapshot'),hiddenPath:path.join(root,'absent-policy'),
    deliveryReady:() => false,
    deliver:async (value,before) => {
      deliveries.push(value);
      return deliverPacket(value,async (method,params) => {
        calls.push({method,params});
        if (method === 'thread/read') return {thread:{id:threadId,status:{type:status,activeFlags:[]},canAcceptDirectInput:true}};
        if (method === 'thread/turns/list') return {data:[{id:turnId,status:'inProgress'}]};
        if (method === 'turn/start') return {turn:{id:turnId}};
        if (method === 'turn/steer') return {turnId};
        if (method === 'thread/queue/add') return {queuedSubmission:{id:turnId,clientUserMessageId:value.packetId}};
        if (method === 'thread/queue/list') return {data:[{id:turnId,clientUserMessageId:value.packetId}]};
        assert.fail(`unexpected fixture RPC ${method}`);
      },before);
    }});
  t.after(() => { server.close(); fs.rmSync(root,{recursive:true,force:true}); });
  const call = (url,method = 'GET',body,authorized = true) => new Promise(resolve => {
    const request = new PassThrough();
    Object.assign(request,{url,method,headers:authorized ? {'x-canvas-token':token} : {}});
    const response = {writeHead(status,headers) { this.status = status; this.headers = headers; },
      end(value) { resolve({status:this.status,body:JSON.parse(value)}); }};
    server.emit('request',request,response);
    request.end(body === undefined ? '' : JSON.stringify(body));
  });
  return {call,calls,deliveries,store,server,root};
}

test('schema 2 settings and native style pass the actual parser without changing bytes', () => {
  for (const color of ['white','yellow','cyan']) for (const width of [2,4,8]) {
    const value = scene(); value.penSettings = {version:1,color,width};
    const body = packet(value), before = structuredClone(body);
    const parsed = parsePacket(body,threadId);
    assert.deepEqual(parsed.scene,Buffer.from(body.sceneJSONBase64,'base64'));
    assert.equal(parsed.binding.sceneSha256,body.sceneSha256);
    assert.equal(JSON.parse(parsed.scene).schemaVersion,2);
    assert.deepEqual(body,before);
  }
});

test('legacy unknown style remains unknown and schema 2 settings need no native strokes', () => {
  for (const schemaVersion of [1,2]) {
    const value = {...scene(),schemaVersion,drawingBase64:''};
    delete value.penSettings; delete value.strokes[0].style;
    const body = packet(value), parsed = parsePacket(body,threadId);
    assert.deepEqual(parsed.scene,Buffer.from(body.sceneJSONBase64,'base64'));
    assert.equal(JSON.parse(parsed.scene).strokes[0].style,undefined);
  }
  const value = {...scene(),drawingBase64:'',strokes:[]};
  assert.doesNotThrow(() => parsePacket(packet(value),threadId));
  value.penSettings = null;
  assert.doesNotThrow(() => parsePacket(packet(value),threadId));
  const unknownColor = scene(); unknownColor.strokes[0].style.color = null;
  assert.doesNotThrow(() => parsePacket(packet(unknownColor),threadId));
});

test('schema, pen settings and native style shape errors fail before persistence or delivery', async t => {
  const f = fixture(t), changes = [
    s => { s.schemaVersion = 3; }, s => { s.schemaVersion = '2'; },
    s => { s.schemaVersion = 1; },
    ...[0,2,'1',null].map(v => s => { s.penSettings.version = v; }),
    ...['red','',null,{}].map(v => s => { s.penSettings.color = v; }),
    ...[0,3,16,'8',null].map(v => s => { s.penSettings.width = v; }),
    s => { s.penSettings.extra = true; }, s => { delete s.penSettings.color; },
    s => { s.drawingBase64 = ''; }, s => { s.drawingBase64 = null; },
    s => { s.strokes[0].style.version = 2; }, s => { s.strokes[0].style.inkType = ''; },
    s => { s.strokes[0].style.color.red = 2; }, s => { s.strokes[0].style.color.alpha = -1; },
    s => { s.strokes[0].style.transform.tx = '0'; },
    s => { s.strokes[0].style.samples = []; },
    s => { s.strokes[0].style.samples[0].width = -1; },
    s => { s.strokes[0].style.samples[0].height = null; },
    s => { s.strokes[0].style.samples[0].opacity = 1.1; },
    s => { s.strokes[0].style = []; }, s => { s.strokes[0].points[0].x = null; }
  ];
  for (const change of changes) {
    const value = scene(); change(value); const body = packet(value);
    assert.throws(() => parsePacket(body,threadId));
    assert.equal((await f.call('/packets','POST',body)).status,409);
    assert.equal(fs.existsSync(path.join(f.store,body.packetId)),false);
  }
  assert.equal(f.deliveries.length,0);
});

test('direct delivery applies the same schema and style guards before any dispatch', async t => {
  const f = fixture(t), scenePath = path.join(f.root,'scene.json'), imagePath = path.join(f.root,'image.png');
  fs.writeFileSync(imagePath,png);
  for (const invalid of [s => { s.schemaVersion = 9; },s => { s.penSettings.width = 3; },
    s => { s.drawingBase64 = ''; },s => { s.strokes[0].style.samples = []; }]) {
    const value = scene(); invalid(value); fs.writeFileSync(scenePath,JSON.stringify(value));
    await assert.rejects(deliverPacket({...packet(value),scenePath,imagePath},async method => {
      assert.equal(method,'thread/read');
      return {thread:{id:threadId,status:{type:'idle'}}};
    },() => assert.fail('invalid scene dispatched')));
  }
});

test('legacy unknown fields survive the actual handler and AI never invents an ink style', async t => {
  const f = fixture(t), value = {...scene(),schemaVersion:1,drawingBase64:''};
  delete value.penSettings; delete value.strokes[0].style;
  const body = packet(value);
  assert.equal((await f.call('/packets','POST',body)).body.state,'started');
  const text = f.calls.find(c => c.method === 'turn/start').params.input[0].text;
  const inline = JSON.parse(text.split('\n구조 데이터(JSON): ')[1]);
  assert.equal(inline.schemaVersion,1);
  assert.equal(inline.penSettings,undefined);
  assert.equal(inline.strokes[0].style,undefined);
  assert.deepEqual(fs.readFileSync(path.join(f.store,body.packetId,'scene.json')),
    Buffer.from(body.sceneJSONBase64,'base64'));
});

test('schema 2 retains packet byte, PNG, ID and 4 MiB scene limits', () => {
  const body = packet(scene());
  for (const changes of [{packetId:'bad'},{sceneSha256:'0'.repeat(64)},
    {imageSha256:'0'.repeat(64)},{imagePNGBase64:Buffer.from('not png!').toString('base64')},
    {sceneJSONBase64:'!bad'}]) assert.throws(() => parsePacket({...body,...changes},threadId));
  const atLimit = Buffer.concat([Buffer.from(body.sceneJSONBase64,'base64'),
    Buffer.alloc(4*1024*1024-Buffer.from(body.sceneJSONBase64,'base64').length,32)]);
  assert.equal(parsePacket(packet(scene(),atLimit),threadId).scene.length,4*1024*1024);
  assert.throws(() => parsePacket(packet(scene(),Buffer.concat([atLimit,Buffer.from(' ')])),threadId),/exceeds 4 MiB/);
});

test('oversize AI projection explicitly omits structure while keeping the exact schema 2 file', async t => {
  const f = fixture(t), value = scene();
  value.nodes = [{text:'한'.repeat(30000)}];
  const body = packet(value);
  assert.equal((await f.call('/packets','POST',body)).body.state,'started');
  const text = f.calls.find(c => c.method === 'turn/start').params.input[0].text;
  const inline = JSON.parse(text.split('\n구조 데이터(JSON): ')[1]);
  assert.equal(inline.schemaVersion,2);
  assert.equal(inline.structureOmitted,true);
  assert.equal(inline.strokes,undefined);
  assert.match(text,/원본 장면 전체를 읽으세요/);
  assert.deepEqual(fs.readFileSync(path.join(f.store,body.packetId,'scene.json')),
    Buffer.from(body.sceneJSONBase64,'base64'));
});

for (const [status,state] of [['idle','started'],['active','steered'],['notLoaded','queued']]) {
  test(`schema 2 ${status} fixed inbox preserves source, AI style and next-stroke revision`, {timeout:30000}, async t => {
    const f = fixture(t,status), value = scene(), body = packet(value);
    assert.equal(f.server.listening,false);
    assert.equal((await f.call('/packets','POST',body,false)).status,401);
    const target = await f.call('/inbox/target');
    assert.equal(target.body.sessionId,body.sessionId);
    assert.equal((await f.call(`/delivery/ready?threadId=${threadId}&targetMode=inbox`)).body.available,false);
    const saved = await f.call('/packets','POST',body);
    assert.equal(saved.status,201); assert.equal(saved.body.state,state);
    assert.equal(saved.body.sessionContinuity.status,'fixed-inbox-bound');
    assert.equal(saved.body.targetMode,'inbox');
    assert.equal(saved.body.sceneSha256,body.sceneSha256);
    assert.deepEqual((await f.call(`/packets/${body.packetId}/receipt`)).body,saved.body);
    const bytes = Buffer.from(body.sceneJSONBase64,'base64');
    const file = path.join(f.store,body.packetId,'scene.json');
    assert.deepEqual(fs.readFileSync(file),bytes);
    const dispatch = f.calls.find(c => ['turn/start','turn/steer','thread/queue/add'].includes(c.method));
    const text = dispatch.params.input[0].text;
    const inline = JSON.parse(text.split('\n구조 데이터(JSON): ')[1]);
    assert.equal(inline.schemaVersion,2);
    assert.deepEqual(inline.penSettings,value.penSettings);
    assert.deepEqual(inline.strokes[0].style,value.strokes[0].style);
    assert.deepEqual(inline.strokes[0].visibility,value.strokes[0].visibility);
    assert.doesNotMatch(text,/opaque fixture|drawingBase64/);
    const revision = {sceneId:id,baseRevision:3,annotations:[],proposedNodes:[],
      setPenSettings:{expected:settings(),settings:{version:1,color:'yellow',width:2}}};
    assert.equal((await f.call(`/packets/${body.packetId}/revision`,'PUT',revision)).status,200);
    assert.deepEqual((await f.call(`/packets/${body.packetId}/revision`)).body,revision);
    assert.equal((await f.call(`/packets/${body.packetId}/revision`,'PUT',{...revision,baseRevision:2})).status,409);
    assert.deepEqual((await f.call(`/packets/${body.packetId}/revision`)).body,revision);
    assert.deepEqual((await f.call('/packets','POST',body)).body,saved.body);
    const alias = {...body,packetId:crypto.randomUUID()};
    assert.equal((await f.call('/packets','POST',alias)).body.canonicalPacketId,body.packetId);
    assert.deepEqual((await f.call(`/packets/${alias.packetId}/revision`)).body,revision);
    assert.equal(f.deliveries.length,1);
    assert.deepEqual(fs.readFileSync(file),bytes);
    const vaultBody = {revision:3,sceneJSONBase64:body.sceneJSONBase64,imagePNGBase64:body.imagePNGBase64,baseSha256:null};
    const vault = await f.call(`/vault/canvas?id=${id}`,'PUT',vaultBody);
    assert.equal(vault.status,200);
    assert.equal((await f.call(`/vault/canvas?id=${id}`)).body.sceneJSONBase64,body.sceneJSONBase64);
    assert.equal((await f.call(`/vault/canvas?id=${id}`,'PUT',vaultBody)).status,409);
    assert.equal((await f.call(`/vault/canvas?id=${id}`)).body.sceneJSONBase64,body.sceneJSONBase64);
  });
}
