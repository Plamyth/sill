'use strict';
const crypto=require('node:crypto'),wire=require('../canvas-document');
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC','base64');
const uuid=()=>crypto.randomUUID(),sha=wire.sha;
function page(){const a=uuid(),b=uuid();return {schemaVersion:3,id:uuid(),revision:1,width:2048,height:1536,drawingBase64:'',strokes:[],nodes:[{id:a,kind:'ellipse',frame:{x:30,y:40,width:180,height:100},text:'원본 e\u0301 👩🏽‍💻',confidence:'confirmed',sourceStrokeIds:[],rotationDegrees:25},{id:b,kind:'line',frame:{x:250,y:120,width:120,height:40},text:'선',confidence:'proposal',sourceStrokeIds:[]}],links:[{id:uuid(),from:a,to:b,label:'관계',kind:'general',fromAnchor:{side:'right',offset:0.5}}],annotations:[{id:uuid(),nodeId:a,text:'일반 주석\r\n#원문',author:'사용자'}]};}
function document(){const pages=[page(),page()];return {format:'ccr.canvas-document',version:1,id:uuid(),revision:1,activePageID:pages[0].id,pages};}
function body(d,base=null,images=d.pages.map(()=>png)) {const bytes=Buffer.from(JSON.stringify(d));return {base,documentJSONBase64:bytes.toString('base64'),documentSha256:sha(bytes),pages:d.pages.map((p,i)=>({id:p.id,drawingSha256:sha(Buffer.from(p.drawingBase64,'base64')),previewSha256:sha(images[i]),previewPNGBase64:images[i].toString('base64')}))};}
const base=s=>Object.fromEntries(['noteSha256','documentSha256','manifestSha256'].map(k=>[k,s[k]]));

module.exports={page,document,body,png,base};
