'use strict';
const {createHash}=require('node:crypto');
const {NativeRealtimeProducer,PROTOCOL_VERSION,METHODS}=require(process.argv[2]);
const requireTrue=value=>{if(!value)throw new Error('interop_failed');};
let input='';
process.stdin.setEncoding('utf8');
process.stdin.on('data',chunk=>{input+=chunk;requireTrue(input.length<=200000);});
process.stdin.on('end',async()=>{
  try{
    const chunks=JSON.parse(input);
    input='';
    requireTrue(Array.isArray(chunks)&&chunks.length>=3);
    const target={schema:'ccr-codex-realtime-target-v1',providerKind:'codex-app-server',
      providerInstanceId:'synthetic-provider',threadId:'synthetic-thread',voiceSessionId:'synthetic-voice'};
    target.targetHash=createHash('sha256').update(JSON.stringify(Object.values(target))).digest('hex');
    let producer,sequence=0,appends=0,received=0,expected;
    const notify=(method,params)=>producer.receive({binding:producer.binding,sequence:++sequence,
      method,params:{threadId:target.threadId,...params}});
    producer=new NativeRealtimeProducer({target,providerInstanceId:target.providerInstanceId,
      connectionId:'synthetic-connection',protocolVersion:PROTOCOL_VERSION,isCurrent:()=>true,
      rpc:(method,params)=>{
        if(method.endsWith('/start'))notify(METHODS.started,{realtimeSessionId:params.realtimeSessionId,version:params.version});
        if(method.endsWith('/appendAudio')){
          appends++;
          requireTrue(params.audio.samplesPerChannel===Buffer.from(params.audio.data,'base64').length/2);
        }
        if(method.endsWith('/stop'))notify(METHODS.closed,{reason:'requested'});
        return {};
      },
      callbacks:{audio:event=>{
        requireTrue(event.pcm.equals(expected)&&event.samplesPerChannel===expected.length/2);
        received++;
      }},
    });
    await producer.start({binding:producer.binding});
    for(const [index,audio] of chunks.entries()){
      await producer.appendAudio({binding:producer.binding,sequence:index+1,audio});
      expected=Buffer.from(audio.data,'base64');
      notify(METHODS.audio,{audio:{...audio,samplesPerChannel:null}});
      expected.fill(0);
    }
    requireTrue(appends===chunks.length&&received===chunks.length);
    await producer.stop({binding:producer.binding});
    process.stdout.write('PASS Core producer accepts Swift DTO and output callback matches PCM\n');
  }catch{
    process.stderr.write('Core memory-only interoperability check failed\n');
    process.exitCode=1;
  }
});
