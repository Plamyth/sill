'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict'),crypto=require('node:crypto'),child=require('node:child_process');
const {createServer}=require('../../CanvasRelay/relay/server'),{ObsidianVault}=require('../../CanvasRelay/relay/obsidian-vault'),w=require('../../CanvasRelay/relay/canvas-document');
const {document,page,body,base,png}=require('../../CanvasRelay/relay/test-input/document-fixture.cjs');
const root=path.resolve(process.argv[2]),cfg=JSON.parse(fs.readFileSync(path.join(root,'settings.json'))),vaultRoot=path.join(root,'vault');fs.mkdirSync(vaultRoot);
const server=createServer({token:cfg.token,vaultRoot,store:path.join(root,'packets'),snapshotPath:path.join(root,'absent-snapshot'),hiddenPath:path.join(root,'absent-hidden'),deliveryReady:()=>false,deliver:()=>{throw Error('External delivery forbidden');}});
const requests=[],children=[],wireFixtures=[];let port,inject=null,delay=null;
const sha=w.sha,gone=pid=>{try{process.kill(pid,0);return false;}catch(e){return e.code==='ESRCH';}};
child.execFileSync=function(program,args,options){
 if(program!=='/usr/bin/python3'||!args[0].endsWith('/CanvasRelay/relay/vault-note-exchange.py'))throw Error('Unexpected child');
 if(inject&&args[2]===path.join(vaultRoot,inject.path)) {
  const job=inject;inject=null;const bytes=Buffer.concat([fs.readFileSync(args[2]),Buffer.from(job.suffix)]);
  const code="const fs=require('node:fs');const f=fs.openSync(process.argv[1],fs.constants.O_WRONLY|fs.constants.O_NOFOLLOW),b=Buffer.from(process.argv[2],'base64');try{fs.writeSync(f,b,0,b.length,0);fs.ftruncateSync(f,b.length);fs.fsyncSync(f);}finally{fs.closeSync(f);}";
  const p=child.spawnSync(process.execPath,['-e',code,args[2],bytes.toString('base64')]);children.push({role:'external-fixture-writer',pid:p.pid,exitCode:p.status,pidGone:gone(p.pid)});assert.equal(p.status,0);
 }
 const p=child.spawnSync(program,args,options);children.push({role:'atomic-exchange',pid:p.pid,exitCode:p.status,pidGone:gone(p.pid),helperSHA256:sha(fs.readFileSync(args[0]))});if(p.status!==0)throw p.error||Error('Exchange failed');return p.stdout;
};
const actual=server.listeners('request')[0];server.removeAllListeners('request');server.on('request',(req,res)=>{
 const row={method:req.method,path:req.url,status:null};requests.push(row);res.once('finish',()=>row.status=res.statusCode);
 if(delay&&req.method==='PUT'&&req.url===delay){delay=null;const end=res.end.bind(res);res.end=(...args)=>{row.handlerStatus=res.statusCode;row.responseDelayed=true;setTimeout(()=>{if(!res.destroyed)end(...args);},500);return res;};}
 actual(req,res);
});
function request(method,route,value,{expected=200,auth=true,timeout=120000,raw=false}={}){
 return new Promise((resolve,reject)=>{
  const data=value===undefined?null:raw?value:Buffer.from(JSON.stringify(value));
  const req=http.request({hostname:'127.0.0.1',port,path:route,method,headers:{...(auth?{'X-Canvas-Token':cfg.token}:{}),...(data?{'content-type':'application/json','content-length':data.length}:{})}},res=>{const chunks=[];let n=0;res.on('data',b=>{n+=b.length;if(n>65*1024*1024){res.destroy();reject(Error('Response exceeds bound'));}else chunks.push(b);});res.on('end',()=>{try{assert.equal(res.statusCode,expected);const bytes=Buffer.concat(chunks),response=JSON.parse(bytes);if(cfg.wireFixturesOnly)wireFixtures.push({method,path:route,status:res.statusCode,request:value??null,response,responseJSONBase64:bytes.toString('base64'),responseSha256:sha(bytes)});resolve(response);}catch(e){reject(e);}});});
  req.setTimeout(timeout,()=>req.destroy(Error('owned-request-timeout')));req.on('error',reject);
  if(data){let index=0;const write=()=>{while(index<data.length){const next=Math.min(index+65536,data.length);const ready=req.write(data.subarray(index,next));index=next;if(!ready){req.once('drain',write);return;}}req.end();};write();}else req.end();
 });
}
function sizedPNG(size){const payload=Buffer.alloc(size-png.length-12,65),type=Buffer.from('tEXt'),chunk=Buffer.alloc(payload.length+12);chunk.writeUInt32BE(payload.length);type.copy(chunk,4);payload.copy(chunk,8);const z=require('node:zlib');let crc;if(z.crc32)crc=z.crc32(Buffer.concat([type,payload]));else{const table=Array.from({length:256},(_,n)=>{for(let i=0;i<8;i++)n=(n>>>1)^((n&1)?0xedb88320:0);return n>>>0;});let n=-1;for(const b of Buffer.concat([type,payload]))n=(n>>>8)^table[(n^b)&255];crc=(n^-1)>>>0;}chunk.writeUInt32BE(crc,payload.length+8);return Buffer.concat([png.subarray(0,-12),chunk,png.subarray(-12)]);}
async function run(){
 const checks=[];await request('GET','/vault/entries',undefined,{auth:false,expected:401});
 const caps=await request('GET','/vault/canvas/capabilities');assert.equal(caps.document.maxRequestBytes,w.MAX_DOCUMENT_REQUEST_BYTES);assert.equal(caps.document.wholeDocument,true);
 assert.equal((await request('GET','/delivery/ready')).available,false);
 const d=document(),endpoint='/vault/document?id='+d.id;
 if(cfg.wireFixturesOnly){d.pages[1].nodes[0].kind='note';d.pages[1].annotations.push({id:crypto.randomUUID(),nodeId:d.pages[1].nodes[0].id,author:'ccr.sill.card-tag/v1',text:'#업무'},{id:crypto.randomUUID(),nodeId:d.pages[1].nodes[0].id,author:'카드 태그',text:'사람이 쓴 원문 e\u0301\r\n#주석'});}
 const first=await request('PUT',endpoint,body(d));const read=await request('GET',endpoint);assert.equal(read.documentJSONBase64,body(d).documentJSONBase64);
 d.pages.reverse();d.pages[1].nodes[0].text+=' HTTP 반대방향';d.revision++;
 const next=await request('PUT',endpoint,body(d,base(first)));assert.equal((await request('GET',endpoint)).documentJSONBase64,body(d).documentJSONBase64);
 assert.equal(new ObsidianVault(vaultRoot).document(d.id).documentSha256,next.documentSha256);
 await request('PUT',endpoint,body(d,base(first)),{expected:409});
 for(const p of d.pages)await request('PUT','/vault/canvas?id='+p.id,{revision:p.revision,sceneJSONBase64:Buffer.from(JSON.stringify(p)).toString('base64'),imagePNGBase64:png.toString('base64'),baseSha256:null},{expected:409});
 await request('PUT','/vault/note?path='+encodeURIComponent(next.path),{baseSha256:next.noteSha256,text:'selected only'},{expected:409});
 checks.push('actualHTTP 전체 문서·비선택 페이지·순서·역방향·freshVault·stale/scene/MD 우회409');
 d.revision++;delay=endpoint;
 await assert.rejects(request('PUT',endpoint,body(d,base(next)),{timeout:50}),/owned-request-timeout/);
 const acknowledged=await request('GET',endpoint);assert.equal(acknowledged.documentSha256,body(d).documentSha256);
 checks.push('성공 ACK 유실 뒤 전체GET 재확인·중복PUT0');
 d.revision++;inject={path:acknowledged.path,suffix:'\r\n보존 외부 원문 e\u0301\r\n'};delay=endpoint;
 await assert.rejects(request('PUT',endpoint,body(d,base(acknowledged)),{timeout:50}),/owned-request-timeout/);
 const held=await request('GET',endpoint,undefined,{expected:409});assert.equal(held.code,'note_reconciliation_required');
 const conflictPath='/vault/document/conflict?id='+d.id,state=await request('GET',conflictPath);assert.equal(state.materials.active.sha256,state.materials.proposal.sha256);
 const selected=await request('GET',conflictPath+'&recoveryID='+state.recoveryID+'&material=displaced&sha256='+state.materials.displaced.sha256);assert.equal(selected.documentSha256,state.materials.displaced.document.documentSha256);
 const resolveBody={recoveryID:state.recoveryID,expected:state.expected,decision:'useDisplaced'};
 const resolved=await request('PUT',conflictPath,resolveBody);assert(resolved.resolved);assert.deepEqual(await request('PUT',conflictPath,resolveBody),resolved);
 const reopened=await request('GET',endpoint);assert.equal(reopened.documentSha256,state.materials.displaced.document.documentSha256);d.revision++;
 await request('PUT',endpoint,body(d,base(reopened)));
 checks.push('409 ACK 유실→active=proposal여도GET barrier→고정후보→명시useDisplaced→재열기/멱등/정상쓰기');
 if(cfg.wireFixturesOnly){assert(children.every(c=>c.exitCode===0&&c.pidGone));return {passed:true,actualHTTP:true,urlProtocolMock:false,checks,requests,children,wireFixtures,maximumValidRequestBytes:null,maximumBoundaryNotRepeated:true,legacySceneLimitBytes:13*1024*1024,externalEffects:0};}
 // Maximal valid wire uses all128 pages,16MiB JSON,32MiB PNGs and worst base64 padding.
 const big=document();big.pages=Array.from({length:128},page);big.activePageID=big.pages[0].id;
 const seed=await request('PUT','/vault/document?id='+big.id,body(big));big.revision++;
 let remaining=w.DOC_BYTES-Buffer.byteLength(JSON.stringify(big));
 for(const p of big.pages){const add=Math.min(remaining,w.SCENE_BYTES-Buffer.byteLength(JSON.stringify(p)));p.nodes[0].text+='x'.repeat(add);remaining-=add;if(!remaining)break;}
 assert.equal(remaining,0);assert.equal(Buffer.byteLength(JSON.stringify(big)),w.DOC_BYTES);
 let tiny=png.length+12;while(tiny%3!==1)tiny++;const small=sizedPNG(tiny),large=sizedPNG(w.PREVIEW_BYTES-127*tiny),images=Array(128).fill(small);images[0]=large;
 const max=body(big,base(seed),images),raw=Buffer.from(JSON.stringify(max));assert.equal(raw.length,w.MAX_DOCUMENT_REQUEST_BYTES);
 const maxSaved=await request('PUT','/vault/document?id='+big.id,raw,{raw:true});assert.equal(maxSaved.documentSha256,max.documentSha256);
 assert.equal(new ObsidianVault(vaultRoot).document(big.id).pages.length,128);
 const before=fs.readFileSync(path.join(vaultRoot,maxSaved.path));
 const tooLarge=await request('PUT','/vault/document?id='+big.id,Buffer.concat([raw,Buffer.from(' ')]),{raw:true,expected:413});assert.equal(tooLarge.code,'document_too_large');assert.equal(tooLarge.publicationAttempted,false);assert(fs.readFileSync(path.join(vaultRoot,maxSaved.path)).equals(before));
 checks.push('실제67139536-byte 유효 PUT와 +1-byte413·정본유지·모든128페이지/16MiB/32MiB 재열기');
 assert(children.every(c=>c.exitCode===0&&c.pidGone));
 return {passed:true,actualHTTP:true,urlProtocolMock:false,checks,requests,children,maximumValidRequestBytes:raw.length,legacySceneLimitBytes:13*1024*1024,externalEffects:0};
}
const stop=()=>{server.closeAllConnections();server.close(()=>process.exit(0));};process.once('SIGTERM',stop);process.once('SIGINT',stop);setTimeout(stop,cfg.ttlSeconds*1000).unref();
server.listen(0,'127.0.0.1',()=>{port=server.address().port;fs.writeFileSync(path.join(root,'ready.json'),JSON.stringify({pid:process.pid,port,host:'127.0.0.1'}));const wait=setInterval(()=>{if(!fs.existsSync(path.join(root,'go')))return;clearInterval(wait);run().then(r=>fs.writeFileSync(path.join(root,'result.json'),JSON.stringify(r))).catch(e=>fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({passed:false,error:e.stack,requests,children})));},50);});
