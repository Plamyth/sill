'use strict';
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const crypto=require('node:crypto');
const root=()=>path.dirname(process.env.CCR_BRIDGE_HELPER || path.join(os.homedir(),'Documents','CARGO24_지식볼트','.obsidian','plugins','codex-control-room','bridge.js'));
const text=(value,max=200)=>typeof value==='string'?value.slice(0,max):null;
const PROVIDERS=['codex','cursor-desktop','cursor-cloud'];
const UUID=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
function privateBindings(){
  try {
    const file=path.join(os.homedir(),'Library','Application Support','CodexControlRoom','unified-agent-bindings.json');
    const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
    try {const info=fs.fstatSync(fd);if(!info.isFile()||info.uid!==process.getuid()||(info.mode&0o077)||info.size>1024*1024)return null;
      return JSON.parse(fs.readFileSync(fd,'utf8'));}finally{fs.closeSync(fd);}
  } catch {return null;}
}
function installedRows(raw,hidden){return require(path.join(root(),'unified-control.js')).rows(raw,privateBindings(),Date.now(),hidden);}
function installedCommand(request){return require(path.join(root(),'unified-agent-client.js')).call(path.join(root(),'unified-agent-command.py'),request);}
function connection(item){
  return {provider:item.provider,connected:item.connected===true,
    state:['connected','stale','unavailable','unsupported'].includes(item.state)?item.state:'unavailable',
    connectedAt:text(item.connectedAt,40),observedAt:text(item.observedAt,40),owner:text(item.owner),
    sessionId:text(item.sessionId,2048),runId:text(item.runId),sourceRevision:Number.isSafeInteger(item.sourceRevision)?item.sourceRevision:text(item.sourceRevision,200),
    readOnly:item.readOnly!==false,capabilities:{read:item.capabilities?.read===true,send:false},
    reason:text(item.reason,500)};
}
function codexSourceState(thread,expected=false,privacy=null){
  if(thread?.voiceCard||thread?.emptySlot)return {sourceConnection:null,stale:thread.stale===true};
  const raw=thread?.sourceConnection;
  if(!raw)return {sourceConnection:null,stale:thread?.stale===true||expected};
  const projected=privacy?privacy.connection(raw):connection(raw);
  const bound=raw.provider==='codex'&&raw.sessionId===thread.id;
  const current=bound&&projected.connected===true&&raw.state==='connected'&&typeof raw.owner==='string'&&Boolean(raw.owner)&&
    Number.isSafeInteger(raw.sourceRevision)&&raw.sourceRevision>=0&&raw.runId===(thread.activeTurnId||null);
  projected.connected=current;
  if(!bound)projected.state='unavailable';
  return {sourceConnection:projected,stale:!current};
}
function controlIdentity(value){
  return typeof value==='string'&&UUID.test(value)?value.toLowerCase():value;
}
function controlHiddenIds(raw,hidden=new Set()){
  const concealed=new Set([...hidden].map(controlIdentity));
  const rows=new Map(),catalogIds=new Set(),conflicts=new Set();
  const fields=['forkedFromId','forkLineageVerified','source','hostId'];
  const signature=item=>JSON.stringify([['forkedFromId','forkLineageVerified'].map(field=>
    [Object.hasOwn(item,field),typeof item[field],controlIdentity(item[field])]),item.source||'codex',item.hostId||'local']);
  const syntheticCard=item=>!item.emptySlot&&!item.sourceMissing&&(item.voiceCard||item.voice)&&
    !Object.hasOwn(item,'forkedFromId')&&!Object.hasOwn(item,'forkLineageVerified');
  for(const item of Array.isArray(raw.catalog)?raw.catalog:[]){
    if(!item)continue;
    const id=controlIdentity(item.id);
    catalogIds.add(id);
    if(rows.has(id)&&signature(rows.get(id))!==signature(item))conflicts.add(id);
    else rows.set(id,item);
  }
  for(const entries of [raw.threads,raw.mobile?.threads])for(const item of Array.isArray(entries)?entries:[]){
    if(!item||syntheticCard(item))continue;
    const id=controlIdentity(item.id),known=rows.get(id);
    if(catalogIds.has(id)){
      if(fields.some(field=>Object.hasOwn(item,field)&&
        controlIdentity(item[field])!==controlIdentity(field==='source'?(known[field]||'codex'):
          field==='hostId'?(known[field]||'local'):known[field])))conflicts.add(id);
    }else if(known&&signature(known)!==signature(item))conflicts.add(id);
    else rows.set(id,item);
  }
  for(const entries of [raw.threads,raw.catalog,raw.mobile?.threads])for(const item of Array.isArray(entries)?entries:[]){
    if(item?.hidden===true)for(const id of [item.id,item.externalId,item.sessionId,item.threadId])
      if(typeof id==='string'&&id)concealed.add(controlIdentity(id));
  }
  const explicit=new Set(concealed);
  for(const [start,row] of rows){
    if(row.source&&row.source!=='codex'&&!conflicts.has(start))continue;
    let id=start,allowed=false;
    const seen=new Set();
    for(let depth=0;depth<64;depth++){
      const current=rows.get(id);
      if(typeof id!=='string'||!UUID.test(id)||explicit.has(id)||conflicts.has(id)||seen.has(id)||!current||current.emptySlot||current.sourceMissing||
        current.forkLineageVerified!==true||(current.source&&current.source!=='codex')||
        (current.hostId&&current.hostId!=='local'))break;
      seen.add(id);
      if(current.forkedFromId===null){allowed=true;break;}
      id=controlIdentity(current.forkedFromId);
    }
    if(!allowed)concealed.add(start);
  }
  return concealed;
}
function controlThreadIds(raw){
  const catalog=Array.isArray(raw.catalog)?raw.catalog:[],catalogIds=new Set(catalog.map(item=>controlIdentity(item?.id)));
  const copies=[raw.threads,raw.mobile?.threads].flatMap(entries=>Array.isArray(entries)?entries:[])
    .filter(item=>!catalogIds.has(controlIdentity(item?.id)));
  return new Set([...catalog,...copies].filter(item=>typeof item?.id==='string'&&UUID.test(item.id)&&!item.emptySlot&&!item.sourceMissing&&
    (!item.source||item.source==='codex')&&(!item.hostId||item.hostId==='local')).map(item=>controlIdentity(item.id)));
}
function controlThreadReadable(raw,id,hidden=new Set()){
  const identity=controlIdentity(id);
  return controlThreadIds(raw).has(identity)&&!controlHiddenIds(raw,hidden).has(identity);
}
function controlTargetHidden(target,hidden){
  if(!target)return false;
  const ids=[target.source,target.key,target.id,target.externalId,target.sessionId,target.threadId,target.runId,target.ownerThreadId,
    target.native?.id,target.activeTurnId,target.native?.activeTurnId];
  if(typeof target.key==='string'&&target.key.startsWith('[')){
    try{const key=JSON.parse(target.key);if(Array.isArray(key))ids.push(...key);}catch{}
  }
  return ids.some(id=>typeof id==='string'&&hidden.has(controlIdentity(id)));
}
function controlPrivacy(raw,hidden=new Set(),normalized=[]){
  const evidence={...raw,threads:[...(raw.threads||[]),...normalized.filter(row=>row?.source==='codex').map(row=>
    ({...row.native,id:row.native?.id??row.externalId,source:row.native?.source||'codex',hostId:row.native?.hostId||row.hostId||'local'}))]};
  const ids=controlHiddenIds(evidence,hidden),known=controlThreadIds(evidence);
  const concealed=new Set(ids),owners=new Set();
  const invalidLocal=row=>row?.source==='codex'&&(!UUID.test(row.externalId||'')||!known.has(controlIdentity(row.externalId))||
    row.native?.id!=null&&controlIdentity(row.native.id)!==controlIdentity(row.externalId));
  const unverifiedReference=row=>UUID.test(row?.ownerThreadId||'')&&
    !known.has(controlIdentity(row.ownerThreadId));
  const originals=[raw.threads,raw.catalog,raw.mobile?.threads,raw.unifiedControl?.items,raw.unifiedControl?.sessions].flatMap(items=>Array.isArray(items)?items:[]);
  function conceal(item){
    for(const id of [item.key,item.id,item.externalId,item.sessionId,item.threadId,item.runId,item.activeTurnId,item.native?.id,item.native?.activeTurnId])
      if(typeof id==='string'&&id)concealed.add(controlIdentity(id));
    for(const source of [item.sourceConnection,item.native?.sourceConnection]){
      for(const id of [source?.sessionId,source?.runId])if(typeof id==='string'&&id)concealed.add(controlIdentity(id));
      if(typeof source?.owner==='string'&&source.owner)owners.add(controlIdentity(source.owner));
    }
  }
  for(const item of originals)if(item&&unverifiedReference(item))conceal(item);
  for(const item of normalized)if(invalidLocal(item)||unverifiedReference(item))conceal(item);
  let changed;
  do{
    const size=concealed.size;
    for(const item of [...originals,...normalized])if(item&&(item.hidden===true||controlTargetHidden(item,concealed)))conceal(item);
    changed=concealed.size!==size;
  }while(changed);
  const publicBindings=[...originals,...normalized].filter(item=>!controlTargetHidden(item,concealed));
  function hiddenConnection(item){
    if(!item)return false;
    if(item.provider==='codex'&&UUID.test(item.sessionId||'')&&!known.has(controlIdentity(item.sessionId)))return true;
    if([item.sessionId,item.runId].some(id=>typeof id==='string'&&concealed.has(controlIdentity(id)))||
      ids.has(controlIdentity(item.owner)))return true;
    return owners.has(controlIdentity(item.owner))&&!publicBindings.some(row=>
      (row.source||'codex')===item.provider&&typeof item.sessionId==='string'&&
      [row.id,row.externalId,row.sessionId,row.threadId,row.native?.id].some(id=>typeof id==='string'&&controlIdentity(id)===controlIdentity(item.sessionId))&&
      controlIdentity(row.runId||row.activeTurnId||row.native?.activeTurnId||null)===controlIdentity(item.runId||null));
  }
  return {ids,connection:item=>connection(hiddenConnection(item)?{provider:item.provider}:item),
    hidden:row=>row.hidden===true||invalidLocal(row)||unverifiedReference(row)||controlTargetHidden(row,concealed)};
}
function projectControl(raw,{rows=installedRows,hidden=new Set(),workspace='all',projectIds=[]}={}){
  let normalized=[],error=null;
  try {normalized=rows(raw,controlHiddenIds(raw,hidden));}catch{error='관제 원본 어댑터가 준비되지 않았습니다.';}
  const privacy=controlPrivacy(raw,hidden,normalized);
  const connections=(Array.isArray(raw.sourceConnections)?raw.sourceConnections:[]).filter(item=>PROVIDERS.includes(item?.provider))
    .map(privacy.connection);
  const seen=new Set();
  const expected=connections.some(item=>item.provider==='codex');
  const items=normalized.filter(row=>PROVIDERS.includes(row?.source)&&typeof row.key==='string'&&row.key.length<=4096&&
    !privacy.hidden(row)&&!seen.has(row.key)&&(seen.add(row.key),true)&&
    (workspace==='all'||projectIds.includes(row.projectId))).map(row=>{
      const native=row.source==='codex'?codexSourceState(row.native||{},expected,privacy):null;
      return {
      key:row.key,source:row.source,provider:row.source,hostId:text(row.hostId || row.native?.hostId),
      externalId:text(row.externalId,2048),sessionId:text(row.sessionId || row.threadId || row.externalId,2048),
      runId:text(row.runId || row.native?.activeTurnId),instanceId:text(row.instanceId),startedAt:text(row.startedAt,40),
      workspaceIdentity:text(row.workspaceIdentity),ownerThreadId:row.ownerVerified===true?text(row.ownerThreadId):null,
      ownerVerified:row.ownerVerified===true,projectId:text(row.projectId),title:text(row.title,200),
      status:text(row.status,100),displayStatus:text(row.displayStatus,300),executionStatus:text(row.executionStatus,100),
      statusSource:text(row.statusSource,100),agentStatus:text(row.agentStatus,100),
      ...(row.source==='cursor-cloud'?{result:row.capabilities?.read===true&&typeof row.result==='string'&&
        Buffer.byteLength(row.result,'utf8')<=12000?row.result:null}:{}),
      observedAt:text(row.observedAt || row.native?.observedAt,40),connectedAt:text(row.connectedAt,40),
      sourceRevision:typeof row.sourceRevision==='number'&&Number.isSafeInteger(row.sourceRevision)?row.sourceRevision:text(row.sourceRevision),
      connectionState:native?.sourceConnection?.state||text(row.connectionState,60),fresh:row.fresh===true&&!native?.stale,
      ...(native?{sourceConnection:native.sourceConnection,stale:native.stale}:{}),
      readOnly:row.capabilities?.send!==true||row.ownerVerified!==true||native?.stale===true,
      capabilities:{read:row.capabilities?.read===true,send:row.capabilities?.send===true&&row.ownerVerified===true&&!native?.stale},
      // Original Codex identifiers remain distinct from provider identities.
      threadId:row.source==='codex'?text(row.externalId):null,
      activeTurnId:row.source==='codex'?text(row.native?.activeTurnId):null
    };});
  return {unifiedControl:{schema:1,rows:items,truncated:false,error},sourceConnections:connections};
}
function sameTarget(row,target){return row&&target&&['source','key','externalId','sessionId','runId','ownerThreadId','hostId','instanceId','startedAt','workspaceIdentity'].every(key=>row[key]===target[key]);}
function commandLedger(directory=path.join(os.homedir(),'Library','Application Support','CodexControlRoom','mobile-unified-commands')){
  const file=id=>{if(!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id))throw Error('invalid_operation');return path.join(directory,id+'.json');};
  function privateDirectory(){fs.mkdirSync(directory,{recursive:true,mode:0o700});const info=fs.lstatSync(directory);
    if(!info.isDirectory()||info.uid!==process.getuid()||(info.mode&0o077)||fs.realpathSync(directory)!==directory)throw Error('unsafe_command_ledger');}
  return {
    read(id){privateDirectory();try{const fd=fs.openSync(file(id),fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const info=fs.fstatSync(fd);
      if(!info.isFile()||info.uid!==process.getuid()||(info.mode&0o077)||info.size>16384)throw Error('unsafe_command_record');
      const value=JSON.parse(fs.readFileSync(fd,'utf8'));if(value.schema!==1||!value.target||typeof value.digest!=='string')throw Error('invalid_command_record');return value;
    }finally{fs.closeSync(fd);}}catch(error){if(error.code==='ENOENT')return null;throw error;}},
    reserve(id,value){privateDirectory();let fd;try{fd=fs.openSync(file(id),'wx',0o600);}catch(error){if(error.code==='EEXIST')return false;throw error;}
      try{fs.writeFileSync(fd,JSON.stringify(value));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
      const parent=fs.openSync(directory,'r');try{fs.fsyncSync(parent);}finally{fs.closeSync(parent);}return true;}
  };
}
function helperDigest(payload){
  const canonical='{'+Object.keys(payload).sort().map(key=>JSON.stringify(key)+': '+JSON.stringify(payload[key])).join(', ')+'}';
  return crypto.createHash('sha256').update(canonical).digest('hex');
}
function publicReceipt(value,record,operationId){
  if(value?.ok!==true)throw Error('receipt_unconfirmed');
  const receipt=value.receipt||value;
  if(value.digest!==undefined&&value.digest!==record.digest)throw Error('receipt_digest_mismatch');
  if(receipt.source!==undefined&&receipt.source!==record.target.source||receipt.externalId!==undefined&&receipt.externalId!==record.target.externalId||
    receipt.parentRunId!==undefined&&receipt.parentRunId!==record.target.runId||receipt.operationId!==undefined&&receipt.operationId!==operationId)throw Error('receipt_target_mismatch');
  const confirmed=receipt.state==='accepted'&&receipt.operationId===operationId&&receipt.source===record.target.source&&
    receipt.externalId===record.target.externalId&&receipt.parentRunId===record.target.runId;
  return {ok:true,operationId,state:confirmed?'accepted':'unknown',source:record.target.source,externalId:record.target.externalId,
    parentRunId:record.target.runId,runId:confirmed?text(receipt.runId):null};
}
async function executeControl(request,projection,{command=installedCommand,ledger=commandLedger(),hidden=new Set(),
  privacy=()=>({hidden:target=>controlTargetHidden(target,controlHiddenIds({},hidden))})}={}){
  if(!request||typeof request!=='object'||!['messages','send','receipt'].includes(request.action))throw Error('지원하지 않는 관제 요청입니다.');
  if(request.action==='messages')throw Error('이 출처의 대화 본문 조회 경로는 아직 지원되지 않습니다.');
  if(!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(request.operationId||''))throw Error('요청 식별자를 확인해 주세요.');
  if(privacy().hidden(request.target||{}))throw Error('숨긴 원본 작업에는 접근할 수 없습니다.');
  const checkedReceipt=async(payload,record)=>{
    const value=await command(payload);
    if(privacy().hidden(record.target))throw Error('숨긴 원본 작업에는 접근할 수 없습니다.');
    return publicReceipt(value,record,request.operationId);
  };
  if(request.action==='receipt'){
    const record=ledger.read(request.operationId);
    if(!record||!sameTarget(record.target,request.target))throw Error('원래 전송의 대상 정보를 확인해 주세요.');
    if(privacy().hidden(record.target))throw Error('숨긴 원본 작업에는 접근할 수 없습니다.');
    return checkedReceipt({action:'receipt',operationId:request.operationId},record);
  }
  const row=projection.unifiedControl.rows.find(row=>sameTarget(row,request.target));
  if(!row||row.source!=='cursor-cloud')throw Error('원본 작업의 식별자 또는 지원 경로를 확인해 주세요.');
  if(!row.capabilities.send||!row.ownerVerified||typeof request.text!=='string'||!request.text.trim()||request.text.length>32000)
    throw Error('원본 작업의 전송 권한 또는 입력을 확인해 주세요.');
  const payload={source:row.source,key:row.key,externalId:row.externalId,runId:row.runId,text:request.text};
  const target=Object.fromEntries(['source','key','externalId','sessionId','runId','ownerThreadId','hostId','instanceId','startedAt','workspaceIdentity'].map(key=>[key,row[key]]));
  const record={schema:1,target,digest:helperDigest(payload)};
  if(!ledger.reserve(request.operationId,record))throw Error('이 요청의 접수 상태를 먼저 확인해 주세요.');
  return checkedReceipt({action:'send',...payload,operationId:request.operationId},record);
}
module.exports={root,projectControl,executeControl,sameTarget,commandLedger,helperDigest,codexSourceState,controlHiddenIds,controlThreadReadable,controlIdentity,controlPrivacy};
