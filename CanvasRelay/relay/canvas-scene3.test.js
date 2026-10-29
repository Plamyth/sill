'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {PassThrough} = require('node:stream');
const {assertInkScene} = require('./canvas-scene');
const {canvasMermaid,canvasDiagramMarkdown} = require('./canvas-diagram');
const {ObsidianVault} = require('./obsidian-vault');
const {createServer,parsePacket} = require('./server');

const id = '11111111-1111-4111-8111-111111111111';
const a = '22222222-2222-4222-8222-222222222222';
const b = '33333333-3333-4333-8333-333333333333';
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const bytes = value => Buffer.from(JSON.stringify(value));
const node = (id,kind,text,x) => ({id,kind,text,confidence:'confirmed',sourceStrokeIds:[],
  frame:{x,y:20,width:50,height:30}});
const scene = (version = 3) => ({schemaVersion:version,id,revision:1,width:200,height:100,
  drawingBase64:'',strokes:[],nodes:[node(a,'note','기존 메모',10),node(b,'box','기존 상자',70)],
  links:[],annotations:[]});
const shapes = () => {
  const value = scene();
  value.nodes[0].kind = 'ellipse';
  value.nodes[0].rotationDegrees = -27.5;
  value.nodes[0].sourceStrokeIds = [id];
  value.nodes[1].kind = 'line';
  value.futureField = {untouched:'한글 e\u0301'};
  return value;
};

function fixture(t,{configuredVault = true} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'scene3-'));
  const vaultRoot = path.join(root,'vault'),store = path.join(root,'packets');
  fs.mkdirSync(vaultRoot);
  const token = 'synthetic-scene3-test-token-only';
  const server = createServer({store,vaultRoot:configuredVault ? vaultRoot : '',token,deliveryReady:() => false,
    snapshotPath:path.join(root,'absent'),hiddenPath:path.join(root,'absent'),
    deliver:() => assert.fail('실제 발송 경로는 호출하지 않는다')});
  const call = (url,method = 'GET',body,authorized = true) => new Promise(resolve => {
    const request = new PassThrough();
    Object.assign(request,{url,method,headers:authorized ? {'x-canvas-token':token} : {}});
    const response = {writeHead(status) { this.status = status; },
      end(value) { resolve({status:this.status,body:JSON.parse(value)}); }};
    server.emit('request',request,response);
    request.end(body === undefined ? '' : JSON.stringify(body));
  });
  t.after(() => server.close());
  return {root,vaultRoot,store,call,vault:new ObsidianVault(vaultRoot)};
}

function packet(value) {
  const source = bytes(value);
  return {schemaVersion:1,packetId:crypto.randomUUID(),threadId:a,
    sessionId:'synthetic-session',sceneSha256:sha(source),imageSha256:sha(png),
    sceneJSONBase64:source.toString('base64'),imagePNGBase64:png.toString('base64')};
}

test('packet1과 scene3을 구분하고 종류·기하 정보·잉크를 원문 그대로 읽는다', () => {
  const value = shapes();
  value.drawingBase64 = 'bmF0aXZl';
  value.penSettings = {version:1,color:'cyan',width:4};
  value.strokes = [{points:[{x:1,y:2,pressure:0.5}],style:{version:1,inkType:'pen',
    transform:{a:1,b:0,c:0,d:1,tx:0,ty:0},samples:[{width:4,height:4,opacity:1}]}}];
  const source = bytes(value);
  assert.doesNotThrow(() => assertInkScene(value));
  assert.deepEqual(parsePacket(packet(value)).scene,source);
  const invalid = structuredClone(value);
  invalid.strokes[0].style.samples[0].opacity = 2;
  assert.throws(() => assertInkScene(invalid),/ink projection/);
  assert.deepEqual(bytes(value),source);
});

test('1·2는 기존 note·box만 허용하고 미지원 버전·종류·기하 정보는 거부한다', () => {
  for (const version of [1,2]) {
    assert.doesNotThrow(() => parsePacket(packet(scene(version))));
    const invalid = shapes();invalid.schemaVersion = version;
    assert.throws(() => parsePacket(packet(invalid)),/요소 종류/);
    assert.equal(canvasMermaid(invalid),null);
  }
  for (const change of [s => s.schemaVersion = 4,s => s.schemaVersion = null,s => delete s.schemaVersion,
    s => s.nodes[0].kind = 'future',s => s.nodes[0].frame.x = '12',
    s => s.nodes[0].frame = null,s => s.nodes[0].rotationDegrees = '90',
    s => s.nodes[0].rotationDegrees = Number.MAX_VALUE,
    s => { s.nodes[0].frame.x = Number.MAX_VALUE;s.nodes[0].frame.width = Number.MAX_VALUE; }]) {
    const value = shapes();change(value);
    const original = bytes(value);
    assert.throws(() => parsePacket(packet(value)));
    assert.deepEqual(bytes(value),original);
  }
});

test('scene3 JSON·Markdown·PNG를 격리 파일에 저장하고 재열기·편집·충돌을 확인한다', async t => {
  const f = fixture(t),value = shapes(),source = bytes(value);
  const body = {revision:1,baseSha256:null,sceneJSONBase64:source.toString('base64'),
    imagePNGBase64:png.toString('base64')};
  const first = await f.call('/vault/canvas?id='+id,'PUT',body);
  assert.equal(first.status,200);
  const loaded = await f.call('/vault/canvas?id='+id);
  assert.equal(loaded.status,200);
  assert.deepEqual(Buffer.from(loaded.body.sceneJSONBase64,'base64'),source);
  assert.deepEqual(fs.readFileSync(path.join(f.vaultRoot,'CCR Canvas/Assets',id+'-'+sha(png)+'.png')),png);
  const markdown = f.vault.note(first.body.path).text;
  for (const shape of value.nodes) {
    assert.ok(markdown.includes(JSON.stringify({kind:shape.kind,frame:shape.frame,
      ...(shape.rotationDegrees != null ? {rotationDegrees:shape.rotationDegrees} : {})})));
  }
  assert.ok(markdown.includes('### 타원') && markdown.includes('### 선'));
  assert.ok(markdown.includes('```mermaid') && markdown.includes('자동 배치 모드'));
  assert.ok(!source.toString('utf8').includes('x'+b.replaceAll('-','')));
  assert.deepEqual(JSON.parse(source).nodes[0].sourceStrokeIds,[id]);
  const memo = f.vault.save(first.body.path,first.body.noteSha256,markdown+'\n사용자 메모\n');
  value.revision = 2;value.nodes[0].text = '재편집한 타원';
  const next = f.vault.saveCanvas(id,2,bytes(value),png,memo.sha256);
  assert.equal(JSON.parse(Buffer.from(f.vault.canvas(id).sceneJSONBase64,'base64')).schemaVersion,3);
  assert.ok(f.vault.note(next.path).text.endsWith('사용자 메모\n'));
  assert.throws(() => f.vault.saveCanvas(id,2,bytes(value),png,memo.sha256),/changed on Mac/);
  const downgraded = scene(2);downgraded.revision = 3;
  assert.throws(() => f.vault.saveCanvas(id,3,bytes(downgraded),png,next.noteSha256),/이전 버전/);
  assert.equal(f.vault.note(next.path).sha256,next.noteSha256);
  assert.equal(new ObsidianVault(f.vaultRoot).canvas(id).sceneSha256,sha(bytes(value)));
});

test('알 수 없는 저장 형식을 거부하며 마지막 정상 파일과 미지원 원본을 보존한다', async t => {
  const f = fixture(t),value = shapes();
  const first = f.vault.saveCanvas(id,1,bytes(value),png,null);
  const names = fs.readdirSync(path.join(f.vaultRoot,'CCR Canvas/Assets'));
  for (const change of [s => s.schemaVersion = 9,s => s.nodes[1].kind = 'future']) {
    const unsupported = shapes();change(unsupported);
    const original = bytes(unsupported);
    const result = await f.call('/vault/canvas?id='+id,'PUT',{revision:1,
      baseSha256:first.noteSha256,sceneJSONBase64:original.toString('base64'),imagePNGBase64:png.toString('base64')});
    assert.equal(result.status,400);
    assert.equal(f.vault.note(first.path).sha256,first.noteSha256);
    assert.deepEqual(fs.readdirSync(path.join(f.vaultRoot,'CCR Canvas/Assets')),names);
    assert.deepEqual(bytes(unsupported),original);
  }
  const original = bytes({...value,schemaVersion:8}),hash = sha(original);
  const asset = path.join(f.vaultRoot,'CCR Canvas/Assets',id+'-'+hash+'.json');
  fs.writeFileSync(asset,original);
  const old = f.vault.note(first.path);
  f.vault.save(first.path,old.sha256,old.text.replaceAll(first.sceneSha256,hash));
  const before = f.vault.note(first.path).sha256;
  assert.equal((await f.call('/vault/canvas?id='+id)).status,409);
  assert.deepEqual(fs.readFileSync(asset),original);
  assert.equal(f.vault.note(first.path).sha256,before);
});

test('기존 1·2 note·box Markdown의 SHA는 원본 릴레이 결과와 같다', t => {
  const f = fixture(t);
  const expected = {1:'243831633f37d5176f0e470e3c6de5380e8341dd3b6eae4c187eecf088ce3a71',
    2:'8ad9eb53201f0fa9af970fa9ff876fb4392cd4204465bfea2e5251cfe05444ee'};
  for (const version of [1,2]) {
    const directory = path.join(f.root,'legacy-'+version);fs.mkdirSync(directory);
    const result = new ObsidianVault(directory).saveCanvas(id,1,bytes(scene(version)),Buffer.from('original png fixture'),null);
    assert.equal(result.noteSha256,expected[version]);
  }
});

test('합의한 타원 class와 보이지 않는 두 끝점 사이 실제 직선을 정확히 투영한다', () => {
  const value = shapes(),original = bytes(value);
  const n = id => 'n'+id.replaceAll('-','');
  const x = 'x'+b.replaceAll('-','');
  value.links = [{id,from:a,to:b,kind:'arrow',label:'관계'}];
  const expected = ['flowchart TD',`${n(a)}["기존 메모"]`,`class ${n(a)} ccrEllipse`,
    `${n(b)}[" "]`,`${x}[" "]`,`${n(b)} ---|"기존 상자"| ${x}`,
    `class ${n(b)},${x} ccrLineEndpoint`,'classDef ccrEllipse rx:50%,ry:50%',
    'classDef ccrLineEndpoint fill:none,stroke:none',`${n(a)} -->|"관계"| ${n(b)}`].join('\n');
  assert.equal(canvasMermaid(value),expected);
  assert.ok(canvasDiagramMarkdown(value).includes('ccr.diagram-shapes/v1'));
  assert.ok(canvasDiagramMarkdown(value).includes('자동 배치 모드'));
  assert.equal(canvasMermaid(scene(2)).includes('classDef'),false);
  value.nodes[0].text = '';value.nodes[1].text = '';
  assert.match(canvasMermaid(value),/이름 없는 요소/);
  assert.match(canvasMermaid(value),/---\|"직선"\|/);
  value.nodes[0].text = '\nclassDef injected fill:red';
  assert.equal(canvasMermaid(value).includes('\nclassDef injected'),false);
  assert.ok(canvasMermaid(value).includes('#10;classDef injected fill#58;red'));
  const originalValue = JSON.parse(original);
  assert.equal(originalValue.nodes.length,2);
  assert.equal(originalValue.nodes[1].kind,'line');
});

test('접힌 선의 표시 끝점과 class를 생성하지 않고 원본 데이터는 보존한다', () => {
  const value = shapes();value.nodes[0].kind = 'box';value.nodes[0].isCollapsed = true;
  value.links = [{id,from:a,to:b,kind:'parentChild',label:''}];
  const before = bytes(value),source = canvasMermaid(value);
  assert.equal(source,'flowchart TD\nn'+a.replaceAll('-','')+'["기존 메모"]');
  assert.deepEqual(bytes(value),before);
});

test('표시 전용 선 끝점도 노드 한도에 포함하고 원본 wire를 늘리지 않는다', () => {
  const value = scene();
  value.nodes = Array.from({length:511},() => node(crypto.randomUUID(),'box','',0));
  value.nodes[0].kind = 'line';
  const before = bytes(value);
  assert.notEqual(canvasMermaid(value),null);
  assert.deepEqual(bytes(value),before);
  value.nodes.push(node(crypto.randomUUID(),'box','',0));
  assert.equal(canvasMermaid(value),null);
});

test('실제 Swift writer의 scene3 fixture와 Mermaid UTF-8 바이트가 일치하고 파일 왕복한다', t => {
  const f = fixture(t),root = path.join(__dirname,'test-input/scene3-projection');
  const source = fs.readFileSync(path.join(root,'projection-scene.json'));
  const value = JSON.parse(source);
  const snapshot = JSON.parse(fs.readFileSync(path.join(root,'projection-snapshot.json')));
  const provenance = JSON.parse(fs.readFileSync(path.join(root,'provenance.json')));
  for (const file of provenance.files) assert.equal(sha(fs.readFileSync(path.join(root,file.file))),file.sha256);
  assertInkScene(value);
  assert.deepEqual(Buffer.from(canvasMermaid(value),'utf8'),Buffer.from(snapshot.source,'utf8'));
  const saved = f.vault.saveCanvas(value.id,value.revision,source,png,null);
  const loaded = new ObsidianVault(f.vaultRoot).canvas(value.id);
  assert.deepEqual(Buffer.from(loaded.sceneJSONBase64,'base64'),source);
  const markdown = f.vault.note(saved.path).text;
  assert.ok(markdown.includes(snapshot.source));
  assert.ok(markdown.includes('자동 배치 모드'));
  assert.equal(value.nodes.length,snapshot.nodes.length);
  assert.deepEqual(value.nodes.map(n => n.kind),['line','box','ellipse']);
});

test('지정 capability endpoint는 기존 인증으로 정확한 계약을 반환한다', async t => {
  const f = fixture(t,{configuredVault:false});
  const route = '/vault/canvas/capabilities';
  assert.equal((await f.call(route,'GET',undefined,false)).status,401);
  const result = await f.call(route);
  assert.equal(result.status,200);
  const {document,...legacy}=result.body;
  assert.equal(document.schema,'ccr.vault-document/v1');assert.equal(document.wholeDocument,true);
  assert.deepEqual(legacy,{schema:'ccr.canvas-capabilities/v1',sceneSchemaVersions:[1,2,3],
    nodeKinds:['note','box','ellipse','line'],diagramProjection:'ccr.diagram-shapes/v1'});
  assert.deepEqual((await f.call('/delivery/ready')).body,{available:false});
});

test('agent 제안의 미지원 종류를 거부하고 scene3 원본과 기존 제안을 보존한다', async t => {
  const f = fixture(t),packetId = crypto.randomUUID(),value = shapes();
  const source = path.join(f.store,packetId+'.json');
  fs.writeFileSync(source,bytes(value));
  fs.writeFileSync(path.join(f.store,packetId+'.receipt.json'),'{}');
  const revision = path.join(f.store,packetId+'.revision.json');
  fs.writeFileSync(revision,'{"existing":true}');
  const before = fs.readFileSync(source);
  const body = {sceneId:id,baseRevision:1,annotations:[],proposedNodes:[{...value.nodes[0],kind:'future'}]};
  assert.equal((await f.call('/packets/'+packetId+'/revision','PUT',body)).status,409);
  assert.equal(fs.readFileSync(revision,'utf8'),'{"existing":true}');
  body.proposedNodes = [];
  body.nodeEdits = [{expected:{...value.nodes[0],kind:'future'},text:'수정'}];
  assert.equal((await f.call('/packets/'+packetId+'/revision','PUT',body)).status,409);
  assert.equal(fs.readFileSync(revision,'utf8'),'{"existing":true}');
  delete body.nodeEdits;
  body.proposedNodes = [value.nodes[0]];
  assert.equal((await f.call('/packets/'+packetId+'/revision','PUT',body)).status,200);
  assert.equal(JSON.parse(fs.readFileSync(revision)).proposedNodes[0].kind,'ellipse');
  assert.deepEqual(fs.readFileSync(source),before);
});
