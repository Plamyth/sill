'use strict';
const {randomUUID}=require('node:crypto');
const {fileURLToPath,pathToFileURL}=require('node:url');
const path=require('node:path');
const HEADER_ID=/^(?:(?:[bB][cC]-|draft-)?[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|empty-state-draft|(?:task-|tile-draft-)[a-zA-Z0-9_-]+)$/;
const RETRYABLE=new Set(['response-timeout','request-busy']);
const ERRORS=Object.freeze({
  'history-unavailable':'이력 조회 연결 준비 전', 'history-stale':'관제 연결 재확인 필요',
  'cursor-expired':'페이지 유효 시간 만료 · 처음부터 다시 조회',
  'cursor-source-changed':'원본 변경 · 처음부터 다시 조회', 'source-changed':'조회 중 원본 변경',
  'source-unavailable':'원본 이력 없음', 'source-busy':'원본 읽기 상태 미확인',
  'response-timeout':'응답 미확인 · 같은 요청 다시 확인', 'request-busy':'다른 조회 처리 중 · 같은 요청 다시 확인',
  'request-expired':'조회 요청 만료', 'request-conflict':'요청 조건 충돌',
  'schema-unavailable':'원본 저장 형식 미지원', 'invalid-metadata':'원본 식별자 오류',
  'read-timeout':'원본 읽기 시간 초과', 'read-failed':'원본 읽기 실패',
  'output-limit':'응답 크기 상한 초과', 'invalid-response':'이력 응답 형식 미확인',
  'read-only-enforcement-unavailable':'읽기 전용 실행 경계 미지원', 'unsafe-path':'원본 경로 검증 실패'});
const fail=()=>{throw Object.assign(Error('invalid-response'),{code:'invalid-response'});};
const text=(value,max)=>typeof value==='string'&&Buffer.byteLength(value)<=max&&!/[\u0000-\u001f\u007f]/.test(value);
function localUri(uri){
  try{const url=new URL(uri),file=fileURLToPath(url);return text(uri,2048)&&url.protocol==='file:'&&!url.hostname&&!url.search&&!url.hash&&
    !url.username&&!url.password&&path.normalize(file)===file&&pathToFileURL(file).href===uri;}catch{return false;}
}
function pageValue(value,now){
  if(value?.ok!==true||value.readOnly!==true)fail();
  const page=value.page;
  if(!page||!Array.isArray(page.items)||page.items.length>100||typeof page.complete!=='boolean'||
    !Number.isFinite(Date.parse(page.observedAt))||Math.abs(now-Date.parse(page.observedAt))>90000||
    (page.complete?page.nextCursor!==null:!text(page.nextCursor,1024)||!/^[A-Za-z0-9_-]+$/.test(page.nextCursor)||!page.items.length))fail();
  const items=page.items.map(item=>{
    if(!item||Object.keys(item).some(key=>!['composerId','title','workspaceUris','createdAt','lastUpdatedAt','isArchived','isDraft'].includes(key))||
      !text(item.composerId,128)||!HEADER_ID.test(item.composerId)||item.title!==null&&!text(item.title,512)||
      !['createdAt','lastUpdatedAt'].every(key=>item[key]===null||Number.isSafeInteger(item[key])&&item[key]>=0)||
      !['isArchived','isDraft'].every(key=>item[key]===null||typeof item[key]==='boolean')||
      item.workspaceUris!==undefined&&(!Array.isArray(item.workspaceUris)||!item.workspaceUris.length||item.workspaceUris.length>32||!item.workspaceUris.every(localUri)))fail();
    return {...item,observedAt:page.observedAt};
  });
  return {...page,items};
}
class CursorHistoryPages{
  constructor({request,onChange=()=>{},clock=Date.now}){
    this.request=request;this.onChange=onChange;this.clock=clock;this.pages=[];this.initialized=false;this.complete=false;this.loading=false;this.error=null;this.nextCursor=null;this.pageCount=0;this.closed=false;
  }
  state(){return {items:this.pages.flatMap(page=>page.items),firstPage:this.pages[0]?.index||0,lastPage:this.pageCount,
    initialized:this.initialized,loading:this.loading,error:this.error,complete:this.complete,
    allRetained:this.complete&&this.pages[0]?.index===1,canRetry:RETRYABLE.has(this.error),hasNext:!this.complete&&!!this.nextCursor};}
  ensure(){return !this.initialized?this.run(5):this.pending||Promise.resolve();}
  next(){return this.complete||this.error?Promise.resolve():this.run(1);}
  retry(){return RETRYABLE.has(this.error)&&this.lastRequest?this.run(1,false,true):Promise.resolve();}
  refresh(){return RETRYABLE.has(this.error)?Promise.resolve():this.run(5,true);}
  run(count,reset=false,retry=false){
    if(this.closed)return Promise.resolve();if(this.pending)return this.pending;
    this.initialized=true;
    this.pending=Promise.resolve().then(async()=>{
      if(this.closed)return;this.loading=true;
      if(reset){this.pages=[];this.nextCursor=null;this.complete=false;this.pageCount=0;this.lastRequest=null;}
      this.error=null;this.onChange();
      try{
        for(let n=0;n<count&&!this.complete&&!this.closed;n++){
          const request=retry&&n===0?this.lastRequest:{action:'cursor-history-page',requestId:randomUUID(),pageSize:100,cursor:this.nextCursor};
          this.lastRequest=request;const reply=await this.request(request);if(this.closed)return;
          const page=pageValue(reply,this.clock());
          let previous=this.pages.at(-1)?.items.at(-1)?.composerId||'';
          for(const item of page.items){if(item.composerId<=previous)fail();previous=item.composerId;}
          if(!page.complete&&page.nextCursor===request.cursor)fail();
          this.pages.push({items:page.items,index:++this.pageCount});if(this.pages.length>5)this.pages.shift();
          this.nextCursor=page.nextCursor;this.complete=page.complete;this.lastRequest=null;this.onChange();
        }
      }catch(error){if(!this.closed)this.error=Object.hasOwn(ERRORS,error.code)?error.code:'invalid-response';}
    }).finally(()=>{this.pending=null;this.loading=false;if(!this.closed)this.onChange();});return this.pending;
  }
  close(){this.closed=true;this.pages=[];this.lastRequest=null;}
}
module.exports={CursorHistoryPages,ERRORS,localUri,pageValue};
