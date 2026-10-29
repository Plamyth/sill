'use strict';
const crypto=require('node:crypto');
const {assertInkScene}=require('./canvas-scene');
const DOC_BYTES=16*1024*1024,SCENE_BYTES=4*1024*1024,PREVIEW_BYTES=32*1024*1024,PAGE_LIMIT=128;
const UUID=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i,HASH=/^[0-9a-f]{64}$/;
const id=v=>typeof v==='string'&&UUID.test(v),hash=v=>typeof v==='string'&&HASH.test(v),key=v=>v.toLowerCase();
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const record=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
function fields(v,allowed,required=allowed){if(!record(v)||Object.keys(v).some(k=>!allowed.includes(k))||required.some(k=>!Object.hasOwn(v,k)))throw Error('지원하지 않거나 빠진 문서 필드입니다.');}
const strings=(v,keys)=>{if(keys.some(k=>typeof v[k]!=='string'))throw Error('문서 문자열이 올바르지 않습니다.');};
const finite=(v,keys)=>{if(keys.some(k=>!Number.isFinite(v[k])))throw Error('문서 좌표가 유한 범위를 벗어났습니다.');};
const integer=v=>Number.isSafeInteger(v)&&v>=0;
function base64(value,limit){
 if(typeof value!=='string'||value.length>4*Math.ceil(limit/3))throw Error('문서 자산의 base64 또는 크기가 올바르지 않습니다.');
 const b=Buffer.from(value,'base64');if(b.length>limit||b.toString('base64')!==value)throw Error('문서 자산의 원본 인코딩이 다릅니다.');return b;
}
function point(v){fields(v,['x','y','pressure']);finite(v,['x','y','pressure']);}
function anchor(v){if(v==null)return;fields(v,['side','offset']);if(!['top','right','bottom','left'].includes(v.side)||!Number.isFinite(v.offset)||v.offset<0||v.offset>1)throw Error('문서 연결점이 올바르지 않습니다.');}
function unique(values){if(!Array.isArray(values)||values.some(v=>!id(v.id))||new Set(values.map(v=>key(v.id))).size!==values.length)throw Error('문서 요소 ID가 중복되거나 올바르지 않습니다.');}
function scene(page){
 const keys=['schemaVersion','id','revision','width','height','drawingBase64','strokes','nodes','links','annotations','penSettings'];fields(page,keys,keys.filter(k=>k!=='penSettings'));
 if(!id(page.id)||!integer(page.revision)||![1,2,3].includes(page.schemaVersion)||![page.width,page.height].every(v=>Number.isFinite(v)&&v>0&&v<=16384))throw Error('지원하지 않는 문서 페이지입니다.');
 if(!Array.isArray(page.nodes)||page.nodes.length>=1000||!Array.isArray(page.strokes)||page.strokes.length>=10000)throw Error('문서 페이지 한도를 초과했습니다.');
 base64(page.drawingBase64,SCENE_BYTES);unique(page.nodes);unique(page.links);unique(page.annotations);
 for(const node of page.nodes){
  fields(node,['id','kind','frame','text','confidence','sourceStrokeIds','vaultNote','isCollapsed','rotationDegrees'],['id','kind','frame','text','confidence','sourceStrokeIds']);strings(node,['text','kind','confidence']);
  if(!['confirmed','proposal'].includes(node.confidence)||!Array.isArray(node.sourceStrokeIds)||node.sourceStrokeIds.some(v=>!id(v)))throw Error('문서 노드의 원본 참조가 올바르지 않습니다.');
  fields(node.frame,['x','y','width','height']);finite(node.frame,['x','y','width','height']);
  if(!Number.isFinite(node.frame.x+node.frame.width)||!Number.isFinite(node.frame.y+node.frame.height))throw Error('문서 노드 좌표가 올바르지 않습니다.');
  if(node.rotationDegrees!=null&&(!Number.isFinite(node.rotationDegrees)||!Number.isFinite(node.rotationDegrees*Math.PI/180)))throw Error('문서 회전값이 올바르지 않습니다.');
  if(node.rotationDegrees!=null&&node.rotationDegrees!==0){const f=node.frame,cx=f.x+f.width/2,cy=f.y+f.height/2,angle=(node.rotationDegrees%360)*Math.PI/180;if(f.width<=0||f.height<=0||![cx,cy].every(Number.isFinite)||[[f.x,f.y],[f.x+f.width,f.y],[f.x,f.y+f.height],[f.x+f.width,f.y+f.height]].some(([x,y])=>![cx+(x-cx)*Math.cos(angle)-(y-cy)*Math.sin(angle),cy+(x-cx)*Math.sin(angle)+(y-cy)*Math.cos(angle)].every(Number.isFinite)))throw Error('문서 회전 좌표를 재열 수 없습니다.');}
  if(node.isCollapsed!=null&&typeof node.isCollapsed!=='boolean')throw Error('문서 접힘 값이 올바르지 않습니다.');
  if(node.vaultNote!=null){const n=node.vaultNote;fields(n,['path','sha256','relayAddress','cacheTruncated','blockID','sourceState','observedSha256','quoteSha256'],['path','sha256','relayAddress']);strings(n,['path','sha256','relayAddress']);if(n.cacheTruncated!=null&&typeof n.cacheTruncated!=='boolean')throw Error('문서 출처 값이 올바르지 않습니다.');for(const k of ['blockID','sourceState','observedSha256','quoteSha256'])if(n[k]!=null&&typeof n[k]!=='string')throw Error('문서 출처 값이 올바르지 않습니다.');if(n.sourceState!=null&&!['current','changed','missing','ambiguous','unsupported','unavailable'].includes(n.sourceState))throw Error('지원하지 않는 출처 상태입니다.');}
 }
 const nodes=new Set(page.nodes.map(v=>key(v.id)));
 for(const link of page.links){fields(link,['id','from','to','label','kind','fromAnchor','toAnchor'],['id','from','to','label']);strings(link,['label']);if(!id(link.from)||!id(link.to)||!nodes.has(key(link.from))||!nodes.has(key(link.to))||link.kind!=null&&!['general','parentChild'].includes(link.kind))throw Error('문서 연결 참조가 올바르지 않습니다.');anchor(link.fromAnchor);anchor(link.toAnchor);}
 for(const a of page.annotations){fields(a,['id','nodeId','text','author'],['id','text','author']);strings(a,['text','author']);if(a.nodeId!=null&&(!id(a.nodeId)||!nodes.has(key(a.nodeId))))throw Error('문서 주석 참조가 올바르지 않습니다.');}
 for(const stroke of page.strokes){
  fields(stroke,['id','points','createdAt','visibility','style'],['id','points','createdAt']);if(!id(stroke.id)||!Number.isFinite(stroke.createdAt)||!Array.isArray(stroke.points))throw Error('문서 획이 올바르지 않습니다.');stroke.points.forEach(point);
  if(stroke.visibility!=null){const v=stroke.visibility;fields(v,['kind','visibleSegments']);if(!['full','masked'].includes(v.kind)||!Array.isArray(v.visibleSegments))throw Error('문서 획 표시가 올바르지 않습니다.');for(const segment of v.visibleSegments){fields(segment,['lowerBound','upperBound','worldPoints']);finite(segment,['lowerBound','upperBound']);if(!Array.isArray(segment.worldPoints))throw Error('문서 획 구간이 올바르지 않습니다.');segment.worldPoints.forEach(point);}}
  if(stroke.style!=null){const v=stroke.style;fields(v,['version','inkType','color','transform','samples'],['version','inkType','transform','samples']);fields(v.transform,['a','b','c','d','tx','ty']);finite(v.transform,['a','b','c','d','tx','ty']);if(v.color!=null){fields(v.color,['red','green','blue','alpha']);finite(v.color,['red','green','blue','alpha']);}if(!Array.isArray(v.samples))throw Error('문서 펜 샘플이 올바르지 않습니다.');for(const sample of v.samples){fields(sample,['width','height','opacity']);finite(sample,['width','height','opacity']);}}
 }
 if(page.penSettings!=null)fields(page.penSettings,['version','color','width']);
 assertInkScene(page);
 if(Buffer.byteLength(JSON.stringify(page))>SCENE_BYTES)throw Error('문서 페이지 JSON 한도를 초과했습니다.');
}
function decodeDocument(bytes){
 if(!Buffer.isBuffer(bytes)||bytes.length>DOC_BYTES)throw Error('문서 JSON 한도를 초과했습니다.');
 const d=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));fields(d,['format','version','id','revision','activePageID','pages']);
 if(d.format!=='ccr.canvas-document'||d.version!==1||!id(d.id)||!integer(d.revision)||!id(d.activePageID)||!Array.isArray(d.pages)||!d.pages.length||d.pages.length>PAGE_LIMIT)throw Error('지원하지 않는 문서 형식입니다.');
 unique(d.pages);if(!d.pages.some(p=>key(p.id)===key(d.activePageID)))throw Error('문서의 현재 페이지가 없습니다.');d.pages.forEach(scene);return d;
}
const baseKeys=['noteSha256','documentSha256','manifestSha256'];
function base(value){if(value===null)return;fields(value,baseKeys);if(baseKeys.some(k=>!hash(value[k])))throw Error('문서 전체 CAS 값이 올바르지 않습니다.');}
function request(body){
 fields(body,['base','documentJSONBase64','documentSha256','pages']);base(body.base);if(!hash(body.documentSha256))throw Error('문서 SHA가 올바르지 않습니다.');
 const bytes=base64(body.documentJSONBase64,DOC_BYTES),document=decodeDocument(bytes);if(sha(bytes)!==body.documentSha256)throw Error('문서 원본 SHA가 다릅니다.');
 if(!Array.isArray(body.pages)||body.pages.length!==document.pages.length)throw Error('모든 페이지 자산이 필요합니다.');let total=0;
 const pages=body.pages.map((asset,index)=>{fields(asset,['id','drawingSha256','previewSha256','previewPNGBase64']);if(!id(asset.id)||key(asset.id)!==key(document.pages[index].id)||!hash(asset.drawingSha256)||!hash(asset.previewSha256))throw Error('문서 자산 순서가 다릅니다.');const drawing=base64(document.pages[index].drawingBase64,SCENE_BYTES),preview=base64(asset.previewPNGBase64,PREVIEW_BYTES);total+=preview.length;if(sha(drawing)!==asset.drawingSha256||sha(preview)!==asset.previewSha256||total>PREVIEW_BYTES)throw Error('문서 자산 SHA 또는 합계 한도를 초과했습니다.');return {id:key(asset.id),drawing,preview};});
 return {bytes,document,pages};
}
const meta={base:Object.fromEntries(baseKeys.map(k=>[k,'0'.repeat(64)])),documentJSONBase64:'',documentSha256:'0'.repeat(64),pages:Array.from({length:PAGE_LIMIT},()=>({id:'00000000-0000-4000-8000-000000000000',drawingSha256:'0'.repeat(64),previewSha256:'0'.repeat(64),previewPNGBase64:''}))};
const WIRE_METADATA_BYTES=Buffer.byteLength(JSON.stringify(meta));
const MAX_DOCUMENT_REQUEST_BYTES=4*Math.ceil(DOC_BYTES/3)+4*Math.floor((PREVIEW_BYTES+2*PAGE_LIMIT)/3)+WIRE_METADATA_BYTES;
const DOCUMENT_CAPABILITY=Object.freeze({schema:'ccr.vault-document/v1',format:'ccr.canvas-document',versions:[1],wholeDocument:true,explicitConflictResolution:true,maxDocumentJSONBytes:DOC_BYTES,maxPageCount:PAGE_LIMIT,maxPreviewTotalBytes:PREVIEW_BYTES,maxRequestBytes:MAX_DOCUMENT_REQUEST_BYTES});
module.exports={DOC_BYTES,SCENE_BYTES,PREVIEW_BYTES,PAGE_LIMIT,MAX_DOCUMENT_REQUEST_BYTES,WIRE_METADATA_BYTES,DOCUMENT_CAPABILITY,decodeDocument,request,base64,fields,sha,id,hash,key};
