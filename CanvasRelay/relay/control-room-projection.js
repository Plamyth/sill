'use strict';
const {controlHiddenIds,controlIdentity,controlPrivacy,codexSourceState} = require('./vendor/mobile-control/mobile-control');
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const BT_SCHEMA = 'control-room-bt-mobile-feed/v1';
const BT_OWNER = 'bt-ledger:goal_becdf9909850486b:';
const BT_MODES = new Set(['stopped','starting','running','stopping','blocked']);
const BT_PHASES = new Set(['queued','observation_pending','result_review','attention','completed']);
const plainText = value => value
  .replace(/([\uD800-\uDBFF][\uDC00-\uDFFF])|[\uD800-\uDFFF]/g, (_,pair) => pair || '')
  .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g,'');
const btId = value => typeof value === 'string' && value.length > 0 && value.length < 200 &&
  plainText(value) === value && value.trim() === value;
const btRevision = value => Number.isSafeInteger(value) && value >= 0;
const btTime = value => typeof value === 'string' && value.length <= 64 && plainText(value) === value ?
  Date.parse(value) : NaN;

function testDestinationCatalog(raw) {
  if (!raw || raw.schema !== 'ccr-test-destinations/v1' ||
      !Number.isFinite(btTime(raw.observedAt)) || !Array.isArray(raw.entries) ||
      raw.entries.length > 256 ||
      (raw.state !== undefined && !['ready','unavailable','malformed'].includes(raw.state)) ||
      (['unavailable','malformed'].includes(raw.state) && raw.entries.length !== 0)) return null;
  const entries = [];
  const ids = new Set();
  const text = (value, limit) => typeof value === 'string' && value.length > 0 &&
    value.length <= limit && plainText(value) === value && value.trim() === value;
  const origin = value => {
    if (!text(value,2048)) return false;
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && url.origin === value && !url.username && !url.password;
    } catch { return false; }
  };
  for (const row of raw.entries) {
    if (!row || ![row.id,row.projectId,row.owner].every(btId) || ids.has(row.id) ||
        ![row.projectLabel,row.label].every(value => text(value,500)) || !text(row.url,4096) ||
        !['reachable','unreachable','unknown'].includes(row.reachability) ||
        !['allowed','blocked','unknown'].includes(row.embed) ||
        !(row.redirectOrigins === undefined || (Array.isArray(row.redirectOrigins) &&
          row.redirectOrigins.length <= 8 && row.redirectOrigins.every(origin))) ||
        !(row.checkedAt === undefined || row.checkedAt === null || Number.isFinite(btTime(row.checkedAt))) ||
        !(row.reason === undefined || row.reason === null || text(row.reason,1000))) return null;
    ids.add(row.id);
    const {id,projectId,projectLabel,label,url,owner,reachability,embed,checkedAt,reason,redirectOrigins} = row;
    entries.push({id,projectId,projectLabel,label,url,owner,reachability,embed,checkedAt,reason,redirectOrigins});
  }
  return {schema:raw.schema,observedAt:raw.observedAt,
    ...(raw.state !== undefined ? {state:raw.state} : {}),entries};
}

function brainTrinityFeed(raw, projection, now) {
  const empty = {schema:BT_SCHEMA,available:false,writable:false,activities:[],reviewRequests:[]};
  const observed = btTime(raw?.observedAt);
  if (raw?.schema !== BT_SCHEMA || raw.available !== true || raw.writable !== false ||
      raw.source !== 'braintrinity' || !btId(raw.ownerInstanceId) ||
      !raw.ownerInstanceId.startsWith(BT_OWNER) || raw.ownerInstanceId.length === BT_OWNER.length ||
      !btRevision(raw.revision) || !btRevision(raw.epoch) || !BT_MODES.has(raw.mode) ||
      !Number.isFinite(observed) || Math.abs(now-observed) > 30000 ||
      !Array.isArray(raw.activities) || !Array.isArray(raw.reviewRequests)) return empty;

  function matches(row, slot) {
    if (!slot || !['normal','voice','project'].includes(slot.kind) || slot.chatgptProjectId ||
        (slot.unavailableReason && slot.unavailableReason !== 'empty-slot')) return false;
    const card = slot.card;
    if (slot.threadId) {
      if (!card || card.id !== slot.threadId || card.source !== 'codex' || card.available !== true ||
          card.hidden || card.archived || card.sourceMissing || card.stale || card.unavailableReason ||
          slot.unavailableReason) return false;
      if (row.threadId && row.threadId !== slot.threadId) return false;
      if (row.projectId && (card.projectVerified !== true || card.projectId !== row.projectId)) return false;
      if ([slot.projectId,slot.carouselProjectId].some(id => id && id !== card.projectId)) return false;
      return Boolean(row.threadId || row.projectId);
    }
    if (row.threadId || !row.projectId || slot.kind !== 'project' || card) return false;
    const ids = [slot.projectId,slot.carouselProjectId].filter(Boolean);
    return ids.length > 0 && ids.every(id => id === row.projectId) &&
      projection.projects.filter(project => project.id === row.projectId && project.projectKind !== 'chatgpt').length === 1;
  }

  function links(row) {
    if (!Array.isArray(row.cardLinks)) return [];
    const seen = new Set();
    return row.cardLinks.slice(0,256).filter(link => {
      if (!btId(link?.workspaceId) || !Number.isInteger(link.slotIndex) ||
          link.slotIndex < 0 || link.slotIndex > 8) return false;
      const layouts = projection.workspaces.filter(layout => layout.id === link.workspaceId);
      if (layouts.length !== 1) return false;
      const saved = layouts[0].slots.filter(slot => slot.index === link.slotIndex);
      const current = projection.workspace === link.workspaceId ?
        projection.currentGrid.filter(slot => slot.index === link.slotIndex) : [];
      if (!(saved.length === 1 && matches(row,saved[0])) &&
          !(current.length === 1 && matches(row,current[0]))) return false;
      const key = JSON.stringify([link.workspaceId,link.slotIndex]);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).map(({workspaceId,slotIndex}) => ({workspaceId,slotIndex}));
  }

  function reference(row) {
    const updated = btTime(row?.updatedAt);
    if (!row || row.ledgerRevision !== raw.revision ||
        ![row.projectId,row.threadId].every(id => id === null || btId(id)) ||
        typeof row.summary !== 'string' || row.summary.length > 2000 ||
        !Number.isFinite(updated) || updated > now+30000) return null;
    return {projectId:row.projectId,threadId:row.threadId,summary:plainText(row.summary),
      updatedAt:row.updatedAt,ledgerRevision:row.ledgerRevision,cardLinks:links(row)};
  }

  const activities = raw.activities.slice(0,50).flatMap(row => {
    if (!btId(row?.key) || !BT_PHASES.has(row.phase)) return [];
    const ref = reference(row);
    return ref ? [{key:row.key,phase:row.phase,...ref}] : [];
  });
  const reviewRequests = raw.reviewRequests.slice(0,50).flatMap(row => {
    if (!btId(row?.id) || row.state !== 'pending' || row.decisionAllowed !== false ||
        !btRevision(row.order)) return [];
    const ref = reference(row);
    return ref ? [{id:row.id,state:'pending',order:row.order,decisionAllowed:false,
      ...Object.fromEntries(['goalId','stepKey','taskId','dispatchId','resultId','runId']
        .filter(key => btId(row[key])).map(key => [key,row[key]])),...ref}] : [];
  });
  return {...empty,available:true,source:'braintrinity',ownerInstanceId:raw.ownerInstanceId,
    revision:raw.revision,epoch:raw.epoch,observedAt:raw.observedAt,mode:raw.mode,
    reason:typeof raw.reason === 'string' ? Array.from(plainText(raw.reason)).slice(0,500).join('') : null,
    activities:activities.filter(row => activities.filter(other => other.key === row.key).length === 1),
    reviewRequests:reviewRequests.filter(row => reviewRequests.filter(other => other.id === row.id).length === 1)};
}

function hiddenThreadIds(snapshot, external = new Set()) {
  return controlHiddenIds(snapshot,external);
}

function controlRoomProjection(snapshot, now = Date.now(), hiddenIds = new Set()) {
  const recent = value => {
    const time = Date.parse(value);
    return Number.isFinite(time) && now-time <= 30000 && time-now <= 5000;
  };
  if (!recent(snapshot.generatedAt)) throw new Error('Control Room snapshot is stale');
  const sourceRows = Array.isArray(snapshot.threads) ? snapshot.threads : [];
  const catalog = new Map((snapshot.catalog || []).map(row => [row.id,row]));
  const history = new Map((snapshot.mobile?.threads || []).map(row => [row.id,row]));
  const privacy = controlPrivacy(snapshot,hiddenIds);
  const concealed = privacy.ids;
  const hidden = (id, card) => typeof id === 'string' &&
    (concealed.has(controlIdentity(id)) || card?.hidden === true);

  function unavailable(member, card) {
    if (!member) return 'missing-catalog-member';
    if (member.sourceMissing || card?.sourceMissing) return 'source-missing';
    if (member.hidden || member.archived || card?.hidden || card?.archived) return 'unavailable';
    if (member.available !== true || card?.available !== true) return 'unavailable';
    if (!member.source) return 'source-unidentified';
    if (card?.stale) return 'stale';
    return card?.unavailableReason ?? null;
  }

  function effectiveCard(card, historyOnly = false) {
    if (!card) return null;
    if (card.source === 'codex' && card.sourceConnection)
      card = {...card,...codexSourceState(card,false,privacy)};
    const member = catalog.get(card.id);
    const reason = unavailable(member,card) ?? (historyOnly ? 'unconfirmed-history' : null);
    if (!reason) return card;
    const effective = {...card,available:false,unavailableReason:reason};
    for (const flag of ['hidden','archived','sourceMissing']) {
      if (member?.[flag]) effective[flag] = true;
    }
    return effective;
  }

  const rows = sourceRows.map(row => row.emptySlot ? row : hidden(row.id,row) ?
    {emptySlot:true,slotIndex:row.slotIndex,kind:'hidden'} : effectiveCard(row));
  const current = new Map(rows.filter(row => !row.emptySlot).map(row => [row.id,row]));

  function slot(index, source, card) {
    const threadId = source?.emptySlot ? null : source?.threadId ?? source?.id ?? null;
    if (source?.kind === 'hidden' || hidden(threadId,card))
      return {index,kind:'hidden',threadId:null,projectId:null,card:null,unavailableReason:'hidden'};
    if (source?.chatgptProjectId && snapshot.chatgptProjectState !== 'cached')
      return {index,kind:'unavailable',threadId:null,projectId:null,chatgptProjectId:null,
        card:null,unavailableReason:'chatgpt-cache-unavailable'};
    return {index,kind:source?.kind ?? (source?.carouselProjectId ? 'project' : card?.voiceCard ? 'voice' : 'normal'),
      threadId,projectId:source?.projectId ?? null,carouselProjectId:source?.carouselProjectId ?? null,
      chatgptProjectId:source?.chatgptProjectId ?? null,
      card:card ?? null,
      unavailableReason:threadId ? card?.unavailableReason ?? unavailable(catalog.get(threadId),card) : 'empty-slot'};
  }

  const currentGrid = Array.from({length:9},(_,index) => {
    const row = rows.find(row => row.slotIndex === index);
    return slot(index,row,row?.emptySlot ? null : row);
  });
  const workspaces = (snapshot.mobile?.workspaces || []).map(workspace => ({
    id:workspace.id,label:workspace.label,kind:workspace.kind ?? null,prefix:workspace.prefix ?? null,
    nativeSectionId:workspace.nativeSectionId ?? null,
    projectIds:workspace.projectIds ?? [],
    chatgptProjectIds:snapshot.chatgptProjectState === 'cached' ? workspace.chatgptProjectIds ?? [] : [],
    slots:Array.from({length:9},(_,index) => {
      const source = workspace.slots?.[index];
      const member = catalog.get(source?.threadId);
      const card = member ? current.get(member.id) ??
        effectiveCard(history.get(member.id) ?? member,history.has(member.id)) : null;
      return slot(index,source,card);
    })
  }));
  const candidateVoiceId = typeof snapshot.activeVoiceId === 'string' ? snapshot.activeVoiceId : null;
  const activeVoiceId = hidden(candidateVoiceId) ? null : candidateVoiceId;
  const voiceCard = rows.find(row => row.id === activeVoiceId && !row.emptySlot) ?? null;
  const session = snapshot.activeVoiceSession;
  const activeVoiceSession = voiceCard?.available === true &&
    session?.threadId === activeVoiceId && UUID.test(session.threadId) && typeof session.sessionId === 'string' &&
    /^[A-Za-z0-9_.:-]{1,256}$/.test(session.sessionId) && recent(session.observedAt) ? session : null;
  const projection = {schemaVersion:1,generatedAt:snapshot.generatedAt,workspace:snapshot.workspace ?? null,
    projects:(snapshot.projects || []).map(({id,label,displayLabel,projectKind}) =>
      ({id,label,displayLabel:displayLabel ?? label,projectKind})),
    chatgptProjects:snapshot.chatgptProjectState === 'cached' ?
      (snapshot.chatgptProjects || []).map(({id,label,displayLabel,projectKind}) =>
        ({id,label,displayLabel:displayLabel ?? label,projectKind})) : [],
    chatgptProjectState:snapshot.chatgptProjectState ?? 'unavailable',
    sections:(snapshot.sections || []).filter(section => section.kind === 'project-prefix' ||
      (typeof section.prefix === 'string' && section.prefix.length > 0)).map(section =>
      ({id:section.id,kind:section.kind ?? null,label:section.label,prefix:section.prefix ?? null,
        absorbedPrefixSectionId:section.absorbedPrefixSectionId ?? null,
        projectIds:section.projectIds ?? [],chatgptProjectIds:snapshot.chatgptProjectState === 'cached' ?
          section.chatgptProjectIds ?? [] : []})),
    activeVoiceId,activeVoiceSession,voiceCard,currentGrid,workspaces};
  projection.brainTrinity = brainTrinityFeed(snapshot.mobile?.brainTrinity,projection,now);
  if (Object.hasOwn(snapshot,'testDestinations')) {
    projection.testDestinations = testDestinationCatalog(snapshot.testDestinations) ??
      {schema:'ccr-test-destinations/v1',observedAt:snapshot.generatedAt,state:'malformed',entries:[]};
  }
  return projection;
}

module.exports = {controlRoomProjection,hiddenThreadIds};
