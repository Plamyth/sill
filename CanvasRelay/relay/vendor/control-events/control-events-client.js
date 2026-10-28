'use strict';
const net=require('node:net');
const fs=require('node:fs');
const path=require('node:path');
const {setImmediate,clearImmediate}=require('node:timers');
const {SCHEMA,createDecoder,reduceEvent}=require('./control-events');
class ControlEventsClient{
  constructor({socketPath,onSnapshot=()=>{},onConnection=()=>{},retryMs=250,maxRetryMs=10000,initialTimeoutMs=5000,initialMaxMs=20000}={}){
    Object.assign(this,{socketPath,onSnapshot,onConnection,retryMs,maxRetryMs,initialTimeoutMs,initialMaxMs});
    this.state=null;this.closed=false;this.delay=retryMs;this.socket=null;this.timer=null;this.ready=false;this.started=false;
  }
  start(){if(this.started&&!this.closed)return this;this.started=true;this.closed=false;this.connect();return this;}
  connect(){
    if(this.closed)return;
    let before;
    try{
      const dir=fs.lstatSync(path.dirname(this.socketPath));before=fs.lstatSync(this.socketPath);
      if(!dir.isDirectory()||!before.isSocket()||dir.uid!==process.getuid()||before.uid!==dir.uid||
        ((dir.mode|before.mode)&0o077)||fs.realpathSync(this.socketPath)!==this.socketPath)throw Error();
    }catch{this.reconnect();return;}
    const socket=this.socket=net.connect(this.socketPath);
    let initialized=false,timeout,idleCheck,absoluteCheck;
    const expire=()=>{if(!initialized&&!this.closed&&this.socket===socket&&!socket.destroyed)socket.destroy();};
    const resetIdle=()=>{
      clearTimeout(timeout);clearImmediate(idleCheck);
      timeout=setTimeout(()=>{idleCheck=setImmediate(expire);idleCheck.unref?.();},this.initialTimeoutMs);timeout.unref?.();
    };
    const absolute=setTimeout(()=>{absoluteCheck=setImmediate(expire);absoluteCheck.unref?.();},this.initialMaxMs);absolute.unref?.();
    const clearInitial=()=>{clearTimeout(timeout);clearTimeout(absolute);clearImmediate(idleCheck);clearImmediate(absoluteCheck);};
    resetIdle();
    let replay=this.state;
    const decode=createDecoder(event=>{
      if(this.closed||this.socket!==socket||socket.destroyed)return;
      const result=reduceEvent(replay,event);
      if(result.status==='resync'){this.state=null;socket.destroy();return;}
      replay=result.state;this.state=replay;
      if(result.status==='applied'){
        initialized=true;clearInitial();
        this.ready=true;this.delay=this.retryMs;this.onConnection({connected:true,state:'connected'});
        if(this.closed||this.socket!==socket||socket.destroyed)return;
        this.onSnapshot(replay.snapshot,{generation:replay.generation,revision:replay.revision});
      }
    });
    socket.once('connect',()=>{
      if(this.closed||this.socket!==socket||socket.destroyed)return;
      try{const after=fs.lstatSync(this.socketPath);if(after.ino!==before.ino||after.dev!==before.dev)throw Error();
        socket.write(JSON.stringify({schema:SCHEMA,type:'subscribe',capabilities:['incremental-fields-v1'],cursor:this.state?{generation:this.state.generation,revision:this.state.revision}:null})+'\n');
      }catch{socket.destroy();}
    });
    socket.on('data',chunk=>{if(this.closed||this.socket!==socket||socket.destroyed)return;try{decode(chunk);if(!initialized&&!socket.destroyed&&this.socket===socket&&chunk.length)resetIdle();}catch{this.state=null;socket.destroy();}});
    socket.on('error',()=>socket.destroy());
    socket.once('close',()=>{clearInitial();if(this.socket!==socket)return;this.socket=null;this.reconnect();});
  }
  reconnect(){
    this.ready=false;this.onConnection({connected:false,state:this.state?'stale':'unavailable'});
    if(this.closed||this.timer)return;
    this.timer=setTimeout(()=>{this.timer=null;this.connect();},this.delay);this.timer.unref?.();
    this.delay=Math.min(this.maxRetryMs,this.delay*2);
  }
  close(){this.closed=true;this.started=false;clearTimeout(this.timer);this.timer=null;this.ready=false;this.socket?.destroy();this.socket=null;}
}
module.exports={ControlEventsClient};
