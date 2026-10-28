'use strict';
const SCHEMA='ccr.control-events/v1';
const MAX_FRAME_BYTES=32*1024*1024;
const GENERATION=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const forbidden=new Set(['__proto__','prototype','constructor']);
const record=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const revision=value=>Number.isSafeInteger(value)&&value>=0;
const copy=value=>JSON.parse(JSON.stringify(value));
function assertSafe(value){
  if(Array.isArray(value)){for(const item of value)assertSafe(item);return;}
  if(!record(value))return;
  for(const [key,item] of Object.entries(value)){
    if(forbidden.has(key))throw Error('이벤트에 허용되지 않는 키가 있습니다.');
    assertSafe(item);
  }
}
function validateEvent(event){
  if(!record(event)||event.schema!==SCHEMA||!GENERATION.test(event.generation)||
    !revision(event.revision)||!['snapshot','patch','heartbeat'].includes(event.type)||
    !Number.isFinite(Date.parse(event.emittedAt)))throw Error('관제 이벤트 형식 오류');
  assertSafe(event);
  if(event.type==='snapshot'&&(!record(event.snapshot)||event.snapshot.schemaVersion!==1))
    throw Error('관제 초기 상태 형식 오류');
  if(event.type==='patch'){
    if(!revision(event.baseRevision)||event.revision!==event.baseRevision+1||!record(event.set)||
      !Array.isArray(event.unset)||event.unset.some(key=>typeof key!=='string'||forbidden.has(key)))
      throw Error('관제 변경 순서 오류');
    for(const name of ['threads','catalog']){
      const rows=event[name];
      if(!record(rows)||!Array.isArray(rows.upsert)||!Array.isArray(rows.remove)||
        rows.upsert.some(row=>!record(row)||typeof row.id!=='string'||!row.id)||
        rows.remove.some(id=>typeof id!=='string'||!id))throw Error('대화 변경 형식 오류');
    }
    if(Object.hasOwn(event,'changes')){
      if(!Array.isArray(event.changes)||event.changes.length>10000||Object.keys(event.set).length||event.unset.length||
        ['threads','catalog'].some(name=>event[name].upsert.length||event[name].remove.length))throw Error('관제 필드 변경 형식 오류');
      for(const change of event.changes){
        if(!record(change)||!['add','replace','remove'].includes(change.op)||!Array.isArray(change.path)||
          !change.path.length||change.path.length>64||change.path.some(key=>
            !(typeof key==='string'||Number.isSafeInteger(key)&&key>=0)||forbidden.has(String(key)))||
          change.op!=='remove'&&!Object.hasOwn(change,'value'))throw Error('관제 필드 변경 경로 오류');
      }
    }
  }
  return event;
}
function applyRows(previous,{upsert,remove}){
  const rows=new Map((previous||[]).map(row=>[row.id,row]));
  for(const id of remove)rows.delete(id);
  for(const row of upsert)rows.set(row.id,row);
  return [...rows.values()];
}
function applyChanges(previous,changes){
  let result=previous;
  const writable=new WeakSet();
  const own=value=>{
    if(value===null||typeof value!=='object')throw Error('관제 필드 변경 대상 오류');
    if(writable.has(value))return value;
    const next=Array.isArray(value)?value.slice():{...value};writable.add(next);return next;
  };
  for(const change of changes){
    let parent=result=own(result);
    for(const key of change.path.slice(0,-1)){
      if(Array.isArray(parent)&&!Number.isSafeInteger(key)||!Object.hasOwn(parent,key))throw Error('관제 필드 변경 경로 누락');
      parent=parent[key]=own(parent[key]);
    }
    const key=change.path.at(-1),exists=Object.hasOwn(parent,key);
    if(Array.isArray(parent)){
      if(!Number.isSafeInteger(key)||key<0||key>parent.length||change.op!=='add'&&!exists)throw Error('관제 배열 변경 경로 오류');
      if(change.op==='add')parent.splice(key,0,copy(change.value));
      else if(change.op==='remove')parent.splice(key,1);else parent[key]=copy(change.value);
    }else{
      if(change.op!=='add'&&!exists)throw Error('관제 필드 변경 키 누락');
      if(change.op==='remove')delete parent[key];else parent[key]=copy(change.value);
    }
  }
  return result;
}
function fieldChanges(previous,next,{maxChanges=10000,maxDepth=64}={}){
  const changes=[];let exceeded=false;
  const add=change=>{if(changes.length===maxChanges)exceeded=true;else changes.push(change);};
  function walk(before,after,path){
    if(exceeded||before===after)return;
    if(path.length>maxDepth){exceeded=true;return;}
    if(Array.isArray(before)&&Array.isArray(after)&&before.length===after.length){
      for(let index=0;index<before.length;index++)walk(before[index],after[index],[...path,index]);
    }else if(record(before)&&record(after)){
      for(const key of Object.keys(before))if(!Object.hasOwn(after,key))add({op:'remove',path:[...path,key]});
      for(const [key,value]of Object.entries(after)){
        if(!Object.hasOwn(before,key))add({op:'add',path:[...path,key],value});
        else walk(before[key],value,[...path,key]);
      }
    }else add({op:'replace',path,value:after});
  }
  walk(previous,next,[]);
  return exceeded||changes.some(change=>!change.path.length||change.path.length>maxDepth)?null:changes;
}
function reduceEvent(current,event){
  validateEvent(event);
  if(event.type==='heartbeat')return {state:current,status:current&&current.generation===event.generation&&
    current.revision===event.revision?'heartbeat':'resync'};
  if(event.type==='snapshot'){
    if(current?.generation===event.generation&&event.revision<current.revision)
      return {state:current,status:'ignored'};
    return {state:{generation:event.generation,revision:event.revision,snapshot:copy(event.snapshot)},status:'applied'};
  }
  if(!current||current.generation!==event.generation)return {state:current,status:'resync'};
  if(event.revision<=current.revision)return {state:current,status:'ignored'};
  if(event.baseRevision!==current.revision)return {state:current,status:'resync'};
  if(Object.hasOwn(event,'changes')){
    const snapshot=applyChanges(current.snapshot,event.changes);
    if(snapshot.schemaVersion!==1)throw Error('관제 필드 변경 결과 형식 오류');
    return {state:{generation:event.generation,revision:event.revision,snapshot},status:'applied'};
  }
  const snapshot={...current.snapshot,...copy(event.set)};
  for(const key of event.unset)delete snapshot[key];
  for(const name of ['threads','catalog'])snapshot[name]=applyRows(snapshot[name],copy(event[name]));
  return {state:{generation:event.generation,revision:event.revision,snapshot},status:'applied'};
}
function rowsDiff(previous,next){
  const old=new Map((previous||[]).map(row=>[row.id,row]));
  const upsert=[];
  for(const row of next||[]){if(JSON.stringify(old.get(row.id))!==JSON.stringify(row))upsert.push(row);old.delete(row.id);}
  return {upsert,remove:[...old.keys()]};
}
function diffSnapshot(previous,next){
  const set={},unset=[];
  for(const [key,value] of Object.entries(next)){
    if(key==='threads'||key==='catalog')continue;
    if(JSON.stringify(previous[key])!==JSON.stringify(value))set[key]=value;
  }
  for(const key of Object.keys(previous))if(!Object.hasOwn(next,key))unset.push(key);
  return {set,unset,threads:rowsDiff(previous.threads,next.threads),catalog:rowsDiff(previous.catalog,next.catalog)};
}
function encode(event){validateEvent(event);const body=JSON.stringify(event)+'\n';
  if(Buffer.byteLength(body)>MAX_FRAME_BYTES)throw Error('관제 이벤트 크기 초과');return body;}
function createDecoder(onEvent,{maxBytes=MAX_FRAME_BYTES}={}){
  let fragments=[],size=0,tail=null,used=0;
  return chunk=>{
    const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);
    let start=0;
    while(start<bytes.length){
      const end=bytes.indexOf(10,start);
      const part=bytes.subarray(start,end<0?bytes.length:end);
      if(size+part.length>maxBytes)throw Error('관제 이벤트 크기 초과');
      let offset=0;
      while(offset<part.length){
        if(!tail||used===tail.length){tail=Buffer.allocUnsafe(Math.min(65536,maxBytes-size));used=0;fragments.push(tail);}
        const count=Math.min(part.length-offset,tail.length-used);
        part.copy(tail,used,offset,offset+count);used+=count;size+=count;offset+=count;
      }
      if(end<0)return;
      if(tail)fragments[fragments.length-1]=tail.subarray(0,used);
      const line=fragments.length===1?fragments[0]:Buffer.concat(fragments,size);
      fragments=[];size=0;tail=null;used=0;start=end+1;
      if(line.length)onEvent(validateEvent(JSON.parse(line.toString('utf8'))));
    }
  };
}
const ControlEvents={SCHEMA,MAX_FRAME_BYTES,GENERATION,validateEvent,reduceEvent,diffSnapshot,fieldChanges,applyRows,encode,createDecoder};
if(typeof module!=='undefined'&&module.exports)module.exports=ControlEvents;
else globalThis.ControlEvents=ControlEvents;
