'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {PassThrough} = require('node:stream');
const {createServer,parsePacket} = require('./server');
const {ObsidianVault} = require('./obsidian-vault');
const {deliverPacket} = require('./codex-delivery');

const MiB = 1024*1024;
const id = '11111111-1111-4111-8111-111111111111';
const threadId = '22222222-2222-4222-8222-222222222222';
const turnId = '33333333-3333-4333-8333-333333333333';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const scene = (schemaVersion = 2,revision = 3) => ({schemaVersion,id,revision,width:2048,height:1536,
  drawingBase64:'',strokes:[],nodes:[],links:[],annotations:[]});
const sceneBytes = (size,revision = 3,schemaVersion = 2) => {
  const bytes = Buffer.from(JSON.stringify(scene(schemaVersion,revision)));
  return Buffer.concat([bytes,Buffer.alloc(size-bytes.length,32)]);
};
function packet(bytes,image = png) {
  return {packetId:crypto.randomUUID(),threadId,sessionId:`inbox:${threadId}`,targetMode:'inbox',
    sceneJSONBase64:bytes.toString('base64'),sceneSha256:sha(bytes),
    imagePNGBase64:image.toString('base64'),imageSha256:sha(image)};
}
function sizedPNG(size) {
  const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
  const data = Buffer.concat([Buffer.from('tEXtComment\0'),Buffer.alloc(size-png.length-20,97)]);
  length.writeUInt32BE(data.length-4);
  let crc = -1;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  checksum.writeUInt32BE((crc ^ -1) >>> 0);
  const result = Buffer.concat([png.subarray(0,-12),length,data,checksum,png.subarray(-12)]);
  assert.equal(result.length,size);
  return result;
}
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-limits-'));
  const vaultRoot = path.join(root,'vault'), store = path.join(root,'packets');
  fs.mkdirSync(vaultRoot);
  const calls = [];
  const token = 'isolated-canvas-limits-test-token';
  const server = createServer({store,vaultRoot,token,inboxThreadId:threadId,
    snapshotPath:path.join(root,'absent-snapshot'),hiddenPath:path.join(root,'absent-policy'),
    controlEvents:{socketPath:path.join(root,'absent-events.sock'),subscribePolicy:() => () => {}},
    deliveryReady:() => false,
    deliver:(value,before) => deliverPacket(value,async (method,params) => {
      calls.push({method,params});
      if (method === 'thread/read') return {thread:{id:threadId,status:{type:'idle'},canAcceptDirectInput:true}};
      if (method === 'turn/start') return {turn:{id:turnId}};
      assert.fail(`unexpected fixture RPC ${method}`);
    },before)});
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root,{recursive:true,force:true});
  });
  const call = (url,method = 'GET',body,authorized = true) => new Promise(resolve => {
    const request = new PassThrough();
    Object.assign(request,{url,method,headers:authorized ? {'x-canvas-token':token} : {}});
    const response = {writeHead(status) { this.status = status; },
      end(value) { resolve({status:this.status,body:JSON.parse(value),destroyed:request.destroyed}); }};
    server.emit('request',request,response);
    const bytes = Buffer.from(body === undefined ? '' : JSON.stringify(body));
    for (let offset = 0; offset < bytes.length && !request.destroyed; offset += 64*1024)
      request.write(bytes.subarray(offset,offset+64*1024));
    request.end();
  });
  return {root,vaultRoot,store,server,call,calls};
}
function vaultBody(bytes,image = png,baseSha256 = null) {
  return {revision:JSON.parse(bytes).revision,baseSha256,
    sceneJSONBase64:bytes.toString('base64'),imagePNGBase64:image.toString('base64')};
}

test('parser accepts exact 4 MiB schema 1 and 2 bytes and refuses the next byte', () => {
  for (const version of [1,2]) {
    const bytes = sceneBytes(4*MiB,3,version);
    assert.deepEqual(parsePacket(packet(bytes),threadId).scene,bytes);
    assert.throws(() => parsePacket(packet(Buffer.concat([bytes,Buffer.from(' ')])),threadId),/exceeds 4 MiB/);
  }
});

test('4 MiB scene and exact 5 MiB PNG persist, receipt GET and duplicate protection preserve bytes', async t => {
  const f = fixture(t), bytes = sceneBytes(4*MiB), image = sizedPNG(5*MiB), body = packet(bytes,image);
  assert.equal(f.server.listening,false);
  assert.equal((await f.call('/packets','POST',body,false)).status,401);
  assert.equal(fs.existsSync(path.join(f.store,body.packetId)),false);
  const received = await f.call('/packets','POST',body);
  assert.equal(received.status,201);
  assert.equal(received.body.state,'started');
  assert.equal(received.body.sceneSha256,sha(bytes));
  assert.deepEqual((await f.call(`/packets/${body.packetId}/receipt`)).body,received.body);
  assert.deepEqual((await f.call('/packets','POST',body)).body,received.body);
  const alias = {...body,packetId:crypto.randomUUID()};
  assert.equal((await f.call('/packets','POST',alias)).body.canonicalPacketId,body.packetId);
  assert.equal(f.calls.filter(c => c.method === 'turn/start').length,1);
  const conflict = {...body,sceneJSONBase64:sceneBytes(4*MiB,4).toString('base64'),sceneSha256:sha(sceneBytes(4*MiB,4))};
  assert.equal((await f.call('/packets','POST',conflict)).status,409);
  for (const bad of [packet(Buffer.concat([bytes,Buffer.from(' ')]),image),
    packet(bytes,sizedPNG(5*MiB+1)),{...packet(bytes,image),sceneSha256:'0'.repeat(64)}]) {
    assert.equal((await f.call('/packets','POST',bad)).status,409);
    assert.equal(fs.existsSync(path.join(f.store,bad.packetId)),false);
  }
  assert.deepEqual(fs.readFileSync(path.join(f.store,body.packetId,'scene.json')),bytes);
  assert.deepEqual(fs.readFileSync(path.join(f.store,body.packetId,'image.png')),image);
  assert.equal(f.calls.filter(c => c.method === 'turn/start').length,1);
});

test('Vault save, reopen, Mac memo CAS and GET accept 4 MiB assets and preserve failed originals', async t => {
  const f = fixture(t), bytes = sceneBytes(4*MiB), image = sizedPNG(5*MiB);
  const route = `/vault/canvas?id=${id}`, body = vaultBody(bytes,image);
  assert.equal((await f.call(route,'PUT',body,false)).status,401);
  assert.equal(fs.existsSync(path.join(f.vaultRoot,'CCR Canvas')),false);
  const saved = await f.call(route,'PUT',body);
  assert.equal(saved.status,200);
  const vault = new ObsidianVault(f.vaultRoot), reopened = vault.canvas(id);
  assert.equal(reopened.sceneJSONBase64,body.sceneJSONBase64);
  assert.equal((await f.call(route)).body.sceneJSONBase64,body.sceneJSONBase64);
  const note = vault.note(saved.body.path), macText = note.text + '\nMac 메모 e\u0301 🖊️\r\n';
  const mac = vault.save(note.path,note.sha256,macText);
  const next = sceneBytes(4*MiB,4);
  const assets = () => Object.fromEntries(fs.readdirSync(path.join(f.vaultRoot,'CCR Canvas','Assets'))
    .map(name => [name,sha(fs.readFileSync(path.join(f.vaultRoot,'CCR Canvas','Assets',name)))]));
  const originals = assets();
  for (const bad of [vaultBody(next,image,saved.body.noteSha256),
    vaultBody(Buffer.concat([bytes,Buffer.from(' ')]),image,mac.sha256),
    vaultBody(bytes,sizedPNG(5*MiB+1),mac.sha256)]) {
    assert.notEqual((await f.call(route,'PUT',bad)).status,200);
    assert.equal(vault.note(note.path).text,macText);
    assert.deepEqual(assets(),originals);
    assert.equal((await f.call(route)).body.sceneJSONBase64,body.sceneJSONBase64);
  }
  assert.equal((await f.call(route,'PUT',vaultBody(next,image,mac.sha256))).status,200);
  const final = (await f.call(route)).body;
  assert.equal(final.sceneJSONBase64,next.toString('base64'));
  assert.equal(final.revision,4);
  assert.equal(new ObsidianVault(f.vaultRoot).canvas(id).sceneSha256,sha(next));
  assert.equal(vault.note(note.path).text.endsWith('\nMac 메모 e\u0301 🖊️\r\n'),true);
  assert.deepEqual(fs.readFileSync(path.join(f.vaultRoot,'CCR Canvas','Assets',`${id}-${sha(image)}.png`)),image);
});

test('only Canvas POST and PUT accept exact 13 MiB envelopes and reject one extra byte', async t => {
  const f = fixture(t), bytes = sceneBytes(4*MiB), image = sizedPNG(5*MiB);
  for (const [route,method,body] of [['/packets','POST',packet(bytes,image)],
    [`/vault/canvas?id=${id}`,'PUT',vaultBody(bytes,image)]]) {
    const bounded = {...body,padding:''};
    bounded.padding = 'x'.repeat(13*MiB-Buffer.byteLength(JSON.stringify(bounded)));
    assert.equal(Buffer.byteLength(JSON.stringify(bounded)),13*MiB);
    const accepted = await f.call(route,method,bounded);
    assert.equal(accepted.status,method === 'POST' ? 201 : 200);
    const rejected = await f.call(route,method,{...bounded,padding:bounded.padding+'x'});
    assert.equal(rejected.status,409);
    assert.equal(rejected.body.error,'Request too large');
    assert.equal(rejected.destroyed,true);
  }
  assert.equal((await f.call(`/vault/canvas?id=${id}`)).body.sceneJSONBase64,bytes.toString('base64'));
});

test('Vault reopening refuses hash-matched JSON over 4 MiB and PNG over 5 MiB without repair', t => {
  const f = fixture(t), vault = new ObsidianVault(f.vaultRoot);
  const bytes = sceneBytes(4*MiB), image = sizedPNG(5*MiB);
  const saved = vault.saveCanvas(id,3,bytes,image,null), note = vault.note(saved.path);
  for (const [extension,original,oversized] of [['json',bytes,Buffer.concat([bytes,Buffer.from(' ')])],
    ['png',image,sizedPNG(5*MiB+1)]]) {
    const asset = path.join(f.vaultRoot,'CCR Canvas','Assets',`${id}-${sha(oversized)}.${extension}`);
    fs.writeFileSync(asset,oversized);
    const changed = note.text.replaceAll(sha(original),sha(oversized));
    fs.writeFileSync(path.join(f.vaultRoot,note.path),changed);
    assert.throws(() => vault.canvas(id),{status:409});
    assert.throws(() => vault.saveCanvas(id,3,bytes,image,sha(Buffer.from(changed))),{status:409});
    assert.equal(fs.readFileSync(path.join(f.vaultRoot,note.path),'utf8'),changed);
    assert.deepEqual(fs.readFileSync(asset),oversized);
    fs.writeFileSync(path.join(f.vaultRoot,note.path),note.text);
  }
  assert.equal(vault.canvas(id).sceneSha256,sha(bytes));
});

test('ordinary notes and Canvas Markdown memos retain inclusive 1 MiB UTF-8 limits', async t => {
  const f = fixture(t), vault = new ObsidianVault(f.vaultRoot), text = '한'+'a'.repeat(MiB-3);
  const route = '/vault/note?path=limit.md';
  const saved = await f.call(route,'PUT',{baseSha256:null,text});
  assert.equal(saved.status,200);
  assert.equal((await f.call(route)).body.text,text);
  assert.equal((await f.call(route,'PUT',{baseSha256:saved.body.sha256,text:text+'x'})).status,413);
  assert.equal(vault.note('limit.md').text,text);
  const huge = await f.call(route,'PUT',{baseSha256:saved.body.sha256,text:'x'.repeat(MiB+4096)});
  assert.equal(huge.body.error,'Request too large');
  const bytes = sceneBytes(4*MiB);
  const canvas = vault.saveCanvas(id,3,bytes,png,null), note = vault.note(canvas.path);
  const memo = note.text + 'm'.repeat(MiB-Buffer.byteLength(note.text));
  const atLimit = vault.save(note.path,note.sha256,memo);
  assert.equal(vault.canvas(id).noteSha256,atLimit.sha256);
  assert.throws(() => vault.save(note.path,atLimit.sha256,memo+'x'),{status:413});
  assert.equal(vault.note(note.path).text,memo);
  fs.appendFileSync(path.join(f.vaultRoot,note.path),'x');
  assert.throws(() => vault.canvas(id),{status:413});
  assert.throws(() => vault.saveCanvas(id,3,bytes,png,atLimit.sha256),{status:413});
  assert.equal(fs.readFileSync(path.join(f.vaultRoot,note.path),'utf8'),memo+'x');
});

test('packet revision HTTP remains capped at 1 MiB with stale revision protection', async t => {
  const f = fixture(t), body = packet(sceneBytes(4*MiB));
  assert.equal((await f.call('/packets','POST',body)).body.state,'started');
  const route = `/packets/${body.packetId}/revision`;
  const revision = {sceneId:id,baseRevision:3,annotations:[],proposedNodes:[]};
  assert.equal((await f.call(route,'PUT',revision)).status,200);
  assert.equal((await f.call(route,'PUT',{...revision,baseRevision:2})).status,409);
  const tooLarge = await f.call(route,'PUT',{...revision,padding:'x'.repeat(MiB)});
  assert.equal(tooLarge.body.error,'Request too large');
  assert.deepEqual((await f.call(route)).body,revision);
});

test('4 MiB native projection omits AI structure over 64 KiB and keeps original file read contract', async t => {
  const f = fixture(t), value = scene();
  value.drawingBase64 = Buffer.from('synthetic opaque native').toString('base64');
  value.strokes = [{id:turnId,points:Array.from({length:3000},(_,x) => ({x,y:0,pressure:0.5}))}];
  const initial = Buffer.from(JSON.stringify(value));
  const bytes = Buffer.concat([initial,Buffer.alloc(4*MiB-initial.length,32)]), body = packet(bytes);
  assert.equal((await f.call('/packets','POST',body)).body.state,'started');
  const text = f.calls.find(c => c.method === 'turn/start').params.input[0].text;
  const inline = JSON.parse(text.split('\n구조 데이터(JSON): ')[1]);
  assert.equal(inline.structureOmitted,true);
  assert.equal(inline.schemaVersion,2);
  assert.equal(inline.strokes,undefined);
  assert.match(text,/원본 장면 전체를 읽으세요/);
  assert.ok(text.includes(path.join(f.store,body.packetId,'scene.json')));
  assert.doesNotMatch(text,/drawingBase64|synthetic opaque native/);
  assert.deepEqual(fs.readFileSync(path.join(f.store,body.packetId,'scene.json')),bytes);
});

test('isolated loopback HTTP accepts both Canvas routes through 13 MiB and bounds overflow', async t => {
  const f = fixture(t), bytes = sceneBytes(4*MiB), image = sizedPNG(5*MiB);
  await new Promise(resolve => f.server.listen(0,'127.0.0.1',resolve));
  const port = f.server.address().port;
  assert.ok(![8791,8793].includes(port));
  t.diagnostic(`isolated-loopback-port=${port}`);
  const headers = {'x-canvas-token':'isolated-canvas-limits-test-token','content-type':'application/json'};
  const base = `http://127.0.0.1:${port}`;
  for (const [route,method,body] of [['/packets','POST',packet(bytes,image)],
    [`/vault/canvas?id=${id}`,'PUT',vaultBody(bytes,image)]]) {
    const bounded = {...body,padding:''};
    bounded.padding = 'x'.repeat(13*MiB-Buffer.byteLength(JSON.stringify(bounded)));
    const accepted = await fetch(base+route,{method,headers,body:JSON.stringify(bounded)});
    assert.equal(accepted.status,method === 'POST' ? 201 : 200);
    const receipt = await accepted.json();
    assert.equal(receipt.sceneSha256,sha(bytes));
    let refused = false;
    try {
      const response = await fetch(base+route,{method,headers,
        body:JSON.stringify({...bounded,padding:bounded.padding+'x'})});
      assert.equal(response.status,409);
      assert.equal((await response.json()).error,'Request too large');
      refused = true;
    } catch (error) {
      if (!(error instanceof TypeError) || error.message !== 'fetch failed') throw error;
      refused = true;
    }
    assert.equal(refused,true);
    const readRoute = method === 'POST' ? `/packets/${body.packetId}/receipt` : route;
    const read = await (await fetch(base+readRoute,{headers})).json();
    assert.equal(read.sceneSha256,sha(bytes));
  }
  const address = f.server.address();
  f.server.closeAllConnections();
  await new Promise(resolve => f.server.close(resolve));
  assert.equal(f.server.listening,false);
  assert.equal(address.port,port);
  await assert.rejects(fetch(base+`/vault/canvas?id=${id}`,{headers}),TypeError);
  t.diagnostic(`isolated-loopback-port=${port} closed-and-unreachable`);
});
