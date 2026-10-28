'use strict';
const fs=require('node:fs');
const net=require('node:net');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const {SCHEMA,diffSnapshot,fieldChanges,applyRows,encode,reduceEvent}=require('./control-events');
const aborted=()=>Object.assign(Error('관제 연결 시작 취소'),{code:'ABORT_ERR'});
class ControlEventsServer{
  constructor({socketPath,clock=()=>new Date().toISOString(),maxHistory=128,maxHistoryBytes=16*1024*1024}={}){
    Object.assign(this,{socketPath,clock,maxHistory,maxHistoryBytes});
    this.generation=randomUUID();this.revision=0;this.snapshot=null;this.history=[];this.historyBytes=0;
    this.clients=new Set();this.sockets=new Set();this.closed=false;
    this.fieldClients=new WeakSet();
  }
  start(){
    if(this.closed)return Promise.reject(aborted());
    return this.starting??=this.bind();
  }
  async bind(){
    const directory=path.dirname(this.socketPath),uid=process.getuid();
    fs.mkdirSync(directory,{recursive:true,mode:0o700});
    const dir=fs.lstatSync(directory);
    if(!dir.isDirectory()||dir.isSymbolicLink()||dir.uid!==uid||(dir.mode&0o077)||fs.realpathSync(directory)!==directory)
      throw Error('관제 연결 디렉터리 권한 오류');
    if(fs.existsSync(this.socketPath)){
      const before=fs.lstatSync(this.socketPath);
      if(!before.isSocket()||before.uid!==uid||(before.mode&0o077))throw Error('관제 연결 소유자 오류');
      const active=await new Promise((resolve,reject)=>{
        const probe=net.connect(this.socketPath);
        let settled=false,ioOpportunity;
        const finish=(error,value)=>{
          if(settled)return;settled=true;clearTimeout(timer);clearImmediate(ioOpportunity);
          this.cancelStart=null;probe.destroy();if(error)reject(error);else resolve(value);
        };
        const timer=setTimeout(()=>{
          // 동기 작업이 타이머를 지연시켜도 준비된 connect 결과에 poll 기회를 준다.
          ioOpportunity=setImmediate(()=>finish(Object.assign(Error('관제 연결 점유 확인 실패'),{code:'ETIMEDOUT'})));
        },1000);
        this.cancelStart=()=>finish(aborted());
        probe.once('connect',()=>finish(null,true));
        probe.once('error',error=>{if(['ECONNREFUSED','ENOENT'].includes(error.code))finish(null,false);else finish(error);});
      });
      if(this.closed)throw aborted();
      if(active)throw Object.assign(Error('관제 연결이 이미 실행 중입니다.'),{code:'EADDRINUSE'});
      const after=fs.lstatSync(this.socketPath);
      if(after.ino!==before.ino||after.dev!==before.dev)throw Object.assign(Error('관제 연결이 변경됐습니다.'),{code:'ESTALE'});
      fs.unlinkSync(this.socketPath);
    }
    if(this.closed)throw aborted();
    this.server=net.createServer(socket=>this.accept(socket));
    this.server.on('error',()=>{for(const socket of this.sockets)socket.destroy();});
    await new Promise((resolve,reject)=>{
      const fail=error=>{this.cancelStart=null;this.server.removeListener('error',fail);reject(error);};
      this.cancelStart=()=>fail(aborted());this.server.once('error',fail);
      this.server.listen(this.socketPath,()=>{this.cancelStart=null;this.server.removeListener('error',fail);resolve();});
    });
    if(this.closed)throw aborted();
    fs.chmodSync(this.socketPath,0o600);this.identity=fs.lstatSync(this.socketPath);
    return this;
  }
  accept(socket){
    if(this.closed){socket.destroy();return;}
    this.sockets.add(socket);
    let input='',subscribed=false;
    let expiryCheck;
    const timer=setTimeout(()=>{expiryCheck=setImmediate(()=>{if(!subscribed)socket.destroy();});expiryCheck.unref?.();},5000);timer.unref();
    const receive=chunk=>{
      input+=chunk.toString('utf8');
      if(Buffer.byteLength(input)>4096)return socket.destroy();
      const end=input.indexOf('\n');if(end<0)return;
      try{
        const request=JSON.parse(input.slice(0,end));
        if(request.schema!==SCHEMA||request.type!=='subscribe'||input.slice(end+1).trim())throw Error();
        if(request.capabilities!==undefined&&(!Array.isArray(request.capabilities)||request.capabilities.length>16||
          request.capabilities.some(value=>typeof value!=='string'||value.length>64)))throw Error();
        if(request.capabilities?.includes('incremental-fields-v1'))this.fieldClients.add(socket);
        clearTimeout(timer);clearImmediate(expiryCheck);socket.removeListener('data',receive);
        socket.on('data',()=>socket.destroy());subscribed=true;
        const cursor=request.cursor;
        this.clients.add(socket);
        const first=cursor&&cursor.generation===this.generation&&Number.isSafeInteger(cursor.revision)&&
          cursor.revision>=0&&cursor.revision<=this.revision?cursor.revision:null;
        const history=this.history.filter(row=>first!==null&&row.revision>first);
        if(first!==null&&history[0]?.baseRevision===first){
          for(const row of history)this.send(socket,this.fieldClients.has(socket)?row.fieldEncoded||row.encoded:row.encoded);
        }else if(this.snapshot)this.send(socket,this.full());
      }catch{socket.destroy();}
    };
    socket.on('data',receive);socket.on('error',()=>socket.destroy());
    socket.on('close',()=>{clearTimeout(timer);clearImmediate(expiryCheck);this.sockets.delete(socket);if(subscribed)this.clients.delete(socket);});
  }
  full(){return encode({schema:SCHEMA,type:'snapshot',generation:this.generation,revision:this.revision,
    emittedAt:this.clock(),snapshot:this.snapshot});}
  send(socket,encoded){if(socket.destroyed)return;
    if(socket.writableLength+Buffer.byteLength(encoded)>64*1024*1024){socket.destroy();return;}
    socket.write(encoded);
  }
  publish(snapshot){
    if(this.closed)return;
    const next=JSON.parse(JSON.stringify(snapshot));
    if(this.snapshot===null){this.snapshot=next;const frame=this.full();for(const client of this.clients)this.send(client,frame);return;}
    const diff=diffSnapshot(this.snapshot,next);
    if(!Object.keys(diff.set).length&&!diff.unset.length&&
      !diff.threads.upsert.length&&!diff.threads.remove.length&&!diff.catalog.upsert.length&&!diff.catalog.remove.length)return;
    this.publishPatch(diff);
  }
  publishPatch(diff){
    if(this.closed||!this.snapshot)return;
    if(this.revision===Number.MAX_SAFE_INTEGER){
      const applied=reduceEvent({generation:this.generation,revision:this.revision-1,snapshot:this.snapshot},
        {schema:SCHEMA,type:'patch',generation:this.generation,baseRevision:this.revision-1,revision:this.revision,emittedAt:this.clock(),...diff});
      this.generation=randomUUID();this.revision=0;this.history=[];this.historyBytes=0;this.snapshot=applied.state.snapshot;
      const frame=this.full();for(const client of this.clients)this.send(client,frame);return;
    }
    const event={schema:SCHEMA,type:'patch',generation:this.generation,baseRevision:this.revision,
      revision:this.revision+1,emittedAt:this.clock(),...diff};
    const encoded=encode(event);
    const wire=JSON.parse(encoded);
    const next={...this.snapshot,...wire.set};
    for(const key of wire.unset)delete next[key];
    for(const name of ['threads','catalog'])next[name]=applyRows(next[name],wire[name]);
    const changes=fieldChanges(this.snapshot,next);
    let fieldEvent=changes===null?event:{...event,set:{},unset:[],threads:{upsert:[],remove:[]},catalog:{upsert:[],remove:[]},changes};
    let fieldEncoded=encoded;
    if(changes!==null)try{fieldEncoded=encode(fieldEvent);}catch(error){
      if(error.message!=='관제 이벤트 크기 초과')throw error;
      fieldEvent=event;
    }
    const result=reduceEvent({generation:this.generation,revision:this.revision,snapshot:this.snapshot},fieldEvent);
    this.revision=event.revision;this.snapshot=result.state.snapshot;
    const bytes=Buffer.byteLength(encoded)+(fieldEncoded===encoded?0:Buffer.byteLength(fieldEncoded));
    this.history.push({...event,encoded,fieldEncoded,bytes});this.historyBytes+=bytes;
    while(this.history.length>this.maxHistory||this.historyBytes>this.maxHistoryBytes){this.historyBytes-=this.history.shift().bytes;}
    for(const client of this.clients)this.send(client,this.fieldClients.has(client)?fieldEncoded:encoded);
  }

  close(){
    if(this.closing)return this.closing;
    this.closed=true;this.cancelStart?.();
    for(const socket of this.sockets)socket.destroy();this.sockets.clear();this.clients.clear();
    this.closing=(async()=>{
      if(this.server)await new Promise(resolve=>this.server.close(resolve));
      try{const now=fs.lstatSync(this.socketPath);if(this.identity&&now.ino===this.identity.ino&&now.dev===this.identity.dev)fs.unlinkSync(this.socketPath);}catch{}
    })();
    return this.closing;
  }
}
function startControlEventsServer({socketPath,onReady=()=>{},retryMs=250,maxRetryMs=10000,
  serverFactory=()=>new ControlEventsServer({socketPath}),setTimer=setTimeout,clearTimer=clearTimeout}){
  const retryable=new Set(['EADDRINUSE','ENOENT','ESTALE','ETIMEDOUT','EAGAIN','ECONNREFUSED']);
  let closed=false,timer=null,active=null,candidate=null,closing=null,delay=retryMs,finishFirst;
  const control={server:null,phase:'starting',error:null,firstAttempt:new Promise(resolve=>{finishFirst=resolve;}),close};
  async function attempt(){
    if(closed||active||control.server)return;
    candidate=serverFactory();control.phase='starting';
    active=(async()=>{
      try{await candidate.start();}
      catch(error){
        await candidate.close();if(closed)return;
        control.error={phase:'startup',code:error.code||'STARTUP_FAILED'};
        control.phase=retryable.has(error.code)?'waiting':'failed';
        if(control.phase==='waiting'){
          timer=setTimer(()=>{timer=null;void attempt();},delay);timer?.unref?.();
          delay=Math.min(maxRetryMs,delay*2);
        }
        return;
      }
      if(closed){await candidate.close();return;}
      control.server=candidate;control.phase='listening';control.error=null;
      try{await onReady(candidate);}catch(error){control.error={phase:'publish',code:error.code||'PUBLISH_FAILED'};}
    })().finally(()=>{active=null;finishFirst();});
    await active;
  }
  function close(){
    if(closing)return closing;
    closed=true;control.phase='closed';if(timer!==null)clearTimer(timer);timer=null;
    closing=(async()=>{await candidate?.close();await active;control.server=null;})();return closing;
  }
  void attempt();return control;
}
module.exports={ControlEventsServer,startControlEventsServer};
