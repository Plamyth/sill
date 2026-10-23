'use strict';
const fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const {Writable}=require('node:stream'),{spawn}=require('node:child_process'),{randomUUID}=require('node:crypto');
const [nodeRoot,folder,index]=process.argv.slice(2);
const {audioForwardingAuthority}=require(path.join(nodeRoot,'audio-forwarding-authority.js'));
const {nativeAudioControl}=require(path.join(nodeRoot,'native-audio-control.js'));
const journal=path.join(folder,'journal.json'),log=path.join(folder,`child-${index}.jsonl`);
const event=value=>fs.appendFileSync(log,JSON.stringify(value)+'\n');
const store={load:()=>fs.existsSync(journal)?JSON.parse(fs.readFileSync(journal)):undefined,
  save:value=>{fs.writeFileSync(journal,JSON.stringify(value));return true;},close(){}};
const keyFile=path.join(folder,'fixture-key');
if(!fs.existsSync(keyFile))fs.writeFileSync(keyFile,Buffer.alloc(32,42));
const authority=audioForwardingAuthority({store,credentialKey:fs.readFileSync(keyFile)});
const credentials=new Map(),requests=new Map();
let input='',holdMethod=null,held=null,worker=null;
process.stdin.on('data',chunk=>{
  input+=chunk;
  while(input.includes('\n')) {
    const at=input.indexOf('\n'),request=JSON.parse(input.slice(0,at));input=input.slice(at+1);
    requests.set(request.requestId,request);
    event({method:request.method,operation:request.payload.operation??null,
      device:request.payload.pairedDeviceId??null,connection:request.payload.connectionId??null});
  }
});
const output=new Writable({write(chunk,_,done){
  const response=JSON.parse(String(chunk)),request=requests.get(response.requestId);
  event({reply:request.method,status:response.result?.state??'accepted',code:response.result?.code??null});
  if(request.method==='forwardingBootstrap')credentials.set(request.payload.pairedDeviceId,response.result.credential.credential);
  const waiting=holdMethod===request.method&&
    (request.method!=='forwardingEvidence'||request.payload.operation==='attach');
  if(waiting){holdMethod=null;held=()=>{process.stdout.write(chunk,done);};event({held:request.method});}
  else process.stdout.write(chunk,done);
}});
const facts={admissionFenced:true,startsSettled:true,mediaDetached:true,callbacksDrained:true,buffersEmpty:true,workersExited:true};
let receipt=null;
const prove=request=>{const {budgetMilliseconds,...identity}=request;return {...identity,state:'quiescent',facts};};
const audio={bootId:randomUUID(),close(){},closeBinding(){},commitPreparedBinding(){},
  prepareBinding:async value=>{receipt=prove(value.request);return receipt;},inspect:()=>receipt,
  prepareLocalReturn:async request=>{receipt=prove(request);return receipt;},
  fenceAndQuiesce:async request=>{receipt=prove(request);return receipt;},
  loseController(){worker?.stdin.end();worker?.kill();}};
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1');
  if(url.pathname==='/arm'){holdMethod=url.searchParams.get('method');res.end('ok');return;}
  if(url.pathname==='/release'){const release=held;held=null;release?.();res.end('ok');return;}
  if(url.pathname==='/state'){res.setHeader('content-type','application/json');res.end(JSON.stringify(authority.snapshot()));return;}
  const id=url.searchParams.get('id');
  try{authority.authenticate(id,credentials.get(id));res.end('authorized');}
  catch{res.writeHead(403);res.end('refused');}
});
nativeAudioControl({input:process.stdin,output,audio,forwarding:authority,
  inspectRuntime:async()=>({runtimeVersion:1,serverListening:server.listening,address:'127.0.0.1',port:0,
    python:'inert-python',router:'inert-router',pythonArguments:['-I','-B']}),
  onReady:()=>server.listen(0,'127.0.0.1',()=>{
    worker=spawn(process.execPath,['-e','process.stdin.resume()'],{stdio:['pipe','pipe','pipe']});
    worker.on('close',()=>event({workerExited:true}));
    fs.writeFileSync(path.join(folder,`child-${index}.json`),JSON.stringify({pid:process.pid,boot:audio.bootId,port:server.address().port}));
  }),
  onLoss:()=>{event({controllerLost:true});server.close();server.closeAllConnections();process.exitCode=1;}});
