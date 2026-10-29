'use strict';
const fs=require('node:fs'),path=require('node:path'),readline=require('node:readline');
const root=fs.realpathSync(process.env.PDF_VIEW_VAULT);
if (!root.startsWith('/Volumes/BT-Workspace/Development-Archives/BT_CCR-')) throw Error('own fixture root required');
process.env.CCR_FIX_MODULE_ROOT=path.resolve('CanvasRelay/relay');
process.env.CCR_CHILD_RECEIPTS=path.join(process.env.TMPDIR,'children.jsonl');
// Atomic helper guard requires all own fixture bytes underneath this task TMPDIR.
process.env.TMPDIR=path.dirname(root);
require('../../../CanvasRelay/test-guard.cjs');
const {ObsidianVault}=require('../../../CanvasRelay/relay/obsidian-vault.js');
const vault=new ObsidianVault(root),reply=x=>process.stdout.write(JSON.stringify(x)+'\n');
function file(relative){const p=path.resolve(root,relative);if(!p.startsWith(root+path.sep))throw Error('outside');return p;}
const lines=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
lines.on('line',line=>{try{const r=JSON.parse(line);let value;
 switch(r.operation){
 case 'writePDF':fs.mkdirSync(path.dirname(file(r.path)),{recursive:true});fs.writeFileSync(file(r.path),Buffer.from(r.base64,'base64'),{flag:'wx'});value=vault.pdf(r.path);break;
 case 'readPDF':value=vault.pdf(r.path);break;
 case 'readNote':value=vault.note(r.path);break;
 case 'saveNote':value=vault.save(r.path,r.baseSha256,r.text);break;
 case 'external':fs.writeFileSync(file(r.path),r.text);value={changed:true};break;
 case 'conflictingSave':value=vault.save(r.path,r.baseSha256,r.text,()=>{fs.writeFileSync(file(r.path),r.external);throw Error('own post-exchange external writer');});break;
 case 'compare':value=vault.noteConflict(r.path);break;
 case 'resolve':value=vault.resolveNoteConflict(r.path,r.request);break;
 default:throw Error('unsupported');
 }reply({ok:true,value});}catch(e){reply({ok:false,status:e.status||500,code:e.code,reconciliationRequired:e.reconciliationRequired,recoveryID:e.recoveryID,message:e.message});}});
