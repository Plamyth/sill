'use strict';
const {createHash} = require('node:crypto');
const {fileURLToPath}=require('node:url');
const path=require('node:path');
const {normalizeObservations}=require('../bridge/cursor-desktop-catalog');
const {localUri}=require('./cursor-history-pages');

const LABELS={codex:'Codex','cursor-cloud':'Cursor Cloud','cursor-desktop':'Cursor Desktop','cursor-history':'Cursor 이력','reason-network':'Reason Network','grok-bot':'Grok Bot'};
const UUID=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const FRESH_MS=90000;
const AGENT_STATES=new Map([
  ['ACTIVE',{filter:'running',label:'Agent 활성 · ACTIVE · 실행·시작 대기 포함'}],
  ['IDLE',{filter:'idle',label:'Agent 대기 · IDLE · 성공 여부 미확인'}],
  ['ARCHIVED',{filter:'all',label:'Agent 종료 · ARCHIVED'}]
]);
const CLOUD_RUN_STATES=new Map([
  ['CREATING',{filter:'running',label:'run 진행'}],['RUNNING',{filter:'running',label:'run 진행'}],
  ['FINISHED',{filter:'completed',label:'run 완료',terminal:true}],
  ['ERROR',{filter:'idle',label:'run 오류',terminal:true}],
  ['CANCELLED',{filter:'idle',label:'run 취소',terminal:true}],
  ['EXPIRED',{filter:'idle',label:'run 만료',terminal:true}]
]);
function text(value,max=2000){return typeof value==='string'?value.slice(0,max):'';}
function sourceLabel(id){return LABELS[id] || '출처 미확인';}
function cloudRunState(row){return row.source==='cursor-cloud' && row.status===row.executionStatus &&
  ['cursor-cloud-sse','cursor-cloud-get-run'].includes(row.statusSource)?CLOUD_RUN_STATES.get(row.executionStatus):null;}
function cloudDisplayStatus(row){
  const run=cloudRunState(row);if(run)return run.label+' · '+row.executionStatus;
  if(row.agentStatus!=null)return AGENT_STATES.get(row.agentStatus)?.label || 'Agent 상태 미확인';
  if(['FINISHED','COMPLETED'].includes(row.status))return 'run 완료 · '+row.status;
  if(['RUNNING','CREATING'].includes(row.status))return 'run 진행 · '+row.status;
  return 'run 상태 · '+(text(row.status,100) || '미확인');
}
function externalProject(row){return 'external-'+createHash('sha256').update(['cursor-desktop','cursor-history'].includes(row.source)?
  JSON.stringify(['cursor-desktop',row.workspaceIdentity]):row.repository || row.source).digest('hex').slice(0,16);}
function desktopKey(row,threadId=null){return JSON.stringify(['cursor-desktop',row.instanceId,row.workspaceIdentity,threadId?.toLowerCase() || null]);}
function workspaceProject(uris,projects){
  const paths=[...new Set(uris.map(uri=>path.normalize(fileURLToPath(uri))))].sort();
  const workspace=paths.map(root=>path.basename(root) || root).join(', ') || '작업공간 미확인';
  const matches=paths.length?(projects || []).filter(project=>{
    const roots=project.sourceConnection?.roots || [];
    const stored=[...new Set(roots.map(root=>root.canonicalPath || root.path))].sort();
    return stored.length===paths.length && stored.every((root,index)=>root===paths[index]);
  }):[];
  return {workspace,projectId:matches.length===1?matches[0].id:null};
}
function desktopRows(data,projects){
  return data.cursorDesktop.flatMap(observation=>{
    const {workspace,projectId}=workspaceProject(observation.workspaceUris,projects);
    return (observation.selectedIds.length?observation.selectedIds:[null]).map(threadId=>({
      ...observation,key:desktopKey(observation,threadId),source:'cursor-desktop',externalId:threadId || observation.instanceId,
      threadId,title:`${workspace} · ${threadId?`열린 대화 ${threadId.replace(/^bc-/,'').slice(0,8)}`:observation.observedAt?'열린 대화 0개':'열린 대화 미확인'}`,
      projectId,ownerThreadId:null,ownerVerified:false,
      status:'미확인',capabilities:{read:true,send:false,approval:false,cancel:false}}));
  });
}
function historyRows(history,data,projects){
  return (history?.items || []).map(item=>{
    const workspaceUris=item.workspaceUris || [],{workspace,projectId}=workspaceProject(workspaceUris,projects);
    const instances=workspaceUris.length?data.cursorDesktop.filter(row=>JSON.stringify(row.workspaceUris)===JSON.stringify(workspaceUris)):[];
    const instance=instances.length===1?instances[0]:null;
    return {...item,key:JSON.stringify(['cursor-history',item.composerId,workspaceUris]),source:'cursor-history',externalId:item.composerId,
      threadId:item.composerId,title:item.title || `제목 없는 이력 · ${item.composerId.slice(0,8)}`,projectId,workspaceUris,
      workspaceLabel:workspace,workspaceIdentity:instance?.workspaceIdentity || createHash('sha256').update(JSON.stringify(workspaceUris)).digest('hex'),
      instanceId:instance?.instanceId || null,ownerThreadId:null,ownerVerified:false,status:'미확인',historyError:history.error || null,
      capabilities:{read:true,send:false,approval:false,cancel:false}};
  });
}
function normalize(raw){
  if(raw?.schema!==1)return {schema:1,observedAt:null,sources:[],items:[],sessions:[],cursorDesktop:[]};
  const seen=new Set();
  const rows=value=>(Array.isArray(value)?value:[]).filter(row=>{
    if(!row || !['cursor-cloud','reason-network','grok-bot'].includes(row.source) ||
      typeof row.externalId!=='string' || row.externalId.length>300)return false;
    const key=typeof row.key==='string'?row.key:JSON.stringify([row.source,row.externalId,row.runId || null]);
    if(seen.has(key))return false;seen.add(key);return true;
  }).map(row=>({...row,key:typeof row.key==='string'?row.key:JSON.stringify([row.source,row.externalId,row.runId || null]),title:text(row.title,200)||row.externalId,
    projectId:typeof row.projectId==='string'?row.projectId:null,
    ownerThreadId:row.ownerVerified===true && UUID.test(row.ownerThreadId||'')?row.ownerThreadId:null,
    ownerVerified:row.ownerVerified===true && UUID.test(row.ownerThreadId||''),
    capabilities:{read:row.capabilities?.read===true,send:row.capabilities?.send===true,approval:false,cancel:false}}));
  let cursorDesktop=[],desktopInvalid=false;
  try{cursorDesktop=normalizeObservations(raw.cursorDesktop || []);}catch{desktopInvalid=true;}
  return {schema:1,observedAt:raw.observedAt,cursorProjects:Array.isArray(raw.cursorProjects)?raw.cursorProjects:[],sources:(Array.isArray(raw.sources)?raw.sources:[])
    .filter(row=>LABELS[row?.id]).map(row=>({...row,label:sourceLabel(row.id),
      ...(row.id==='cursor-desktop'?{instanceCount:cursorDesktop.length,...(desktopInvalid?{state:'unavailable'}:{})}:{})})),items:rows(raw.items),sessions:rows(raw.sessions),cursorDesktop};
}
function bindings(raw){
  return raw?.schema===1 && Array.isArray(raw.bindings)?raw.bindings.filter(row=>
    typeof row.key==='string' && UUID.test(row.ownerThreadId||'') &&
    typeof row.projectId==='string' && typeof row.observedAt==='string'):[];
}
function externalRows(snapshot,linked=null,now=Date.now(),hiddenIds=new Set(),history=null){
  const data=normalize(snapshot?.unifiedControl);
  const assignments=bindings(linked);
  const known=new Map((assignments.length?snapshot?.catalog || []:[]).map(row=>[row.id,row]));
  const histories=historyRows(history,data,snapshot?.projects);
  const desktop=desktopRows(data,snapshot?.projects).filter(row=>!histories.some(item=>item.instanceId===row.instanceId&&item.threadId===row.threadId));
  const external=[...data.items.filter(row=>row.source!=='reason-network'),...data.sessions,...desktop,...histories].map(row=>{
    const assignment=assignments.find(item=>item.key===row.key);
    const owner=assignment && known.get(assignment.ownerThreadId);
    const bound=owner?.available!==false && owner?.projectVerified===true && owner.projectId===assignment?.projectId;
    const desktop=row.source==='cursor-desktop',historical=row.source==='cursor-history';
    const cloud=row.source==='cursor-cloud';
    const at=Date.parse(row.observedAt || (!desktop && !cloud && data.observedAt) || '');
    const state=data.sources.find(item=>item.id===row.source)?.state;
    const observationFresh=Number.isFinite(at) && now-at>=-30000 && now-at<FRESH_MS &&
      (historical?!row.historyError:desktop?['observed','stale'].includes(state) && row.state==='observed':
        cloud?(state==='observed' || state==='stale' && row.readFailed===false) &&
          row.readFailed!==true && !['stale','unavailable'].includes(row.state):state==='observed');
    const run=cloudRunState(row),received=Date.parse(row.lastReceivedAt || '');
    const runFresh=run && row.readFailed===false && ['observed','stale'].includes(state) &&
      Number.isFinite(at) && now-at>=-30000 &&
      (run.terminal && ['closed','expired'].includes(row.connectionState) ||
        row.connectionState==='connected' && Number.isFinite(received) && now-received>=-30000 && now-received<FRESH_MS);
    const fresh=observationFresh || Boolean(runFresh);
    return {...row,projectId:bound?owner.projectId:row.projectId,
      ownerThreadId:bound?owner.id:row.ownerThreadId,ownerVerified:bound||row.ownerVerified,
      fresh,stale:!fresh,capabilities:{...row.capabilities,send:observationFresh && (row.source==='reason-network' && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(row.externalId) && ['busy','idle'].includes(row.status) || row.source==='cursor-cloud' && bound && row.model && !/grok/i.test(row.model) && ['FINISHED','ERROR','CANCELLED','EXPIRED'].includes(row.status))},
      displayStatus:historical?`${fresh?'이력 조회':'이전 이력 · 재확인 필요'} · 활성 선택·진행 미확인`:desktop?`${row.state==='unavailable'?'조회 미확인':!fresh?'이전 관측 · 재확인 필요':'읽기 관측'} · ${row.observedAt?`열린 대화 ${row.selectedIds.length}개`:'열린 대화 수 미확인'} · 활성 선택·진행 미확인`:
        !fresh?'연결 상태 재확인 필요':cloud?cloudDisplayStatus(row):text(row.status,100)||'상태 미확인'};
  });
  return external.filter(row=>!row.ownerThreadId || !hiddenIds?.has(row.ownerThreadId));
}
function rows(snapshot,linked=null,now=Date.now(),hiddenIds=new Set()){
  const external=externalRows(snapshot,linked,now,hiddenIds);
  const local=(snapshot?.catalog||[]).map(row=>({key:'codex:'+row.id,source:'codex',externalId:row.id,
    title:row.title||row.id,projectId:row.projectId,ownerThreadId:row.id,ownerVerified:true,
    displayStatus:row.status || (row.turnStatus==='inProgress'?'진행 중':row.turnStatus==='completed'?'응답 완료':'상태 미확인'),
    fresh:row.available!==false,capabilities:{read:row.available!==false,send:row.available!==false},native:row}));
  return [...local,...external].filter(row=>!row.ownerThreadId || !hiddenIds?.has(row.ownerThreadId));
}
function projectRows(snapshot,projectId,linked,now,hiddenIds){return externalRows(snapshot,linked,now,hiddenIds).filter(row=>row.source!=='codex' &&
  (row.projectId===projectId || !row.projectId && externalProject(row)===projectId));}
function overview(snapshot,linked){
  const projects=[...(snapshot?.projects||[])],sections=[...(snapshot?.sections||[])];
  const loose=externalRows(snapshot,linked).filter(row=>row.source!=='codex'&&!row.projectId);
  const added=[];
  for(const row of loose){const id=externalProject(row);if(projects.some(item=>item.id===id))continue;
    projects.push({id,label:row.repository==='github.com/plamyth/theone-cargo'?'Cargo24 Cloud · 소속 연결 대기':sourceLabel(row.source)+' · 소속 연결 대기',kind:'external'});added.push(id);}
  if(added.length)sections.push({id:'external-agents',label:'외부 작업',threadIds:[],projectIds:added});
  return {projects,sections};
}
function matchesFilter(row,filter) {
  if(filter==='all')return true;
  if(['cursor-desktop','cursor-history'].includes(row.source))return false;
  if(!row.fresh)return false;
  const run=cloudRunState(row);if(run)return run.filter===filter;
  if(row.source==='cursor-cloud' && row.agentStatus!=null)return AGENT_STATES.get(row.agentStatus)?.filter===filter;
  if(filter==='running')return ['RUNNING','CREATING'].includes(row.status);
  if(filter==='completed')return ['FINISHED','COMPLETED'].includes(row.status);
  if(filter==='idle')return ['IDLE','WAITING','STOPPED','PAUSED','ERROR','CANCELLED','CANCELED','EXPIRED'].includes(row.status);
  return false;
}
function cursorRows(snapshot,linked=null,now=Date.now(),hiddenIds=new Set(),history=null){
  const cursorSnapshot={unifiedControl:snapshot?.unifiedControl};
  if(bindings(linked).length)cursorSnapshot.catalog=snapshot?.catalog;
  return externalRows(cursorSnapshot,linked,now,hiddenIds,history)
    .filter(row=>['cursor-cloud','cursor-desktop','cursor-history'].includes(row.source));
}
function workspaceUris(value){
  if(!Array.isArray(value) || !value.length || !value.every(localUri))return [];
  return [...new Set(value)].sort();
}
function cursorRepository(value){
  if(typeof value!=='string')return null;
  try{
    const url=new URL(value.replace(/^git@github\.com:/,'https://github.com/').replace(/^github\.com\//,'https://github.com/'));
    const parts=url.pathname.replace(/\/$/,'').replace(/\.git$/,'').split('/');
    if(url.protocol!=='https:' || url.hostname!=='github.com' || url.username || url.password || url.port || url.search || url.hash ||
      parts.length!==3 || !parts[1] || !parts[2])return null;
    return `github.com/${parts[1]}/${parts[2]}`.toLowerCase();
  }catch{return null;}
}
function cursorProjects(snapshot,linked=null,now=Date.now(),hiddenIds=new Set(),history=null){
  const projects=new Map();
  for(const item of normalize(snapshot?.unifiedControl).cursorProjects || []){
    if(!item || item.verified!==true || typeof item.id!=='string' || !item.id || typeof item.label!=='string' || !item.label.trim())continue;
    const id='cursor-project:'+item.id;
    if(projects.has(id))continue;
    projects.set(id,{id,nativeId:item.id,label:item.label,kind:'cursor-project',
      workspaceUris:workspaceUris(item.workspaceUris),repository:cursorRepository(item.repository),
      externalIds:Array.isArray(item.externalIds)?item.externalIds.filter(id=>typeof id==='string'):[],rows:[]});
  }
  const native=[...projects.values()];
  for(const row of cursorRows(snapshot,linked,now,hiddenIds,history)){
    const uris=workspaceUris(row.workspaceUris),repository=cursorRepository(row.repository);
    let matches=native.filter(project=>project.nativeId===row.cursorProjectId || project.externalIds.includes(row.externalId));
    if(!matches.length)matches=native.filter(project=>uris.length && JSON.stringify(project.workspaceUris)===JSON.stringify(uris));
    if(!matches.length)matches=native.filter(project=>repository && project.repository===repository);
    let project=matches.length===1?matches[0]:null;
    if(!project){
      const kind=uris.length?'workspace':repository?'repository':'unassigned';
      const identity=uris.length?JSON.stringify(uris):repository || row.key;
      const id=`cursor-${kind}:`+createHash('sha256').update(identity).digest('hex').slice(0,16);
      if(!projects.has(id))projects.set(id,{id,kind:'cursor-'+kind,
        label:uris.length?uris.map(uri=>path.basename(fileURLToPath(uri)) || fileURLToPath(uri)).join(', '):
          repository || `${sourceLabel(row.source)} · 소속 미확인 · ${row.externalId.slice(0,8)}`,
        workspaceUris:uris,repository,rows:[]});
      project=projects.get(id);
    }
    project.rows.push(row);
  }
  return [...projects.values()];
}
function cursorWorkspaceSequence(...args){
  return [{id:'all',label:'전체'},...cursorProjects(...args).map(project=>({id:'project:'+project.id,label:project.label}))];
}
function summarize(snapshot){const value=normalize(snapshot?.unifiedControl);return {
  sources:value.sources,cloud:value.items.length,agents:value.sessions.length,
  running:value.items.filter(row=>['RUNNING','CREATING','진행 중','실행 중'].includes(row.status)).length};}
module.exports={normalize,rows,externalRows,projectRows,overview,summarize,bindings,sourceLabel,externalProject,matchesFilter,FRESH_MS,desktopKey,
  cursorRows,cursorProjects,cursorWorkspaceSequence};
