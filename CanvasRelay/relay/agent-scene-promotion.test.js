'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {PassThrough} = require('node:stream');
const {createServer} = require('./server');
const {assertAgentRevision} = require('./canvas-scene');
const source = require('./test-input/scene3-promotion/original-scene2.json');
const proposal = require('./test-input/scene3-promotion/remote-line-revision.json');
const applied = require('./test-input/scene3-promotion/locally-applied-scene3.json');

function fixture(t,version) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'agent-promotion-'));
  const id = crypto.randomUUID(),token = 'isolated-agent-promotion-fixture-token';
  const scene = {...source,schemaVersion:version},sceneFile = path.join(root,id+'.json');
  const raw = Buffer.from(JSON.stringify(scene));fs.writeFileSync(sceneFile,raw);
  fs.writeFileSync(path.join(root,id+'.receipt.json'),'{}');
  const revisionFile = path.join(root,id+'.revision.json');fs.writeFileSync(revisionFile,'{"prior":true}');
  const server = createServer({store:root,token,hiddenPath:path.join(root,'absent'),
    snapshotPath:path.join(root,'absent'),deliveryReady:() => false,
    deliver:() => assert.fail('실제 발송 금지')});
  t.after(() => server.close());
  const put = body => new Promise(resolve => {
    const request = new PassThrough();Object.assign(request,{url:'/packets/'+id+'/revision',method:'PUT',headers:{'x-canvas-token':token}});
    server.emit('request',request,{writeHead(status) { this.status = status; },end(bytes) { resolve({status:this.status,body:JSON.parse(bytes)}); }});
    request.end(JSON.stringify(body));
  });
  return {put,sceneFile,revisionFile,raw};
}

for (const version of [1,2,3]) for (const kind of ['line','ellipse']) {
  test(`실제 Swift 제안 ${kind}를 scene${version}에서 허용하고 원본 packet은 그대로 둔다`, async t => {
    const f = fixture(t,version),body = structuredClone(proposal);body.proposedNodes[0].kind = kind;
    const result = await f.put(body);
    assert.equal(result.status,200);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.revisionFile)),body);
    assert.deepEqual(fs.readFileSync(f.sceneFile),f.raw);
    assert.equal(JSON.parse(f.raw).schemaVersion,version);
    assert.equal(applied.schemaVersion,3);
    assert.equal(applied.nodes.find(n => n.id === proposal.proposedNodes[0].id).kind,'line');
  });
}

for (const version of [1,2,3]) {
  test(`scene${version}의 unknown 종류·잘못된 제안은 기존 원본과 revision을 보존한다`, async t => {
    const f = fixture(t,version);
    for (const change of [b => b.proposedNodes[0].kind = 'future',b => b.proposedNodes[0].frame.x = '12',
      b => b.proposedNodes.push({...b.proposedNodes[0],kind:'unknown'}),
      b => { b.proposedNodes = [];b.nodeEdits = [{expected:{...proposal.proposedNodes[0],kind:'future'},text:'수정'}]; }]) {
      const body = structuredClone(proposal);change(body);
      assert.equal((await f.put(body)).status,409);
      assert.equal(fs.readFileSync(f.revisionFile,'utf8'),'{"prior":true}');
      assert.deepEqual(fs.readFileSync(f.sceneFile),f.raw);
    }
  });
}

test('canonical 승격은 검증된 새 도형 제안에만 적용하며 기존 잉크와 입력을 바꾸지 않는다', () => {
  for (const version of [1,2,3]) {
    const scene = {...source,schemaVersion:version};
    if (version >= 2) {
      scene.drawingBase64 = 'bmF0aXZlLWZpeHR1cmU=';
      scene.penSettings = {version:1,color:'cyan',width:4};
      scene.strokes = [{id:crypto.randomUUID(),points:[{x:1,y:2,pressure:0.5}],style:{version:1,inkType:'pen',
        transform:{a:1,b:0,c:0,d:1,tx:0,ty:0},samples:[{width:4,height:4,opacity:1}]}}];
    }
    const before = Buffer.from(JSON.stringify(scene)),body = structuredClone(proposal);
    assert.equal(assertAgentRevision(scene,body),3);
    assert.deepEqual(Buffer.from(JSON.stringify(scene)),before);
    body.proposedNodes[0].kind = 'note';
    assert.equal(assertAgentRevision(scene,body),version);
    body.proposedNodes = [];
    assert.equal(assertAgentRevision(scene,body),version);
  }
  for (const version of [0,4,'3',null])
    assert.throws(() => assertAgentRevision({...source,schemaVersion:version},proposal));
});
