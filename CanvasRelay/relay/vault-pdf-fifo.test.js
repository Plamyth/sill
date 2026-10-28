'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto'),child=require('node:child_process');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
if(process.argv[2]==='--fifo-child'){
 const root=process.argv[3],file=path.join(root,'original.pdf'),open=fs.openSync,close=fs.closeSync,read=fs.readSync;
 let switched=false,opened=null,closed=false,reads=0;
 fs.openSync=function(target,flags,...rest){
  if(target===file&&!switched){
   switched=true;fs.renameSync(file,path.join(root,'preserved.pdf'));
   child.execFileSync('/usr/bin/mkfifo',[file]);
   fs.writeFileSync(path.join(root,'hook.json'),JSON.stringify({flags,nonblock:Boolean(flags&fs.constants.O_NONBLOCK),fifo:fs.lstatSync(file).isFIFO()}));
   opened=open.call(fs,target,flags,...rest);return opened;
  }
  return open.call(fs,target,flags,...rest);
 };
 fs.closeSync=function(fd){if(fd===opened)closed=true;return close(fd);};
 fs.readSync=function(fd,...args){if(fd===opened)reads++;return read(fd,...args);};
 const {ObsidianVault}=require('./obsidian-vault');
 try{new ObsidianVault(root).pdf('original.pdf');throw Error('FIFO accepted');}
 catch(error){if(error.status!==409)throw error;console.log(JSON.stringify({status:error.status,closed,reads}));}
}else{
 const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'ccr-pdf-fifo-'))),bytes=Buffer.from('%PDF-1.4\noriginal immutable fixture\n%%EOF\n');
 let result,receipt;
 try{
  fs.writeFileSync(path.join(root,'original.pdf'),bytes);
  result=child.spawnSync(process.execPath,[__filename,'--fifo-child',root],{timeout:1200,killSignal:'SIGKILL',encoding:'utf8'});
  assert(fs.existsSync(path.join(root,'hook.json')),JSON.stringify({status:result.status,error:result.error?.code,stderr:result.stderr,stdout:result.stdout}));
  const hook=JSON.parse(fs.readFileSync(path.join(root,'hook.json'))),preserved=fs.readFileSync(path.join(root,'preserved.pdf'));
  let gone=false;try{process.kill(result.pid,0);}catch(error){gone=error.code==='ESRCH';}
  assert(gone);assert(preserved.equals(bytes));assert(fs.lstatSync(path.join(root,'original.pdf')).isFIFO());
  if(process.argv.includes('--expect-blocked')){assert.equal(result.error?.code,'ETIMEDOUT');assert.equal(result.signal,'SIGKILL');assert.equal(hook.nonblock,false);}
  else{assert.equal(result.status,0,result.stderr);assert.equal(hook.nonblock,true);assert.deepEqual(JSON.parse(result.stdout),{status:409,closed:true,reads:0});}
  receipt={expectedBlocked:process.argv.includes('--expect-blocked'),hook,child:{pid:result.pid,status:result.status,signal:result.signal,errorCode:result.error?.code??null,pidGone:gone,response:result.stdout.trim()},originalSHA256:sha(bytes),preservedSHA256:sha(preserved),fifoPreserved:true,listenerCount:0};
 }finally{fs.rmSync(root,{recursive:true,force:true});}
 receipt.fixtureCleanupVerified=!fs.existsSync(root);console.log(JSON.stringify(receipt));
}
