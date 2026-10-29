'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const w=require('./canvas-document'),{document,body,png}=require('./test-input/document-fixture.cjs');
test('문서 전용 wire의 최대 메타데이터와128개 base64 padding을 실제 인코딩해 산정한다',()=>{
 const d=document();const h='0'.repeat(64),meta={base:{noteSha256:h,documentSha256:h,manifestSha256:h},documentJSONBase64:'',documentSha256:h,pages:Array.from({length:128},()=>({id:d.pages[0].id,drawingSha256:h,previewSha256:h,previewPNGBase64:''}))};
 assert.equal(Buffer.byteLength(JSON.stringify(meta)),w.WIRE_METADATA_BYTES);
 const padding=Array(128).fill(1);padding[0]=w.PREVIEW_BYTES-127;
 assert.equal(padding.reduce((n,v)=>n+4*Math.ceil(v/3),0),4*Math.floor((w.PREVIEW_BYTES+256)/3));
 assert.equal(w.MAX_DOCUMENT_REQUEST_BYTES,67139536);assert(w.MAX_DOCUMENT_REQUEST_BYTES<65*1024*1024);
 assert.throws(()=>w.request({...body(d),documentJSONBase64:' '.repeat(4*Math.ceil(w.DOC_BYTES/3)+1)}));
 assert.throws(()=>w.request({...body(d),pages:body(d).pages.reverse()}));
 const a=body(d);a.pages.pop();assert.throws(()=>w.request(a));
 const b=body(d);b.pages[1].drawingSha256=h;assert.throws(()=>w.request(b));
 const c=body(d);c.documentSha256=h;assert.throws(()=>w.request(c));
});
