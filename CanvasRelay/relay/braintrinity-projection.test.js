'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {controlRoomProjection} = require('./control-room-projection');

const now = Date.parse('2026-10-15T12:00:00Z');
const time = new Date(now).toISOString();
const thread = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const owner = 'bt-ledger:goal_becdf9909850486b:16777232:404398100';
const empty = {schema:'control-room-bt-mobile-feed/v1',available:false,writable:false,
  activities:[],reviewRequests:[]};

function fixture() {
  const card = {id:thread,slotIndex:0,available:true,source:'codex',hostId:'local',
    forkedFromId:null,forkLineageVerified:true,projectId:'project-a',projectVerified:true};
  const ref = {projectId:'project-a',threadId:thread,summary:'Owner evidence',updatedAt:time,
    ledgerRevision:38,cardLinks:[{workspaceId:'all',slotIndex:0}]};
  return {generatedAt:time,workspace:'all',threads:[card],catalog:[{...card}],
    projects:[{id:'project-a',label:'Project A',projectKind:'codex'}],
    mobile:{workspaces:[{id:'all',label:'All',slots:[{kind:'normal',threadId:thread}]}],
      brainTrinity:{schema:empty.schema,available:true,writable:false,source:'braintrinity',
        ownerInstanceId:owner,revision:38,epoch:0,observedAt:time,mode:'blocked',reason:'effect_gate_identity_changed',
        activities:[{key:'activity-1',phase:'attention',...ref}],
        reviewRequests:[{id:'review-1',state:'pending',order:0,decisionAllowed:false,
          goalId:'goal-owner',taskId:'task-owner',dispatchId:'dispatch-owner',resultId:'result-owner',
          runId:'run-owner',stepKey:'step-owner',...ref}]}}};
}
const project = (snapshot,hidden = new Set()) => controlRoomProjection(snapshot,now,hidden);
const feed = snapshot => project(snapshot).brainTrinity;

test('read-only source shape and exact row/link/ref relationship survive the projection', () => {
  const snapshot = fixture();
  const projection = project(snapshot);
  assert.deepEqual(projection.brainTrinity,snapshot.mobile.brainTrinity);
  assert.equal(projection.currentGrid[0].card.projectVerified,true);
  assert.equal(projection.brainTrinity.reviewRequests[0].decisionAllowed,false);
  if (process.env.CANVAS_BT_FIXTURE)
    fs.writeFileSync(process.env.CANVAS_BT_FIXTURE,JSON.stringify(projection),{mode:0o600});
});

for (const [label,change] of [
  ['missing',s => delete s.mobile.brainTrinity],
  ['unavailable',s => s.mobile.brainTrinity.available = false],
  ['writable',s => s.mobile.brainTrinity.writable = true],
  ['missing read-only flag',s => delete s.mobile.brainTrinity.writable],
  ['foreign source',s => s.mobile.brainTrinity.source = 'chatgpt'],
  ['foreign owner',s => s.mobile.brainTrinity.ownerInstanceId = 'bt-ledger:goal_other:1'],
  ['empty owner instance',s => s.mobile.brainTrinity.ownerInstanceId = 'bt-ledger:goal_becdf9909850486b:'],
  ['stale',s => s.mobile.brainTrinity.observedAt = new Date(now-30001).toISOString()],
  ['future',s => s.mobile.brainTrinity.observedAt = new Date(now+30001).toISOString()],
  ['invalid date',s => s.mobile.brainTrinity.observedAt = 'bad-date'],
  ['foreign schema',s => s.mobile.brainTrinity.schema = 'braintrinity-control-room/v1'],
  ['negative revision',s => s.mobile.brainTrinity.revision = -1],
  ['unsafe revision',s => s.mobile.brainTrinity.revision = Number.MAX_SAFE_INTEGER+1],
  ['invalid epoch',s => s.mobile.brainTrinity.epoch = '0'],
  ['unknown mode',s => s.mobile.brainTrinity.mode = 'ready'],
  ['missing rows',s => delete s.mobile.brainTrinity.activities]
]) test(`${label} feed fails closed without retaining earlier badges`, () => {
  const snapshot = fixture();
  assert.equal(feed(snapshot).activities.length,1);
  change(snapshot);
  assert.deepEqual(feed(snapshot),empty);
});

test('current owner with zero rows retains blocked mode and never fabricates activity', () => {
  const snapshot = fixture();
  snapshot.mobile.brainTrinity.activities = [];
  snapshot.mobile.brainTrinity.reviewRequests = [];
  assert.deepEqual(feed(snapshot),snapshot.mobile.brainTrinity);
});

test('row revision, time, phase and review permission validation removes invalid rows', () => {
  for (const change of [row => row.ledgerRevision = 37,row => row.updatedAt = 'invalid',
    row => row.updatedAt = new Date(now+30001).toISOString(),row => row.projectId = {},
    row => row.summary = 'x'.repeat(2001)]) {
    const snapshot = fixture();
    change(snapshot.mobile.brainTrinity.activities[0]);
    change(snapshot.mobile.brainTrinity.reviewRequests[0]);
    assert.deepEqual(feed(snapshot).activities,[]);
    assert.deepEqual(feed(snapshot).reviewRequests,[]);
  }
  for (const change of [row => row.state = 'resolved',row => row.decisionAllowed = true,
    row => delete row.decisionAllowed,row => row.order = -1]) {
    const snapshot = fixture(); change(snapshot.mobile.brainTrinity.reviewRequests[0]);
    assert.deepEqual(feed(snapshot).reviewRequests,[]);
  }
  const snapshot = fixture(); snapshot.mobile.brainTrinity.activities[0].phase = 'running';
  assert.deepEqual(feed(snapshot).activities,[]);
});

test('only allowlisted bounded fields reach mobile; text control characters are removed', () => {
  const snapshot = fixture(); const raw = snapshot.mobile.brainTrinity;
  raw.command = 'must not propagate'; raw.reason = '\u0000blocked\u202e';
  raw.activities[0].summary = 'safe\u0000\u001b\u202e text'; raw.activities[0].secret = 'must not propagate';
  raw.activities[0].cardLinks[0].token = 'must not propagate';
  raw.reviewRequests[0].verdictURL = 'must not propagate';
  const result = feed(snapshot);
  assert.equal(result.reason,'blocked'); assert.equal(result.activities[0].summary,'safe text');
  assert.equal(JSON.stringify(result).includes('must not propagate'),false);
  raw.activities = Array.from({length:100},(_,i) => ({...raw.activities[0],key:`a-${i}`}));
  raw.reviewRequests = Array.from({length:100},(_,i) => ({...raw.reviewRequests[0],id:`r-${i}`}));
  assert.equal(feed(snapshot).activities.length,50); assert.equal(feed(snapshot).reviewRequests.length,50);
});

test('bounded reason preserves Unicode scalars for the Swift projection decoder', () => {
  const snapshot = fixture();
  snapshot.mobile.brainTrinity.reason = 'x'.repeat(499) + '🚧' + 'y';
  snapshot.mobile.brainTrinity.activities[0].summary = 'safe\ud83d text';
  const projection = project(snapshot);
  assert.equal(projection.brainTrinity.reason,'x'.repeat(499) + '🚧');
  assert.equal(projection.brainTrinity.activities[0].summary,'safe text');
  assert.equal(Array.from(projection.brainTrinity.reason).length,500);
  if (process.env.CANVAS_BT_UNICODE_FIXTURE)
    fs.writeFileSync(process.env.CANVAS_BT_UNICODE_FIXTURE,JSON.stringify(projection),{mode:0o600});
});

test('unlinked and ownerless rows remain unassigned even when their text names the visible card', () => {
  const snapshot = fixture();
  const activity = snapshot.mobile.brainTrinity.activities[0];
  activity.summary = thread; activity.cardLinks = [];
  assert.deepEqual(feed(snapshot).activities[0].cardLinks,[]);
  activity.threadId = null; activity.projectId = null;
  activity.cardLinks = [{workspaceId:'all',slotIndex:0}];
  assert.deepEqual(feed(snapshot).activities[0].cardLinks,[]);
});

for (const [label,change] of [
  ['hidden catalog',s => s.catalog[0].hidden = true],
  ['hidden slot',s => {s.threads[0].hidden = true; s.mobile.workspaces[0].slots[0].kind = 'hidden';}],
  ['unavailable',s => s.catalog[0].available = false],
  ['missing source',s => s.threads[0].sourceMissing = true],
  ['ChatGPT card',s => s.threads[0].source = 'chatgpt'],
  ['ChatGPT slot kind',s => {s.threads[0].kind = 'chatgpt'; s.mobile.workspaces[0].slots[0].kind = 'chatgpt';}],
  ['ChatGPT project',s => {s.threads[0].chatgptProjectId = 'remote'; s.mobile.workspaces[0].slots[0].chatgptProjectId = 'remote';}],
  ['different thread',s => s.mobile.brainTrinity.activities[0].threadId = other],
  ['different project',s => s.mobile.brainTrinity.activities[0].projectId = 'project-b'],
  ['unverified project',s => delete s.threads[0].projectVerified],
  ['mismatched visible project',s => {s.threads[0].carouselProjectId = 'project-b'; s.mobile.workspaces[0].slots[0].projectId = 'project-b';}],
  ['foreign workspace',s => s.mobile.brainTrinity.activities[0].cardLinks[0].workspaceId = 'other'],
  ['wrong index',s => s.mobile.brainTrinity.activities[0].cardLinks[0].slotIndex = 1],
  ['invalid index',s => s.mobile.brainTrinity.activities[0].cardLinks[0].slotIndex = 9],
  ['duplicate workspace',s => s.mobile.workspaces.push({...s.mobile.workspaces[0]})]
]) test(`${label} never receives an activity link`, () => {
  const snapshot = fixture(); change(snapshot);
  assert.deepEqual(feed(snapshot).activities[0].cardLinks,[]);
});

test('external hidden policy strips BT links in both saved and current layouts', () => {
  const snapshot = fixture();
  const result = project(snapshot,new Set([thread])).brainTrinity;
  assert.deepEqual(result.activities[0].cardLinks,[]);
  assert.deepEqual(result.reviewRequests[0].cardLinks,[]);
});

test('project-only rows link only to an exact supplied Codex project identity', () => {
  const snapshot = fixture();
  snapshot.threads = [{emptySlot:true,slotIndex:0,carouselProjectId:'project-a'}];
  snapshot.mobile.workspaces[0].slots = [{kind:'project',projectId:'project-a'}];
  snapshot.mobile.brainTrinity.activities[0].threadId = null;
  assert.deepEqual(feed(snapshot).activities[0].cardLinks,[{workspaceId:'all',slotIndex:0}]);
  snapshot.projects = [];
  assert.deepEqual(feed(snapshot).activities[0].cardLinks,[]);
});

test('duplicate row IDs are ambiguous and cannot create duplicate badges', () => {
  const snapshot = fixture(); const raw = snapshot.mobile.brainTrinity;
  raw.activities.push({...raw.activities[0]}); raw.reviewRequests.push({...raw.reviewRequests[0]});
  assert.deepEqual(feed(snapshot).activities,[]); assert.deepEqual(feed(snapshot).reviewRequests,[]);
});
