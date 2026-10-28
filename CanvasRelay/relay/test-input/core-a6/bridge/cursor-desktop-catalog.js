'use strict';
const os=require('node:os');
const path=require('node:path');
const {fileURLToPath}=require('node:url');
const {CursorDesktopClient}=require('./cursor-desktop-client');

const LIMITS=Object.freeze({instances:32,uris:32,ids:32,bytes:256*1024,concurrency:4,timeoutMs:15000,intervalMs:30000});
const UUID=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const THREAD=/^(?:bc-)?[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const STATES=['observed','stale','unavailable'];
function normalizeObservations(value){
  if(!Array.isArray(value) || value.length>LIMITS.instances || Buffer.byteLength(JSON.stringify(value))>LIMITS.bytes)
    throw Error('invalid-desktop-catalog');
  const seen=new Set();
  return value.map(row=>{
    if(!row || !UUID.test(row.instanceId || '') || !/^[a-f0-9]{64}$/.test(row.workspaceIdentity || '') ||
      !STATES.includes(row.state) || !(row.observedAt===null || typeof row.observedAt==='string' && Number.isFinite(Date.parse(row.observedAt))) ||
      row.state==='observed' && row.observedAt===null ||
      !Array.isArray(row.workspaceUris) || row.workspaceUris.length>LIMITS.uris ||
      !row.workspaceUris.every(uri=>{
        if(typeof uri!=='string' || uri.length>2048)return false;
        try{
          const u=new URL(uri);
          return u.protocol==='file:' && !u.host && !u.username && !u.password && !u.search && !u.hash &&
            path.isAbsolute(fileURLToPath(u));
        }catch{return false;}
      }) || !Array.isArray(row.selectedIds) || row.selectedIds.length>LIMITS.ids ||
      !row.selectedIds.every(id=>typeof id==='string' && THREAD.test(id)) ||
      new Set(row.selectedIds.map(id=>id.toLowerCase())).size!==row.selectedIds.length)throw Error('invalid-desktop-observation');
    const instanceId=row.instanceId.toLowerCase();
    if(seen.has(instanceId))throw Error('duplicate-desktop-instance');seen.add(instanceId);
    return {instanceId,workspaceIdentity:row.workspaceIdentity,workspaceUris:[...row.workspaceUris],
      selectedIds:[...row.selectedIds],observedAt:row.observedAt,state:row.state};
  });
}

class CursorDesktopCatalog {
  constructor({clock=Date.now,timeoutMs=LIMITS.timeoutMs,createClient=()=>new CursorDesktopClient({
    stateRoot:path.join(os.homedir(),'.local/state/ccr-cursor-desktop-catalog'),timeoutMs:1500})}={}){
    if(!Number.isSafeInteger(timeoutMs) || timeoutMs<1 || timeoutMs>LIMITS.timeoutMs)throw Error('invalid-desktop-timeout');
    Object.assign(this,{clock,timeoutMs,createClient});this.lastRead=-Infinity;this.closed=false;
    this.generations=new Map();
  }
  read(){
    if(this.closed)return Promise.reject(Error('desktop-catalog-closed'));
    if(this.pending)return this.pending;
    if(this.value && this.clock()-this.lastRead>=0 && this.clock()-this.lastRead<LIMITS.intervalMs)return Promise.resolve(this.value);
    this.lastRead=this.clock();
    this.pending=this.collect().finally(()=>{this.pending=null;});return this.pending;
  }
  fallback(){
    return {state:this.value?'stale':'unavailable',observedAt:this.value?.observedAt || null,
      rejectedCount:this.value?.rejectedCount || 0,
      observations:(this.value?.observations || []).map(row=>({...row,state:row.observedAt?'stale':'unavailable'}))};
  }
  async collect(){
    const job={cancelled:false};this.job=job;let timer,client;
    try{
      client=this.createClient();let closing;
      this.closeClient=()=>closing ||= Promise.resolve().then(()=>client.close());
      const value=await Promise.race([this.load(client,job),new Promise((_,reject)=>{
        timer=setTimeout(()=>{job.cancelled=true;reject(Error('desktop-catalog-timeout'));},this.timeoutMs);
      })]);
      this.value=value;
    }catch{this.value=this.fallback();}
    finally{clearTimeout(timer);job.cancelled=true;if(client)await this.closeClient();this.closeClient=null;this.job=null;}
    if(this.closed)throw Error('desktop-catalog-closed');
    return this.value;
  }
  async load(client,job){
    const result=await client.discover();
    if(!Array.isArray(result.instances) || !Array.isArray(result.rejected) ||
      result.instances.length+result.rejected.length>LIMITS.instances)throw Error('invalid-desktop-discovery');
    const descriptors=normalizeObservations(result.instances.map(instance=>({...instance,selectedIds:[],observedAt:null,state:'unavailable'})));
    const previous=new Map((this.value?.observations || []).map(row=>[row.instanceId,row]));
    const observations=new Array(descriptors.length);let next=0;
    const workers=Array.from({length:Math.min(LIMITS.concurrency,descriptors.length)},async()=>{
      while(!job.cancelled && next<descriptors.length){
        const index=next++,descriptor=descriptors[index];
        try{
          const value=await client.observe(descriptor.instanceId);
          if(value.instance.instanceId.toLowerCase()!==descriptor.instanceId || value.instance.workspaceIdentity!==descriptor.workspaceIdentity ||
            value.instance.startedAt!==result.instances[index].startedAt || value.instance.pid!==result.instances[index].pid ||
            JSON.stringify(value.instance.workspaceUris)!==JSON.stringify(descriptor.workspaceUris))throw Error('desktop-identity-changed');
          observations[index]=normalizeObservations([{...descriptor,selectedIds:value.selectedIds,
            observedAt:new Date(this.clock()).toISOString(),state:'observed'}])[0];
        }catch{
          const old=previous.get(descriptor.instanceId);
          const generation=this.generations.get(descriptor.instanceId),current=result.instances[index];
          observations[index]=generation?.startedAt===current.startedAt && generation?.pid===current.pid &&
            old?.workspaceIdentity===descriptor.workspaceIdentity &&
            JSON.stringify(old.workspaceUris)===JSON.stringify(descriptor.workspaceUris) ?
            {...old,state:old.observedAt?'stale':'unavailable'} : descriptor;
        }
      }
    });
    await Promise.all(workers);
    if(job.cancelled)throw Error('desktop-catalog-stopped');
    for(const rejected of result.rejected){
      const old=previous.get(rejected.instanceId?.toLowerCase());
      if(old)observations.push({...old,state:old.observedAt?'stale':'unavailable'});
    }
    const normalized=normalizeObservations(observations);
    const complete=!result.rejected.length && normalized.every(row=>row.state==='observed');
    this.generations=new Map(normalized.map(row=>[row.instanceId,
      result.instances.find(instance=>instance.instanceId.toLowerCase()===row.instanceId) || this.generations.get(row.instanceId)]));
    return {state:complete?'observed':normalized.some(row=>row.observedAt)?'stale':'unavailable',
      observedAt:complete?new Date(this.clock()).toISOString():this.value?.observedAt || null,
      rejectedCount:result.rejected.length,observations:normalized};
  }
  async close(){
    this.closed=true;if(this.job)this.job.cancelled=true;
    if(this.closeClient)await this.closeClient();
    await this.pending?.catch(()=>{});
  }
}
module.exports={CursorDesktopCatalog,normalizeObservations,LIMITS};
