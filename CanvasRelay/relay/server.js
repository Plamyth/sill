'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {validPNG} = require('./canvas-png');
const {DOCUMENT_CAPABILITY,MAX_DOCUMENT_REQUEST_BYTES} = require('./canvas-document');
const {assertInkScene,assertAgentRevision,SCENE_CAPABILITIES,MAX_CANVAS_SCENE_BYTES} = require('./canvas-scene');
const {appServerDeliveryReady,withAppServer,deliverPacket} = require('./codex-delivery');
const {controlRoomProjection,hiddenThreadIds} = require('./control-room-projection');
const {ObsidianVault,VaultError} = require('./obsidian-vault');
const {VaultBlockEdits} = require('./vault-block-edits');
const {ControlRoomEvents} = require('./control-room-events');
const {watchPrivacyPolicy} = require('./vendor/mobile-control/control-privacy-policy');

const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const SNAPSHOT = path.join(os.homedir(),'Library','Application Support','CodexControlRoom','snapshot.json');
const HIDDEN = path.join(path.dirname(SNAPSHOT),'hidden-threads.json');
const STORE = process.env.CANVAS_RELAY_STORE || path.join(__dirname,'received');
const PORT = Number(process.env.CANVAS_RELAY_PORT || 8787);
const HOST = process.env.CANVAS_RELAY_HOST || '127.0.0.1';
const TOKEN = process.env.CANVAS_RELAY_TOKEN || '';
const SESSION = /^[A-Za-z0-9_.:-]{1,256}$/;
const HASH = /^[0-9a-f]{64}$/;
const MAX_CANVAS_REQUEST_BYTES = 13 * 1024 * 1024;

function sha(data) { return crypto.createHash('sha256').update(data).digest('hex'); }
function freshDate(value) {
  const at = Date.parse(value || '');
  return Number.isFinite(at) && Date.now() - at <= 30000 && at <= Date.now() + 5000;
}

function readHiddenIds(file = HIDDEN) {
  const fd = fs.openSync(file,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let contents;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0 || stat.size > 100000)
      throw new Error('Hidden card policy unavailable');
    contents = fs.readFileSync(fd,'utf8');
  } finally { fs.closeSync(fd); }
  const value = JSON.parse(contents);
  if (value?.version !== 1 || !Array.isArray(value.ids) || value.ids.length > 2000 ||
      value.ids.some(id => typeof id !== 'string' || !UUID.test(id)))
    throw new Error('Hidden card policy invalid');
  return new Set(value.ids.map(id => id.toLowerCase()));
}

function voiceProjection(snapshotPath = SNAPSHOT, hiddenPath = HIDDEN) {
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath,'utf8'));
  if (!freshDate(snapshot.generatedAt)) throw new Error('Control Room snapshot is stale');
  const session = snapshot.activeVoiceSession;
  const candidateId = String(session?.threadId || '').toLowerCase();
  if (session == null || hiddenThreadIds(snapshot,readHiddenIds(hiddenPath)).has(candidateId))
    return {generatedAt:snapshot.generatedAt,activeVoiceSession:null};
  if (!UUID.test(session.threadId || '') || (typeof session.sessionId !== 'string' || !SESSION.test(session.sessionId)) ||
      String(snapshot.activeVoiceId).toLowerCase() !== session.threadId.toLowerCase() || !freshDate(session.observedAt))
    throw new Error('Active voice session is unavailable or stale');
  return {generatedAt:snapshot.generatedAt,activeVoiceSession:{
    threadId:session.threadId.toLowerCase(),sessionId:session.sessionId,observedAt:session.observedAt}};
}

function samePair(a, b) {
  return !!a && !!b && a.threadId === b.threadId && a.sessionId === b.sessionId;
}

function requireTarget(snapshotPath, hiddenPath, packet, inboxThreadId) {
  if (packet.targetMode === 'inbox') {
    if (!UUID.test(inboxThreadId || '') || packet.threadId !== inboxThreadId.toLowerCase() ||
        packet.sessionId !== `inbox:${inboxThreadId.toLowerCase()}`)
      throw new Error('Fixed canvas inbox binding unavailable');
    return {threadId:packet.threadId,sessionId:packet.sessionId,targetMode:'inbox'};
  }
  if (packet.targetMode === 'selected-chat') {
    const snapshot = JSON.parse(fs.readFileSync(snapshotPath,'utf8'));
    const projection = controlRoomProjection(snapshot,Date.now(),readHiddenIds(hiddenPath));
    const slots = projection.currentGrid.filter(slot => slot.threadId === packet.threadId);
    const members = (snapshot.catalog || []).filter(row => row.id === packet.threadId);
    const rows = (snapshot.threads || []).filter(row => row.id === packet.threadId);
    const slot = slots[0], card = slot?.card;
    if (slots.length !== 1 || members.length !== 1 || rows.length !== 1 ||
        !['normal','voice','project'].includes(slot.kind) || slot.chatgptProjectId || slot.unavailableReason ||
        card?.id !== packet.threadId || [card,members[0]].some(row => row.source !== 'codex' ||
          row.available !== true || row.hidden || row.archived || row.sourceMissing || row.stale || row.unavailableReason))
      throw new Error('Selected chat is not a visible available Codex card in the current grid');
    return {threadId:packet.threadId,sessionId:packet.sessionId,targetMode:packet.targetMode,
      observedAt:projection.generatedAt};
  }
  const session = voiceProjection(snapshotPath,hiddenPath).activeVoiceSession;
  if (!samePair(session,packet)) throw new Error('Active voice session closed or changed before send');
  return session;
}

function decodeBytes(value) {
  if (typeof value !== 'string' || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value))
    throw new Error('Invalid base64 packet bytes');
  const bytes = Buffer.from(value,'base64');
  if (bytes.toString('base64') !== value) throw new Error('Invalid base64 packet bytes');
  return bytes;
}

function parsePacket(body, inboxThreadId = '') {
  if (!UUID.test(body?.packetId || '') || !UUID.test(body?.threadId || '') ||
      (typeof body?.sessionId !== 'string' || !SESSION.test(body.sessionId)) || !HASH.test(body?.imageSha256 || '') ||
      !HASH.test(body?.sceneSha256 || '')) throw new Error('Invalid canvas packet binding');
  if ((body.targetMode != null && !['selected-chat','inbox'].includes(body.targetMode)) ||
      (body.targetMode === 'selected-chat' && body.sessionId !== `manual:${body.threadId.toLowerCase()}`) ||
      (body.targetMode === 'inbox' && (!UUID.test(inboxThreadId) ||
        body.threadId.toLowerCase() !== inboxThreadId.toLowerCase() ||
        body.sessionId !== `inbox:${inboxThreadId.toLowerCase()}`)) ||
      (body.targetMode == null && /^(manual|inbox):/.test(body.sessionId)))
    throw new Error('Invalid canvas target mode or manual binding');
  const image = decodeBytes(body.imagePNGBase64);
  const scene = decodeBytes(body.sceneJSONBase64);
  if (image.length < 8 || image.length > 5*1024*1024 || !validPNG(image))
    throw new Error('Canvas image must be PNG under 5 MiB');
  if (scene.length > MAX_CANVAS_SCENE_BYTES) throw new Error('Canvas scene exceeds 4 MiB');
  if (sha(image) !== body.imageSha256 || sha(scene) !== body.sceneSha256)
    throw new Error('Canvas byte hashes do not match');
  const value = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(scene));
  assertInkScene(value);
  if (!UUID.test(value.id || '') ||
      !Number.isSafeInteger(value.revision) || value.revision < 0 ||
      !Array.isArray(value.nodes) || !Array.isArray(value.links) || !Array.isArray(value.strokes))
    throw new Error('Invalid canvas scene');
  return {image,scene,binding:{packetId:body.packetId.toLowerCase(),threadId:body.threadId.toLowerCase(),
    sessionId:body.sessionId,imageSha256:sha(image),sceneSha256:sha(scene),
    ...(body.targetMode != null ? {targetMode:body.targetMode} : {})}};
}

function sameTargetMode(a, b) { return (a.targetMode ?? null) === (b.targetMode ?? null); }

function syncDirectory(directory) {
  const fd = fs.openSync(directory,'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function writeBytes(file, bytes) {
  const fd = fs.openSync(file,'wx',0o600);
  try { fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function writeReceipt(directory, receipt) {
  const temporary = path.join(directory,`${crypto.randomUUID()}.tmp`);
  writeBytes(temporary,JSON.stringify(receipt));
  fs.renameSync(temporary,path.join(directory,'receipt.json'));
  syncDirectory(directory);
}

function readReceipt(directory) {
  const receiptPath = path.join(directory,'receipt.json');
  const receipt = fs.existsSync(receiptPath) ? JSON.parse(fs.readFileSync(receiptPath,'utf8')) :
    {...JSON.parse(fs.readFileSync(path.join(directory,'packet.json'),'utf8')),
      state:'unknown',reason:'Packet persistence interrupted; do not resend'};
  if (!receipt.canonicalPacketId) return receipt;
  if (!UUID.test(receipt.canonicalPacketId) || receipt.canonicalPacketId === receipt.packetId)
    throw new Error('Invalid equivalent packet receipt');
  const canonical = readReceipt(path.join(path.dirname(directory),receipt.canonicalPacketId));
  if (canonical.canonicalPacketId || !sameTargetMode(canonical,receipt) || ['threadId','sessionId','imageSha256','sceneSha256'].some(key =>
    canonical[key] !== receipt[key])) throw new Error('Equivalent packet receipt binding conflict');
  return {...canonical,packetId:receipt.packetId,canonicalPacketId:canonical.packetId};
}

function equivalentSlot(store, binding) {
  const identity = [binding.threadId,binding.sessionId,binding.imageSha256,binding.sceneSha256];
  if (binding.targetMode != null) identity.push(binding.targetMode);
  const key = sha(JSON.stringify(identity));
  const root = path.join(store,'.equivalent',key);
  let directory = root;
  const seen = new Set();
  while (fs.existsSync(directory)) {
    const original = JSON.parse(fs.readFileSync(path.join(directory,'reservation.json'),'utf8'));
    if (!UUID.test(original.packetId || '') || seen.has(original.packetId) || !sameTargetMode(original,binding) ||
        ['threadId','sessionId','imageSha256','sceneSha256'].some(key => original[key] !== binding[key]))
      throw new Error('Equivalent packet reservation conflict');
    if (original.packetId === binding.packetId) return {directory,canonicalId:original.packetId};
    seen.add(original.packetId);
    let receipt;
    try { receipt = readReceipt(path.join(store,original.packetId)); }
    catch { return {directory,canonicalId:original.packetId}; }
    if (receipt.state !== 'rejected') return {directory,canonicalId:original.packetId};
    // A definite refusal has no enqueue effect. One durable successor may claim a new attempt.
    directory = path.join(root,`after-${original.packetId}`);
  }
  return {directory,canonicalId:null};
}

function claimEquivalent(store, binding) {
  const slot = equivalentSlot(store,binding);
  if (slot.canonicalId) return slot.canonicalId;
  try { fs.mkdirSync(slot.directory,{mode:0o700}); }
  catch (error) {
    if (error.code === 'EEXIST') throw new Error('Equivalent packet reserved concurrently; read its receipt');
    throw error;
  }
  syncDirectory(path.dirname(slot.directory));
  writeBytes(path.join(slot.directory,'reservation.json'),JSON.stringify(binding));
  syncDirectory(slot.directory);
  return null;
}

function persistPacket(store, binding, image, scene, canonical = null, deliveryScope = 'active-turn-steer') {
  const directory = path.join(store,binding.packetId);
  fs.mkdirSync(directory,{mode:0o700});
  syncDirectory(store);
  const receipt = {...binding,state:'stored',queuedId:null,turnId:null,clientUserMessageId:binding.packetId,
    deliveryScope,
    sessionContinuity:{status:'not-observed',atomic:false,before:null,after:null},
    createdAt:new Date().toISOString()};
  if (canonical) Object.assign(receipt,canonical,binding,{canonicalPacketId:canonical.packetId});
  writeBytes(path.join(directory,'packet.json'),JSON.stringify(receipt));
  writeBytes(path.join(directory,'image.png'),image);
  writeBytes(path.join(directory,'scene.json'),scene);
  writeReceipt(directory,receipt);
  return receipt;
}

function verifyStoredBytes(directory, binding) {
  if (sha(fs.readFileSync(path.join(directory,'image.png'))) !== binding.imageSha256 ||
      sha(fs.readFileSync(path.join(directory,'scene.json'))) !== binding.sceneSha256)
    throw new Error('Stored canvas byte hashes do not match');
}

function json(response, status, value) {
  response.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});
  response.end(JSON.stringify(value));
}

function receive(request, limit = 9*1024*1024, document = false) {
  return new Promise((resolve,reject) => {
    const chunks = []; let length = 0, exceeded = false;
    request.on('data', chunk => {
      if(exceeded)return;length += chunk.length;
      if (length > limit) {
        exceeded=true;chunks.length=0;
        if(document)reject(new VaultError('문서 wire 한도를 초과했습니다.',413,{code:'document_too_large',publicationAttempted:false,reconciliationRequired:false}));
        else {request.destroy();reject(new Error('Request too large'));}
      }
      else chunks.push(chunk);
    });
    request.on('end', () => {
      if(exceeded)return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(new Error('Invalid JSON')); }
    });
    request.on('error', reject);
  });
}

function createServer({snapshotPath = SNAPSHOT, hiddenPath = HIDDEN, store = STORE, token = TOKEN,
  vaultRoot = process.env.CANVAS_RELAY_VAULT_ROOT || '',
  controlEvents = {},
  deliveryScope = 'active-turn-steer',
  inboxThreadId = process.env.CANVAS_RELAY_INBOX_THREAD_ID || '',
  deliveryReady = appServerDeliveryReady,
  deliver = (packet,beforeDispatch) => withAppServer(rpc => deliverPacket(packet,rpc,beforeDispatch))} = {}) {
  if (!['active-turn-steer','exact-chat-queue-only'].includes(deliveryScope))
    throw new Error('Invalid delivery scope');
  if (!token || token.length < 24) throw new Error('Set CANVAS_RELAY_TOKEN to at least 24 characters');
  if (inboxThreadId && !UUID.test(inboxThreadId)) throw new Error('Invalid fixed canvas inbox thread ID');
  const vault = vaultRoot ? new ObsidianVault(vaultRoot) : null;
  fs.mkdirSync(store,{recursive:true,mode:0o700});
  fs.chmodSync(store,0o700);
  syncDirectory(path.dirname(store));
  fs.mkdirSync(path.join(store,'.equivalent'),{recursive:true,mode:0o700});
  syncDirectory(store);
  const blockEdits = vault ? new VaultBlockEdits(vault,store) : null;
  for (const item of fs.readdirSync(store,{withFileTypes:true})) {
    if (!item.isDirectory() || !UUID.test(item.name)) continue;
    const directory = path.join(store,item.name);
    let manifest;
    try { manifest = JSON.parse(fs.readFileSync(path.join(directory,'packet.json'),'utf8')); } catch { continue; }
    let receipt;
    try { receipt = readReceipt(directory); } catch { continue; }
    if (!manifest.canonicalPacketId && receipt.state !== 'rejected') claimEquivalent(store,manifest);
    if (!receipt.canonicalPacketId && ['stored','dispatching'].includes(receipt.state))
      writeReceipt(directory,{...receipt,state:'unknown',reason:'Relay restarted; do not resend'});
  }
  const events = new ControlRoomEvents({
    subscribePolicy:callbacks => watchPrivacyPolicy({file:hiddenPath,...callbacks}),
    ...controlEvents,readHiddenIds:() => readHiddenIds(hiddenPath)});
  const server = http.createServer(async (request,response) => {
    if (request.headers['x-canvas-token'] !== token) return json(response,401,{error:'Unauthorized'});
    const url = new URL(request.url,'http://localhost');
    try {
      if (request.method === 'GET' && url.pathname === '/vault/canvas/capabilities')
        return json(response,200,{...SCENE_CAPABILITIES,document:DOCUMENT_CAPABILITY});
      if (url.pathname.startsWith('/vault/')) {
        if (!vault) return json(response,503,{error:'Obsidian vault is not configured'});
        const relative = url.searchParams.get('path') ?? '';
        if (url.pathname === '/vault/document') {
          if([...url.searchParams.keys()].join(',')!=='id')throw new VaultError('Only the document ID is accepted');
          const id=url.searchParams.get('id');
          if(request.method==='GET')return json(response,200,vault.document(id));
          if(request.method==='PUT')return json(response,200,vault.saveDocument(id,await receive(request,MAX_DOCUMENT_REQUEST_BYTES,true)));
        }
        if (url.pathname === '/vault/document/conflict') {
          const keys=[...url.searchParams.keys()].sort().join(','),id=url.searchParams.get('id');
          if(request.method==='GET') {
            if(keys==='id')return json(response,200,vault.documentConflict(id));
            if(keys==='id,material,recoveryID,sha256')return json(response,200,vault.documentConflict(id,Object.fromEntries(['material','recoveryID','sha256'].map(k=>[k,url.searchParams.get(k)]))));
            throw new VaultError('Only document reconciliation identifiers are accepted');
          }
          if(request.method==='PUT'&&keys==='id')return json(response,200,vault.resolveDocumentConflict(id,await receive(request,16*1024)));
          throw new VaultError('Invalid document reconciliation request');
        }

        if (url.pathname === '/vault/block') {
          const blockID = url.searchParams.get('blockID') ?? '';
          if (request.method === 'GET') return json(response,200,blockEdits.block(relative,blockID));
          if (request.method === 'PUT') {
            const body = await receive(request,6*1024*1024 + 4096);
            return json(response,200,blockEdits.edit(relative,blockID,body));
          }
        }
        if (url.pathname === '/vault/note/conflict') {
          if ([...url.searchParams.keys()].join(',') !== 'path') throw new VaultError('Only the note path is accepted');
          if (request.method === 'GET') return json(response,200,vault.noteConflict(relative));
          if (request.method === 'PUT') {
            const body = await receive(request,16*1024);
            return json(response,200,vault.resolveNoteConflict(relative,body));
          }
        }
        if (url.pathname === '/vault/canvas/conflict') {
          if ([...url.searchParams.keys()].join(',') !== 'id') throw new VaultError('Only the canvas ID is accepted');
          const id = url.searchParams.get('id') || '';
          if (request.method === 'GET') return json(response,200,vault.canvasConflict(id));
          if (request.method === 'PUT') {
            const body = await receive(request,16*1024);
            return json(response,200,vault.resolveCanvasConflict(id,body));
          }
        }
        if (url.pathname === '/vault/canvas') {
          const id = url.searchParams.get('id') || '';
          if (request.method === 'GET') return json(response,200,vault.canvas(id));
          if (request.method === 'PUT') {
            const body = await receive(request,MAX_CANVAS_REQUEST_BYTES);
            const scene = decodeBytes(body?.sceneJSONBase64);
            const image = decodeBytes(body?.imagePNGBase64);
            if (!validPNG(image)) throw new VaultError('Canvas preview is not a valid PNG');
            return json(response,200,vault.saveCanvas(id,body?.revision,scene,image,body?.baseSha256));
          }
        }
        if (request.method === 'GET' && url.pathname === '/vault/pdf')
          return json(response,200,vault.pdf(relative));
        if (request.method === 'GET' && url.pathname === '/vault/entries')
          return json(response,200,{entries:vault.entries(relative)});
        if (request.method === 'GET' && url.pathname === '/vault/note')
          return json(response,200,vault.note(relative));
        if (request.method === 'PUT' && url.pathname === '/vault/note') {
          const body = await receive(request,1024*1024 + 4096);
          return json(response,200,vault.save(relative,body?.baseSha256,body?.text));
        }
      }
      if (request.method === 'GET' && url.pathname === '/control-room/events')
        return events.attach(response);
      if (request.method === 'GET' && url.pathname === '/inbox/target') {
        if (!inboxThreadId) return json(response,503,{error:'고정 그림 수신함이 아직 설정되지 않았습니다.'});
        const threadId = inboxThreadId.toLowerCase();
        return json(response,200,{threadId,sessionId:`inbox:${threadId}`,
          targetMode:'inbox',title:'고정 그림 수신함'});
      }
      if (request.method === 'GET' && url.pathname === '/delivery/ready') {
        let available = false;
        try {
          const threadId = url.searchParams.get('threadId');
          const mode = url.searchParams.get('targetMode');
          if (mode !== 'inbox' || (inboxThreadId && threadId?.toLowerCase() === inboxThreadId.toLowerCase()))
            available = await deliveryReady(threadId,mode);
        } catch {}
        return json(response,200,{available:available === true});
      }
      if (request.method === 'GET' && url.pathname === '/control-room/projection')
        return json(response,200,controlRoomProjection(JSON.parse(fs.readFileSync(snapshotPath,'utf8')),
          Date.now(),readHiddenIds(hiddenPath)));
      if (request.method === 'GET' && url.pathname === '/voice/projection')
        return json(response,200,voiceProjection(snapshotPath,hiddenPath));
      if (request.method === 'POST' && url.pathname === '/packets') {
        const {image,scene,binding} = parsePacket(await receive(request,MAX_CANVAS_REQUEST_BYTES),inboxThreadId);
        const directory = path.join(store,binding.packetId);
        if (fs.existsSync(directory)) {
          const prior = readReceipt(directory);
          if (!sameTargetMode(prior,binding) || Object.keys(binding).some(key => prior[key] !== binding[key]))
            throw new Error('Packet ID already binds different bytes or target session');
          verifyStoredBytes(directory,binding);
          return json(response,200,prior);
        }
        // Both reservations survive crashes. Neither an incomplete claim nor an alias can dispatch.
        let canonicalId = equivalentSlot(store,binding).canonicalId;
        if (!canonicalId) {
          try { requireTarget(snapshotPath,hiddenPath,binding,inboxThreadId); }
          catch (error) {
            const rejected = persistPacket(store,binding,image,scene,null,
              binding.targetMode ? 'exact-chat-start' : deliveryScope);
            rejected.state = 'rejected';
            rejected.reason = error.message;
            writeReceipt(directory,rejected);
            return json(response,201,rejected);
          }
          canonicalId = claimEquivalent(store,binding);
        }
        if (canonicalId) {
          if (canonicalId === binding.packetId) throw new Error('Packet reservation incomplete; do not resend');
          const canonical = readReceipt(path.join(store,canonicalId));
          const alias = persistPacket(store,binding,image,scene,canonical,deliveryScope);
          return json(response,200,alias);
        }
        const receipt = persistPacket(store,binding,image,scene,null,
          binding.targetMode ? 'exact-chat-start' : deliveryScope);
        try {
          requireTarget(snapshotPath,hiddenPath,binding,inboxThreadId);
          const result = await deliver({...binding,imagePath:path.join(directory,'image.png'),
            scenePath:path.join(directory,'scene.json')},scope => {
            if (receipt.state !== 'stored') throw new Error('Packet dispatch already attempted');
            if (binding.targetMode === 'selected-chat' || binding.targetMode === 'inbox') {
              if (!['active-turn-steer','exact-chat-start',
                ...(binding.targetMode === 'inbox' ? ['exact-chat-queue-only'] : [])].includes(scope))
                throw new Error('Invalid selected chat dispatch scope');
              receipt.deliveryScope = scope;
            }
            verifyStoredBytes(directory,binding);
            const before = requireTarget(snapshotPath,hiddenPath,binding,inboxThreadId);
            receipt.state = 'dispatching';
            receipt.sessionContinuity = {status:binding.targetMode === 'inbox' ? 'fixed-inbox-bound' : 'before-only',
              atomic:false,before:binding.targetMode === 'inbox' ? null : before,after:null};
            writeReceipt(directory,receipt);
          });
          const scope = receipt.deliveryScope;
          const id = scope === 'exact-chat-queue-only' ? result?.queuedId : result?.turnId;
          if (receipt.state !== 'dispatching' || !UUID.test(id || '') ||
              result.clientUserMessageId !== binding.packetId ||
              (binding.targetMode != null && result.deliveryScope !== scope))
            throw new Error('Conversation delivery result unknown');
          receipt.state = scope === 'exact-chat-start' ? 'started' : scope === 'active-turn-steer' ? 'steered' : 'queued';
          if (scope !== 'exact-chat-queue-only') receipt.turnId = id;
          else receipt.queuedId = id;
          let after = null;
          if (binding.targetMode !== 'inbox') {
            try { after = binding.targetMode != null ? requireTarget(snapshotPath,hiddenPath,binding,inboxThreadId) :
              voiceProjection(snapshotPath,hiddenPath).activeVoiceSession; } catch {}
          }
          receipt.sessionContinuity.after = after;
          receipt.sessionContinuity.status = binding.targetMode === 'inbox' ? 'fixed-inbox-bound' :
            samePair(binding,after) ? 'observed-same' : 'changed-or-unavailable';
        } catch (error) {
          receipt.state = receipt.state === 'stored' ? 'rejected' : 'unknown';
          receipt.reason = error.message;
          if (UUID.test(error.queuedId || '')) receipt.queuedId = error.queuedId;
        }
        writeReceipt(directory,receipt);
        return json(response,201,receipt);
      }
      const packetMatch = url.pathname.match(/^\/packets\/([0-9a-f-]+)\/(receipt|revision)$/i);
      const packetId = packetMatch?.[1]?.toLowerCase();
      if (UUID.test(packetId || '')) {
        const directory = path.join(store,packetId);
        if (packetMatch[2] === 'receipt' && request.method === 'GET') {
          if (!fs.existsSync(directory)) return json(response,404,{error:'Packet receipt not found; do not resend'});
          return json(response,200,readReceipt(directory));
        }
        // Equivalent sends share the original agent's revision as well as its queue receipt.
        const legacy = !fs.existsSync(directory);
        const canonicalId = legacy ? null : readReceipt(directory).canonicalPacketId;
        const revisionDirectory = canonicalId ? path.join(store,canonicalId) : directory;
        const file = legacy ? path.join(store,`${packetId}.revision.json`) : path.join(revisionDirectory,'revision.json');
        if (packetMatch[2] === 'revision' && request.method === 'GET')
          return json(response,200,fs.existsSync(file) ? JSON.parse(fs.readFileSync(file,'utf8')) : null);
        if (packetMatch[2] === 'revision' && request.method === 'PUT') {
          const receiptPath = legacy ? path.join(store,`${packetId}.receipt.json`) : path.join(revisionDirectory,'receipt.json');
          if (!fs.existsSync(receiptPath)) throw new Error('Canvas packet not found');
          const body = await receive(request,1024*1024);
          const scenePath = legacy ? path.join(store,`${packetId}.json`) : path.join(revisionDirectory,'scene.json');
          const scene = JSON.parse(fs.readFileSync(scenePath,'utf8'));
          if (body?.sceneId !== scene.id || body.baseRevision !== scene.revision ||
              !Array.isArray(body.annotations) || !Array.isArray(body.proposedNodes))
            throw new Error('Agent revision does not match canvas');
          assertAgentRevision(scene,body);
          const temporary = `${file}.${crypto.randomUUID()}.tmp`;
          writeBytes(temporary,JSON.stringify(body));
          fs.renameSync(temporary,file);
          syncDirectory(path.dirname(file));
          return json(response,200,{saved:true,packetId});
        }
      }
      return json(response,404,{error:'Not found'});
    } catch (error) { return json(response,error instanceof VaultError ? error.status : 409,
      {error:error.message,...(error.code ? {code:error.code} : {}),
        ...(typeof error.reconciliationRequired==='boolean' ? {reconciliationRequired:error.reconciliationRequired,
          ...(error.recoveryID?{recoveryID:error.recoveryID}:{}),publicationAttempted:error.publicationAttempted} : {})}); }
  });
  const close = server.close;
  server.close = function (...args) {
    events.close();
    return close.apply(this,args);
  };
  server.once('close',() => events.close());
  return server;
}

if (require.main === module) {
  const server = createServer();
  server.listen(PORT,HOST,() => process.stdout.write(JSON.stringify({host:HOST,port:PORT,store:STORE})+'\n'));
}

module.exports = {createServer,voiceProjection,parsePacket};
