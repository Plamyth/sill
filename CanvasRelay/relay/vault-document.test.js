'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto'),child=require('node:child_process');
const {ObsidianVault}=require('./obsidian-vault'),wire=require('./canvas-document');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const uuid=()=>crypto.randomUUID(),sha=wire.sha;
function page(){const a=uuid(),b=uuid();return {schemaVersion:3,id:uuid(),revision:1,width:2048,height:1536,drawingBase64:'',strokes:[],nodes:[{id:a,kind:'ellipse',frame:{x:30,y:40,width:180,height:100},text:'원본 e\u0301 👩🏽‍💻',confidence:'confirmed',sourceStrokeIds:[],rotationDegrees:25},{id:b,kind:'line',frame:{x:250,y:120,width:120,height:40},text:'선',confidence:'proposal',sourceStrokeIds:[]}],links:[{id:uuid(),from:a,to:b,label:'관계',kind:'general',fromAnchor:{side:'right',offset:0.5}}],annotations:[{id:uuid(),nodeId:a,text:'일반 주석\r\n#원문',author:'사용자'}]};}
function document(){const pages=[page(),page()];return {format:'ccr.canvas-document',version:1,id:uuid(),revision:1,activePageID:pages[0].id,pages};}
function body(d,base=null,images=d.pages.map(()=>png)) {const bytes=Buffer.from(JSON.stringify(d));return {base,documentJSONBase64:bytes.toString('base64'),documentSha256:sha(bytes),pages:d.pages.map((p,i)=>({id:p.id,drawingSha256:sha(Buffer.from(p.drawingBase64,'base64')),previewSha256:sha(images[i]),previewPNGBase64:images[i].toString('base64')}))};}
const base=s=>Object.fromEntries(['noteSha256','documentSha256','manifestSha256'].map(k=>[k,s[k]]));
function fixture(t){const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'ccr-document-')));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));const d=document();return {root,d,vault:new ObsidianVault(root)};}
function atExchange(file,callback,run){const exec=child.execFileSync;let fired=false;child.execFileSync=function(program,args,...rest){if(!fired&&args?.[0]?.endsWith('vault-note-exchange.py')&&args[2]===file){fired=true;callback(program,args);}return exec.call(this,program,args,...rest);};try{const result=run();assert(fired);return result;}finally{child.execFileSync=exec;}}
function fault(f,decision='keepCurrent'){
 const first=f.vault.saveDocument(f.d.id,body(f.d)),file=path.join(f.root,first.path),original=fs.readFileSync(file);f.d.revision++;
 atExchange(file,()=>child.execFileSync(process.execPath,[path.join(__dirname,'test-input/vault-external-writer.cjs'),file,Buffer.from(original+'\r\n외부 메모\r\n').toString('base64'),'in-place']),()=>assert.throws(()=>f.vault.saveDocument(f.d.id,body(f.d,base(first))),{status:409,code:'note_reconciliation_required'}));
 const state=new ObsidianVault(f.root).documentConflict(f.d.id);return {first,state,file,original};
}

test('전체 문서·비선택 페이지·순서·자산과 메모를 정확 재열고 전체 CAS를 적용한다',t=>{
 const f=fixture(t),input=body(f.d),saved=f.vault.saveDocument(f.d.id,input),file=path.join(f.root,saved.path);
 assert.equal(new ObsidianVault(f.root).document(f.d.id).documentJSONBase64,input.documentJSONBase64);
 const old=fs.readFileSync(file),suffix='\ufeff\r\n원문 e\u0301 [[other.md]]\r\n';fs.writeFileSync(file,Buffer.concat([old,Buffer.from(suffix)]));const read=f.vault.document(f.d.id);
 f.d.pages[1].nodes[0].text+=' 비선택 변경';f.d.pages.reverse();f.d.revision++;
 const next=f.vault.saveDocument(f.d.id,body(f.d,base(read))),fresh=new ObsidianVault(f.root).document(f.d.id);
 assert.equal(fresh.documentJSONBase64,body(f.d).documentJSONBase64);assert.deepEqual(fresh.pages.map(p=>p.id),f.d.pages.map(p=>p.id));assert(fs.readFileSync(file).subarray(-Buffer.byteLength(suffix)).equals(Buffer.from(suffix)));
 assert.throws(()=>f.vault.saveDocument(f.d.id,body(f.d,base(saved))),{status:409,code:'document_stale'});
 assert.equal(new ObsidianVault(f.root).document(f.d.id).noteSha256,next.noteSha256);
 assert(fs.existsSync(path.join(f.root,'CCR Documents/Assets',f.d.id,saved.generation,'document.json')));
});

test('nested 미래 필드와 미지원 버전/종류/참조는 비선택 페이지에서도 전체 거부하며 파일 쓰기0이다',t=>{
 const f=fixture(t),targets=[d=>d.future=1,d=>d.pages[1].future=1,d=>d.pages[1].nodes[0].futureRequiredPayload={raw:1},d=>d.pages[1].links[0].futureRequiredPayload={raw:1},d=>d.pages[1].annotations[0].futureRequiredPayload={raw:1},d=>d.pages[1].nodes[0].frame.future=1,d=>d.pages[1].links[0].fromAnchor.future=1,d=>d.version=2,d=>d.pages[1].schemaVersion=4,d=>d.pages[1].nodes[0].kind='future',d=>d.pages[1].links[0].from=uuid(),d=>d.pages[1].annotations[0].nodeId=uuid(),d=>d.pages[1].id=d.pages[0].id,d=>d.activePageID=uuid()];
 for(const mutate of targets){const copy=structuredClone(f.d);mutate(copy);assert.throws(()=>f.vault.saveDocument(copy.id,body(copy)),{status:400,code:'invalid_document'});assert.deepEqual(fs.readdirSync(f.root),[]);}
});

test('미리보기만 바뀌어도 manifest/note CAS가 바뀌고 원본 JSON SHA는 유지된다',t=>{
 const f=fixture(t),first=f.vault.saveDocument(f.d.id,body(f.d));
 const zlib=require('node:zlib'),crc=b=>{let c=-1;for(const v of b){c^=v;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}return(c^-1)>>>0;};
 const type=Buffer.from('tEXt'),payload=Buffer.from('자체 preview 메타데이터'),chunk=Buffer.alloc(12+payload.length);chunk.writeUInt32BE(payload.length);type.copy(chunk,4);payload.copy(chunk,8);chunk.writeUInt32BE(crc(Buffer.concat([type,payload])),8+payload.length);const changed=Buffer.concat([png.subarray(0,-12),chunk,png.subarray(-12)]);
 const second=f.vault.saveDocument(f.d.id,body(f.d,base(first),[png,changed]));assert.equal(first.documentSha256,second.documentSha256);assert.notEqual(first.manifestSha256,second.manifestSha256);assert.notEqual(first.noteSha256,second.noteSha256);assert.throws(()=>f.vault.saveDocument(f.d.id,body(f.d,base(first))),{status:409});
});

for(const decision of ['keepCurrent','useDisplaced'])test(`typed409 뒤 명시 ${decision}와 전체 재열기·멱등성·정상쓰기`,t=>{
 const f=fixture(t),{state,file}=fault(f);
 for(const run of [()=>new ObsidianVault(f.root).document(f.d.id),()=>f.vault.saveDocument(f.d.id,body(f.d)),()=>f.vault.note('CCR Documents/'+f.d.id+'.md')])assert.throws(run,{status:409,code:'note_reconciliation_required'});
 assert.equal(state.materials.active.sha256,state.materials.proposal.sha256);assert(state.materials.base.validDocument&&state.materials.displaced.validDocument&&state.materials.proposal.validDocument);
 const selected=state.materials[decision==='keepCurrent'?'active':'displaced'];const proposal=f.vault.documentConflict(f.d.id,{recoveryID:state.recoveryID,material:'proposal',sha256:state.materials.proposal.sha256});assert.equal(proposal.documentSha256,state.materials.proposal.document.documentSha256);
 const request={recoveryID:state.recoveryID,expected:state.expected,decision},resolved=new ObsidianVault(f.root).resolveDocumentConflict(f.d.id,request);assert(resolved.resolved);assert.equal(sha(fs.readFileSync(file)),selected.sha256);assert.deepEqual(f.vault.resolveDocumentConflict(f.d.id,request),resolved);
 assert.throws(()=>f.vault.resolveDocumentConflict(f.d.id,{...request,decision:decision==='keepCurrent'?'useDisplaced':'keepCurrent'}),{status:409});
 const current=f.vault.document(f.d.id);f.d.revision++;f.vault.saveDocument(f.d.id,body(f.d,base(current)));
 assert(fs.existsSync(path.join(f.root,'.ccr-save-'+state.recoveryID,'base.md')));
});

test('같은 UUID와 페이지의 단일scene/일반MD/hardlink 우회는 쓰기 전에 거부한다',t=>{
 const f=fixture(t),first=f.vault.saveDocument(f.d.id,body(f.d)),file=path.join(f.root,first.path),bytes=fs.readFileSync(file);
 for(const p of f.d.pages)assert.throws(()=>f.vault.saveCanvas(p.id,p.revision,Buffer.from(JSON.stringify(p)),png,null),{code:'document_api_required'});
 assert.throws(()=>f.vault.saveCanvas(f.d.id,1,Buffer.from(JSON.stringify(f.d)),png,null),{code:'document_api_required'});
 assert.throws(()=>f.vault.save(first.path,first.noteSha256,'selected page'),{code:'document_api_required'});
 fs.linkSync(file,path.join(f.root,'alias.md'));assert.throws(()=>f.vault.save('alias.md',first.noteSha256,'selected page'),{code:'document_api_required'});assert.throws(()=>f.vault.noteConflict('alias.md'),{status:409});assert(fs.readFileSync(file).equals(bytes));
 const unrelated=page();f.vault.saveCanvas(unrelated.id,1,Buffer.from(JSON.stringify(unrelated)),png,null);assert.equal(f.vault.canvas(unrelated.id).revision,1);
 assert.equal(f.vault.save('ordinary.md',null,'---\nx: y\n---\n설명 ccr_document_id: 는 일반 원문이다').text.includes('설명'),true);
});

test('발행 뒤 정본 디렉터리 교체는 false success 대신 vaultroot의 지속 barrier로 남는다',t=>{
 const f=fixture(t),first=f.vault.saveDocument(f.d.id,body(f.d)),file=path.join(f.root,first.path);f.d.revision++;
 const exec=child.execFileSync;let fired=false;
 child.execFileSync=function(program,args,...rest){const result=exec.call(this,program,args,...rest);if(!fired&&args?.[0]?.endsWith('vault-note-exchange.py')&&args[2]===file){fired=true;const canonical=path.join(f.root,'CCR Documents');fs.renameSync(canonical,path.join(f.root,'preserved-directory'));fs.mkdirSync(canonical);fs.writeFileSync(file,'외부 정본');}return result;};
 try{assert.throws(()=>f.vault.saveDocument(f.d.id,body(f.d,base(first))),{code:'note_reconciliation_required'});}finally{child.execFileSync=exec;}
 assert(fired);assert.throws(()=>new ObsidianVault(f.root).document(f.d.id),{code:'note_reconciliation_required'});
 const state=new ObsidianVault(f.root).documentConflict(f.d.id);assert.equal(state.materials.active.validDocument,false);assert.equal(state.materials.proposal.validDocument,false);assert.throws(()=>f.vault.resolveDocumentConflict(f.d.id,{recoveryID:state.recoveryID,expected:state.expected,decision:'keepCurrent'}),{status:409});
 assert(fs.existsSync(path.join(f.root,'preserved-directory','Assets',f.d.id,first.generation,'document.json')));assert.equal(fs.readFileSync(file,'utf8'),'외부 정본');
});

test('missing/symlink/FIFO/변경된 자산은 전체 읽기를 거부하고 세대 원본을 덮지 않는다',t=>{
 const f=fixture(t),first=f.vault.saveDocument(f.d.id,body(f.d)),asset=path.join(f.root,'CCR Documents/Assets',f.d.id,first.generation,'pages',f.d.pages[1].id,'preview.png'),raw=fs.readFileSync(asset);
 fs.renameSync(asset,asset+'.original');assert.throws(()=>f.vault.document(f.d.id));fs.symlinkSync(asset+'.original',asset);assert.throws(()=>f.vault.document(f.d.id));fs.unlinkSync(asset);fs.writeFileSync(asset,Buffer.from('not png'));assert.throws(()=>f.vault.document(f.d.id));assert(fs.readFileSync(asset+'.original').equals(raw));
});
module.exports={page,document,body,png,base};
