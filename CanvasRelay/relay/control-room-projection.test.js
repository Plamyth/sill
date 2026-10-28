'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createServer} = require('./server');

const voiceId = '11111111-1111-4111-8111-111111111111';
const otherId = '22222222-2222-4222-8222-222222222222';
const missingId = '33333333-3333-4333-8333-333333333333';
const token = 'projection-test-token-at-least-24';

async function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'canvas-projection-'));
  const snapshotPath = path.join(dir,'snapshot.json');
  const hiddenPath = path.join(dir,'hidden-threads.json');
  fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids:[]}),{mode:0o600});
  const now = new Date().toISOString();
  const voice = {id:voiceId,slotIndex:2,voiceCard:true,title:'Actual voice title',titleVerified:true,
    available:true,source:'codex',status:'진행 중',turnStatus:'inProgress',provenance:'local-history',
    events:[{id:'event-1',ts:now,kind:'message',role:'user',text:'Observed transcript',source:'history',voiceSessionId:'session-1'}],
    project:'Voice project',projectId:'project-with-no-owner',
    latestProgress:{id:'progress-1',ts:now,kind:'progress',role:'assistant',text:'Canvas expansion running'},
    latestUser:{id:'user-1',ts:now,kind:'message',role:'user',text:'Show the canvas'},
    activeTools:['xcodebuild'],pendingTools:1,
    inputRequest:{kind:'approval',requestId:'request-1'},voiceState:{record:'start observed',sessionId:'session-1'},
    executions:[{id:'exec-1',status:'running',sourceThreadId:voiceId}]};
  const snapshot = {generatedAt:now,workspace:'all',activeVoiceId:voiceId,
    activeVoiceSession:{threadId:voiceId,sessionId:'session-1',observedAt:now},
    projects:[{id:'project-with-no-owner',label:'Empty project',projectKind:'codex'}],
    threads:[voice,{id:otherId,slotIndex:5,title:'Current unavailable',available:false,sourceMissing:true}],
    catalog:[{id:voiceId,available:true,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true},
      {id:otherId,available:true,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true},
      {id:missingId,available:false,source:'codex',hostId:'local',forkedFromId:null,forkLineageVerified:true}],
    mobile:{threads:[{id:otherId,title:'Older available history',available:true}],
      workspaces:[{id:'saved',label:'Saved layout',slots:[{kind:'voice',threadId:voiceId},
        {kind:'normal',threadId:otherId},{kind:'normal',threadId:missingId},
        {kind:'normal',threadId:'44444444-4444-4444-8444-444444444444'},
        {kind:'normal',threadId:null,projectId:'project-with-no-owner'}]}]}};
  const write = () => fs.writeFileSync(snapshotPath,JSON.stringify(snapshot));
  write();
  let sends = 0;
  const server = createServer({snapshotPath,hiddenPath,store:path.join(dir,'store'),token,
    deliver:async () => { sends++; }});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const root = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); fs.rmSync(dir,{recursive:true,force:true}); });
  const get = (secret = token, method = 'GET') => fetch(root+'/control-room/projection',{
    method,headers:{'x-canvas-token':secret}});
  const hide = ids => fs.writeFileSync(hiddenPath,JSON.stringify({version:1,ids}),{mode:0o600});
  return {snapshot,voice,write,get,hide,hiddenPath,sends:() => sends};
}

test('authenticated projection passes the owner catalog without changing iframe observations', async t => {
  const f = await fixture(t);
  const catalog = {schema:'ccr-test-destinations/v1',observedAt:f.snapshot.generatedAt,entries:[{
    id:'cargo-local',projectId:'project-with-no-owner',projectLabel:'카고24',label:'관리자 시험',
    url:'https://cargo.example.test/admin',owner:'fixture-owner',reachability:'reachable',
    embed:'blocked',checkedAt:f.snapshot.generatedAt,reason:'X-Frame-Options: SAMEORIGIN'}]};
  f.snapshot.testDestinations = catalog;
  f.write();
  assert.equal((await f.get('wrong-token')).status,401);
  const response = await f.get();
  assert.equal(response.status,200);
  assert.deepEqual((await response.json()).testDestinations,catalog);
  assert.equal(f.sends(),0);
});

test('projection distinguishes an absent catalog from a confirmed empty catalog', async t => {
  const f = await fixture(t);
  assert.equal(Object.hasOwn(await (await f.get()).json(),'testDestinations'),false);
  f.snapshot.testDestinations = {schema:'ccr-test-destinations/v1',
    observedAt:f.snapshot.generatedAt,entries:[]};
  f.write();
  assert.deepEqual((await (await f.get()).json()).testDestinations,f.snapshot.testDestinations);
});

test('catalog accepts omitted optional observation fields without inventing values', async t => {
  const f = await fixture(t);
  const entry = {id:'confirmed-local',projectId:'project-with-no-owner',projectLabel:'시험',
    label:'확인된 화면',url:'https://confirmed.example.test/',owner:'fixture-owner',
    reachability:'unknown',embed:'unknown'};
  for (const optional of [{},{checkedAt:null,reason:null},
    {checkedAt:f.snapshot.generatedAt,reason:'관측 완료'}]) {
    const catalog = {schema:'ccr-test-destinations/v1',
      observedAt:f.snapshot.generatedAt,entries:[{...entry,...optional}]};
    f.snapshot.testDestinations = catalog;
    f.write();
    assert.deepEqual((await (await f.get()).json()).testDestinations,catalog);
  }
  assert.equal(f.sends(),0);
});

test('projection rejects malformed catalogs and does not forward undeclared credentials', async t => {
  const f = await fixture(t);
  for (const value of [null,[],{}, {schema:'ccr-test-destinations/v2',entries:[]},
    {schema:'ccr-test-destinations/v1',observedAt:f.snapshot.generatedAt,entries:Array(257).fill({})}]) {
    f.snapshot.testDestinations = value;
    f.write();
    assert.deepEqual((await (await f.get()).json()).testDestinations, {schema:'ccr-test-destinations/v1',
      observedAt:f.snapshot.generatedAt,state:'malformed',entries:[]});
  }
  f.snapshot.testDestinations = {schema:'ccr-test-destinations/v1',
    observedAt:f.snapshot.generatedAt,entries:[],token:'must-not-leak'};
  f.write();
  const value = await (await f.get()).json();
  assert.deepEqual(value.testDestinations,{schema:'ccr-test-destinations/v1',
    observedAt:f.snapshot.generatedAt,entries:[]});
  assert.equal(JSON.stringify(value).includes('must-not-leak'),false);
});

test('catalog preserves explicit failure states without exposing rows or treating them as ready', async t => {
  const f = await fixture(t);
  for (const state of ['ready','unavailable','malformed']) {
    const catalog = {schema:'ccr-test-destinations/v1',observedAt:f.snapshot.generatedAt,state,entries:[]};
    f.snapshot.testDestinations = catalog;
    f.write();
    assert.deepEqual((await (await f.get()).json()).testDestinations,catalog);
  }
  for (const state of [null,0,{},'unknown']) {
    f.snapshot.testDestinations = {schema:'ccr-test-destinations/v1',observedAt:f.snapshot.generatedAt,state,entries:[]};
    f.write();
    assert.equal((await (await f.get()).json()).testDestinations.state,'malformed');
  }
  f.snapshot.testDestinations = {schema:'ccr-test-destinations/v1',observedAt:f.snapshot.generatedAt,
    state:'unavailable',entries:[{token:'must-not-leak'}],token:'must-not-leak'};
  f.write();
  const value = (await (await f.get()).json()).testDestinations;
  assert.equal(value.state,'malformed');
  assert.deepEqual(value.entries,[]);
  assert.equal(JSON.stringify(value).includes('must-not-leak'),false);
});

test('catalog forwards only bounded exact HTTPS redirect origins', async t => {
  const f = await fixture(t);
  const entry = {id:'confirmed-local',projectId:'project-with-no-owner',projectLabel:'시험',
    label:'확인된 화면',url:'https://confirmed.example.test/',owner:'fixture-owner',
    reachability:'reachable',embed:'unknown',redirectOrigins:['https://login.example.test']};
  const catalog = {schema:'ccr-test-destinations/v1',
    observedAt:f.snapshot.generatedAt,entries:[entry]};
  f.snapshot.testDestinations = catalog;
  f.write();
  assert.deepEqual((await (await f.get()).json()).testDestinations,catalog);
  for (const invalid of [null,'https://login.example.test',Array(9).fill('https://login.example.test'),
    ['http://login.example.test'],['https://user:secret@login.example.test'],
    ['https://login.example.test/path'],['https://login.example.test/?secret=1']]) {
    entry.redirectOrigins = invalid;
    f.write();
    assert.deepEqual((await (await f.get()).json()).testDestinations, {schema:'ccr-test-destinations/v1',
      observedAt:f.snapshot.generatedAt,state:'malformed',entries:[]});
  }
  assert.equal(f.sends(),0);
});

test('PC hidden file conceals the current voice card and saved copies without leaking content', async t => {
  const f = await fixture(t);
  f.hide([voiceId]);
  const value = await (await f.get()).json();
  assert.equal(value.activeVoiceId,null);
  assert.equal(value.activeVoiceSession,null);
  assert.equal(value.voiceCard,null);
  for (const slot of [value.currentGrid[2],value.workspaces[0].slots[0]]) {
    assert.equal(slot.threadId,null);
    assert.equal(slot.card,null);
    assert.equal(slot.unavailableReason,'hidden');
  }
  assert.equal(JSON.stringify(value).includes('Actual voice title'),false);
  assert.equal(JSON.stringify(value).includes('Observed transcript'),false);
  assert.equal(f.sends(),0);
});

test('a hidden current row cannot reappear from saved mobile history', async t => {
  const f = await fixture(t);
  f.snapshot.threads[0].hidden = true;
  f.snapshot.mobile.threads.push({...f.voice});
  f.write();
  const value = await (await f.get()).json();
  assert.equal(value.activeVoiceId,null);
  assert.equal(value.voiceCard,null);
  assert.equal(value.workspaces[0].slots[0].card,null);
  assert.equal(value.workspaces[0].slots[0].threadId,null);
  assert.equal(value.workspaces[0].slots[0].unavailableReason,'hidden');
  assert.equal(JSON.stringify(value).includes('Observed transcript'),false);
});

for (const source of ['catalog','current row']) {
  test(`mixed-case hidden ${source} ID conceals a lowercase voice and saved card`, async t => {
    const f = await fixture(t);
    const id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    f.snapshot.activeVoiceId = id;
    f.snapshot.activeVoiceSession.threadId = id;
    f.snapshot.threads[0].id = source === 'current row' ? id.toUpperCase() : id;
    f.snapshot.catalog[0].id = source === 'catalog' ? id.toUpperCase() : id;
    f.snapshot[source === 'catalog' ? 'catalog' : 'threads'][0].hidden = true;
    f.snapshot.mobile.workspaces[0].slots[0].threadId = id;
    f.snapshot.mobile.threads.push({...f.voice,id});
    f.write();
    const value = await (await f.get()).json();
    assert.equal(value.activeVoiceId,null);
    assert.equal(value.activeVoiceSession,null);
    assert.equal(value.currentGrid[2].card,null);
    assert.equal(value.workspaces[0].slots[0].card,null);
    assert.equal(JSON.stringify(value).includes('Observed transcript'),false);
  });
}

test('empty project slots retain carousel identity without inventing a conversation', async t => {
  const f = await fixture(t);
  f.snapshot.threads.push({emptySlot:true,slotIndex:4,carouselProjectId:'project-with-no-owner'});
  f.write();
  const value = await (await f.get()).json();
  assert.equal(value.projects[0].label,'Empty project');
  assert.equal(value.currentGrid[4].kind,'project');
  assert.equal(value.currentGrid[4].carouselProjectId,'project-with-no-owner');
  assert.equal(value.currentGrid[4].projectId,null);
  assert.equal(value.currentGrid[4].threadId,null);
  assert.equal(value.workspaces[0].slots[4].projectId,'project-with-no-owner');
  assert.equal(value.workspaces[0].slots[4].threadId,null);
});

test('prefixed local and ChatGPT projects keep separate read-only identities', async t => {
  const f = await fixture(t);
  f.snapshot.chatgptProjects = [{id:'g-p-chatgpt',label:'카고24_기획',displayLabel:'기획',projectKind:'chatgpt'}];
  f.snapshot.chatgptProjectState = 'cached';
  f.snapshot.sections = [{id:'project-prefix-cargo24',kind:'project-prefix',label:'카고24',prefix:'카고24',
    projectIds:['project-with-no-owner'],chatgptProjectIds:['g-p-chatgpt']}];
  f.snapshot.mobile.workspaces.push({id:'project-prefix-cargo24',kind:'project-prefix',label:'카고24',
    prefix:'카고24',projectIds:['project-with-no-owner'],chatgptProjectIds:['g-p-chatgpt'],
    slots:[{kind:'project',threadId:null,projectId:'project-with-no-owner'},
      {kind:'project',threadId:null,chatgptProjectId:'g-p-chatgpt'}]});
  f.write();
  const value = await (await f.get()).json();
  assert.equal(value.sections[0].kind,'project-prefix');
  assert.equal(value.chatgptProjects[0].label,'카고24_기획');
  assert.equal(value.chatgptProjects[0].displayLabel,'기획');
  assert.equal(value.chatgptProjects[0].projectKind,'chatgpt');
  assert.equal(value.chatgptProjectState,'cached');
  assert.deepEqual(value.workspaces[1].projectIds,['project-with-no-owner']);
  assert.deepEqual(value.workspaces[1].chatgptProjectIds,['g-p-chatgpt']);
  assert.equal(value.workspaces[1].slots[1].chatgptProjectId,'g-p-chatgpt');
  assert.equal(value.workspaces[1].slots[1].threadId,null);
  assert.equal(value.workspaces[1].slots[1].card,null);
  f.snapshot.chatgptProjectState = 'account-unverified';
  f.write();
  const unverified = await (await f.get()).json();
  assert.equal(unverified.chatgptProjects.length,0);
  assert.deepEqual(unverified.workspaces[1].chatgptProjectIds,[]);
  assert.equal(unverified.workspaces[1].slots[1].chatgptProjectId,null);
  assert.equal(unverified.workspaces[1].slots[1].unavailableReason,'chatgpt-cache-unavailable');
});

test('absorbed prefix keeps the native section and workspace identity', async t => {
  const f = await fixture(t);
  const nativeId = '6826c7b4-8c4b-451a-870d-e6287438a5ee';
  const derivedId = 'project-prefix-cc39835f2bd26276';
  f.snapshot.sections = [{id:nativeId,label:'카고24',prefix:'카고24',
    absorbedPrefixSectionId:derivedId,projectIds:['project-with-no-owner'],chatgptProjectIds:[]}];
  f.snapshot.mobile.workspaces.push({id:`section:${nativeId}`,kind:'project-prefix',label:'카고24',
    prefix:'카고24',nativeSectionId:nativeId,projectIds:['project-with-no-owner'],
    chatgptProjectIds:[],slots:[{kind:'project',threadId:null,projectId:'project-with-no-owner'}]});
  f.write();
  const value = await (await f.get()).json();
  assert.equal(value.sections.length,1);
  assert.equal(value.sections[0].id,nativeId);
  assert.equal(value.sections[0].absorbedPrefixSectionId,derivedId);
  assert.deepEqual(value.sections[0].projectIds,['project-with-no-owner']);
  assert.equal(value.workspaces[1].id,`section:${nativeId}`);
  assert.equal(value.workspaces[1].nativeSectionId,nativeId);
  assert.equal(value.workspaces[1].slots[0].projectId,'project-with-no-owner');
});

test('unreadable PC hidden policy fails closed instead of displaying cards', async t => {
  const f = await fixture(t);
  f.hide([voiceId]);
  fs.chmodSync(f.hiddenPath,0o644);
  assert.equal((await f.get()).status,409);
});

test('a symlink cannot replace the private PC hidden policy file', async t => {
  const f = await fixture(t);
  const target = `${f.hiddenPath}.target`;
  fs.writeFileSync(target,JSON.stringify({version:1,ids:[voiceId]}),{mode:0o600});
  fs.unlinkSync(f.hiddenPath);
  fs.symlinkSync(target,f.hiddenPath);
  assert.equal((await f.get()).status,409);
});

test('authenticated JSON projects exact current voice evidence and nine PC slots without sending', async t => {
  const f = await fixture(t);
  assert.equal((await f.get('wrong')).status,401);
  const response = await f.get();
  assert.equal(response.status,200);
  assert.equal(response.headers.get('cache-control'),'no-store');
  const value = await response.json();
  if (process.env.CANVAS_PROJECTION_FIXTURE)
    fs.writeFileSync(process.env.CANVAS_PROJECTION_FIXTURE,JSON.stringify(value));
  assert.equal(value.schemaVersion,1);
  assert.deepEqual(value.voiceCard,f.voice);
  assert.deepEqual(value.activeVoiceSession,f.snapshot.activeVoiceSession);
  assert.equal(value.currentGrid.length,9);
  assert.equal(value.currentGrid[2].threadId,voiceId);
  assert.deepEqual(value.currentGrid[2].card,f.voice);
  assert.equal(value.currentGrid[0].card,null);
  assert.equal(value.currentGrid[5].unavailableReason,'source-missing');
  assert.equal((await f.get(token,'POST')).status,404);
  assert.equal(f.sends(),0);
});

test('saved layouts resolve exact IDs and never replace missing source or unavailable owners', async t => {
  const f = await fixture(t);
  const value = await (await f.get()).json();
  const slots = value.workspaces[0].slots;
  assert.equal(slots.length,9);
  assert.equal(slots[0].card.id,voiceId);
  assert.equal(slots[1].card.title,'Current unavailable');
  assert.equal(slots[1].unavailableReason,'source-missing');
  assert.equal(slots[2].unavailableReason,'unavailable');
  assert.equal(slots[3].unavailableReason,'missing-catalog-member');
  assert.equal(slots[3].card,null);
  assert.equal(slots[4].threadId,null);
  assert.equal(slots[4].projectId,'project-with-no-owner');
  assert.equal(slots[4].card,null);
});

test('candidate is not a live session and mobile history cannot become the voice card', async t => {
  const f = await fixture(t);
  f.snapshot.activeVoiceSession = null;
  f.write();
  assert.equal((await (await f.get()).json()).activeVoiceSession,null);
  f.snapshot.threads = [];
  f.snapshot.mobile.threads.push(f.voice);
  f.write();
  assert.equal((await (await f.get()).json()).voiceCard,null);
});

test('hidden, archived and missing-source catalog members stay unavailable despite available history', async t => {
  const f = await fixture(t);
  for (const flag of ['hidden','archived','sourceMissing']) {
    f.snapshot.catalog[0][flag] = true;
    f.write();
    const value = await (await f.get()).json();
    assert.notEqual(value.workspaces[0].slots[0].unavailableReason,null);
    assert.equal(value.activeVoiceSession,null);
    delete f.snapshot.catalog[0][flag];
  }
});

test('stale, future and malformed snapshots reject while invalid session becomes explicitly unconfirmed', async t => {
  const f = await fixture(t);
  for (const generatedAt of ['invalid',new Date(Date.now()-60000).toISOString(),new Date(Date.now()+60000).toISOString()]) {
    f.snapshot.generatedAt = generatedAt; f.write();
    assert.equal((await f.get()).status,409);
  }
  f.snapshot.generatedAt = new Date().toISOString();
  f.snapshot.activeVoiceSession.sessionId = '';
  f.write();
  assert.equal((await (await f.get()).json()).activeVoiceSession,null);
});

test('saved catalog-only cards keep verified metadata without invented status or history', async t => {
  const f = await fixture(t);
  f.snapshot.threads = [f.voice];
  f.snapshot.mobile.threads = [];
  Object.assign(f.snapshot.catalog[1],{title:'Catalog title',titleVerified:true});
  f.write();
  const value = await (await f.get()).json();
  const card = value.workspaces[0].slots[1].card;
  assert.equal(card.id,otherId);
  assert.equal(card.title,'Catalog title');
  assert.equal(card.status,undefined);
  assert.equal(card.events,undefined);
  assert.equal(value.workspaces[0].slots[1].unavailableReason,null);
});

test('session switch, close and stale observation are reflected without changing the card owner', async t => {
  const f = await fixture(t);
  f.snapshot.activeVoiceSession.sessionId = 'new-session-same-thread';
  f.write();
  assert.equal((await (await f.get()).json()).activeVoiceSession.sessionId,'new-session-same-thread');
  f.snapshot.activeVoiceSession.observedAt = '2020-01-01T00:00:00Z';
  f.write();
  assert.equal((await (await f.get()).json()).activeVoiceSession,null);
  f.snapshot.activeVoiceSession = null;
  f.write();
  const closed = await (await f.get()).json();
  assert.equal(closed.activeVoiceSession,null);
  assert.deepEqual(closed.voiceCard,f.voice);
});

test('disconnected reduced mobile history stays unconfirmed even inside a fresh HTTP snapshot', async t => {
  const f = await fixture(t);
  f.snapshot.threads = [f.voice];
  const history = {id:otherId,source:'codex',available:true,title:'Disconnected history',titleVerified:true,
    status:'Waiting for approval',turnStatus:'inProgress',events:[{id:'historical-event',source:'history',text:'Old turn'}],
    inputRequest:{requestId:'historical-request'},executions:[{id:'historical-execution'}]};
  for (const observation of [{},{stale:true},{observedAt:'2020-01-01T00:00:00Z'},
    {stale:false,observedAt:f.snapshot.generatedAt}]) {
    f.snapshot.mobile.threads = [{...history,...observation}];
    f.write();
    const slot = (await (await f.get()).json()).workspaces[0].slots[1];
    assert.equal(slot.unavailableReason,observation.stale ? 'stale' : 'unconfirmed-history');
    assert.equal(slot.card.available,false);
    assert.equal(slot.threadId,otherId);
    assert.equal(slot.card.id,otherId);
    assert.equal(slot.card.source,'codex');
    assert.deepEqual(slot.card.events,history.events);
    assert.deepEqual(slot.card.inputRequest,history.inputRequest);
  }
  assert.equal(f.sends(),0);
});

test('catalog restrictions reach voice, PC and saved cards through one effective availability', async t => {
  const f = await fixture(t);
  const {controlRoomProjection} = require('./control-room-projection');
  for (const restriction of [{hidden:true},{archived:true},{sourceMissing:true},{available:false}]) {
    const snapshot = structuredClone(f.snapshot);
    Object.assign(snapshot.catalog[0],restriction);
    const before = structuredClone(snapshot);
    const value = controlRoomProjection(snapshot,Date.parse(snapshot.generatedAt));
    if (restriction.hidden || restriction.sourceMissing) {
      assert.equal(value.activeVoiceId,null);
      assert.equal(value.voiceCard,null);
      for (const slot of [value.currentGrid[2],value.workspaces[0].slots[0]]) {
        assert.equal(slot.threadId,null);
        assert.equal(slot.card,null);
        assert.equal(slot.unavailableReason,'hidden');
      }
      assert.equal(JSON.stringify(value).includes('Actual voice title'),false);
      assert.equal(value.activeVoiceSession,null);
      assert.deepEqual(snapshot,before,'projection must not mutate source evidence');
      continue;
    }
    for (const card of [value.voiceCard,value.currentGrid[2].card,value.workspaces[0].slots[0].card]) {
      assert.equal(card.available,false,JSON.stringify(restriction));
      assert.equal(card.id,voiceId);
      assert.equal(card.source,'codex');
      assert.equal(card.unavailableReason,restriction.sourceMissing ? 'source-missing' : 'unavailable');
      for (const flag of ['hidden','archived','sourceMissing']) {
        if (restriction[flag]) assert.equal(card[flag],true);
      }
    }
    assert.equal(value.activeVoiceSession,null);
    assert.deepEqual(snapshot,before,'projection must not mutate source evidence');
  }
});

test('HTTP voice JSON carries catalog denial and never exposes an available voice card', async t => {
  const f = await fixture(t);
  for (const restriction of [{hidden:true},{archived:true},{sourceMissing:true},{available:false}]) {
    f.snapshot.catalog[0] = {id:voiceId,source:'codex',hostId:'local',
      forkedFromId:null,forkLineageVerified:true,available:true,...restriction};
    f.write();
    const value = await (await f.get()).json();
    if (restriction.hidden || restriction.sourceMissing) {
      assert.equal(value.voiceCard,null);
      assert.equal(value.currentGrid[2].card,null);
      assert.equal(value.workspaces[0].slots[0].card,null);
      assert.equal(value.currentGrid[2].unavailableReason,'hidden');
      assert.equal(value.activeVoiceSession,null);
      continue;
    }
    assert.equal(value.voiceCard.available,false);
    assert.equal(value.voiceCard.unavailableReason,value.currentGrid[2].unavailableReason);
    assert.equal(value.voiceCard.unavailableReason,value.workspaces[0].slots[0].unavailableReason);
    assert.equal(value.activeVoiceSession,null);
  }
});
