'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {ObsidianVault}=require('../../../CanvasRelay/relay/obsidian-vault.js');
const root=fs.realpathSync(process.argv[2]);assert(root.startsWith('/Volumes/BT-Workspace/Development-Archives/BT_CCR-'));
const vault=new ObsidianVault(root),file=path.join(root,'book.epub'),bytes=fs.readFileSync(file),sha=x=>crypto.createHash('sha256').update(x).digest('hex');
let checks=0;function ok(x){assert(x);checks++;}function reject(fn,status){assert.throws(fn,e=>status===undefined||e.status===status);checks++;}
const value=vault.epub('book.epub');ok(value.path==='book.epub'&&value.sha256===sha(bytes)&&Buffer.from(value.dataBase64,'base64').equals(bytes));
ok(vault.entries('').some(x=>x.path==='book.epub'&&x.kind==='epub'));
reject(()=>vault.epub('../book.epub'));reject(()=>vault.epub('missing.epub'),404);reject(()=>vault.epub('book.md'));reject(()=>vault.save('book.epub',null,'never write'));
fs.symlinkSync(file,path.join(root,'alias.epub'));reject(()=>vault.epub('alias.epub'));
fs.writeFileSync(path.join(root,'bad.epub'),'not a ZIP');reject(()=>vault.epub('bad.epub'));
const fd=fs.openSync(path.join(root,'large.epub'),'wx');fs.ftruncateSync(fd,32*1024*1024+1);fs.closeSync(fd);reject(()=>vault.epub('large.epub'),413);
ok(fs.readFileSync(file).equals(bytes));console.log(JSON.stringify({passed:true,checks,actualObsidianRawRead:true,originalSHA:sha(bytes),originalUnchanged:true,HTTP:false,listener:false}));
