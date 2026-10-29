#!/usr/bin/env python3
"""Planck의 PDF013 두 반례만 실제 Store/Files로 재검증한다. 기존76/SDK 실행0."""
import argparse,hashlib,json,os,plistlib,subprocess,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--review',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path'])
assert any(x.exists() and x.samefile(archive) for x in [a.output,*a.output.parents])
review=a.review.resolve();original=json.loads((review/'result.json').read_text());loss=json.loads((review/'loss-values.json').read_text())
assert original['commit']=='013ec4d61212c1c82c7a6cd344291d1fa60e80d9'
protected={str(review/name):value for name,value in {**original['artifactHashes'],**original['observationHashes']}.items()}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
protected[str(review/'result.json')]=sha(review/'result.json')
assert all(sha(Path(p))==h for p,h in protected.items())
out=a.output.resolve()/('repair-'+str(uuid.uuid4()));out.mkdir(parents=True)
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
assert not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),'수리 exact source를 먼저 commit한다'
originalExecution=json.loads((review/'execution.json').read_text());command=list(originalExecution['results'][0]['command'])
reader=out/'PDFNativeReader.swift';reader.write_text((root/'iOSClient/CanvasBridge/VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0]);assert reader.read_bytes()==(review/'PDFNativeReader.swift').read_bytes()
for i,value in enumerate(command):
 if value==str(review/'PDFNativeReader.swift'):command[i]=str(reader)
 elif value==str(review/'main.swift'):pass
 elif '/source/' in value and value.endswith('.swift'):command[i]=str(root/value.split('/source/',1)[1])
command[command.index('-module-cache-path')+1]=str(out/'modules');command[command.index('-o')+1]=str(out/'check')
infoIndex=command.index('__info_plist')+2;info=plistlib.loads(Path(command[infoIndex]).read_bytes());info.update(CCRSourceCommit=commit,CCRSourceTree=tree)
(out/'Info.plist').write_bytes(plistlib.dumps(info));command[infoIndex]=str(out/'Info.plist')
inputs={value:sha(Path(value)) for value in command if value.endswith(('.swift','.o','.plist'))}
(out/'tmp').mkdir();env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(out/'tmp')+'/')
results=[];comparisons={}
r=subprocess.run(command,cwd=root,env=env,text=True,capture_output=True,timeout=240);(out/'compile.log').write_text(r.stdout+r.stderr);print('compile',r.returncode,(r.stdout+r.stderr)[-3500:],flush=True);results.append(dict(name='compile',command=command,exitCode=r.returncode))
if r.returncode==0:
 for mode in ['busy','cleanup']:
  folder=out/mode;folder.mkdir();identity=str(uuid.uuid4());home=folder/'home';state=home/'Library/Application Support/CCRIntegrationTests'/identity/'state';state.mkdir(parents=True)
  (state.parent/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='independent-pdf-glue-fixture-01234567890123456789')))
  args=[str(out/'check'),str(folder),mode,'--ccr-test-runtime',identity]
  r=subprocess.run(args,cwd=root,env=dict(env,CFFIXED_USER_HOME=str(home)),text=True,capture_output=True,timeout=60);(out/(mode+'.log')).write_text(r.stdout+r.stderr);print(mode,r.returncode,(r.stdout+r.stderr)[-3500:],flush=True);results.append(dict(name=mode,command=args,exitCode=r.returncode))
  if r.returncode:break
  rows=json.loads((folder/(mode+'-observations.json')).read_text())
  if mode=='busy':
   old=json.loads((review/'busy/busy-observations.json').read_text())[0];new=rows[0]
   ok=old['busyAfterLateResponse'] and not new['closeReturned'] and new['busyImmediatelyAfterClose'] and not new['busyAfterLateResponse'] and new['reopenAccepted'] and new['puts']==new['gets']==1 and rows[1]['busyAfterConnectionChange']==False
   comparisons[mode]=dict(counterexampleAfter=not ok,before=old,after=rows)
  else:
   new=rows[0];reopen=json.loads((folder/'reopen-result.json').read_text());attempt=json.loads((folder/'cleanup-attempted.json').read_text());import base64
   attemptedRecord=json.loads(base64.b64decode(attempt['payload']))
   durable=json.loads((state/'CanvasPDFExcerptCreate/recovery.json').read_text());durableRecord=json.loads(base64.b64decode(durable['payload']))
   view=durableRecord['viewRecovery'];attemptView=attemptedRecord['viewRecovery']
   newSHA=hashlib.sha256(view['draft']['markdown'].encode()).hexdigest()
   ok=loss['newProcess']['restoredWidth']==0.8 and new['cleanupFaultTriggered'] and new['readerWidth']==new['durableDraftWidth']==reopen['restoredWidth']==0.6 and new['puts']==new['gets']==1 and reopen['opened'] and not reopen['submittedPresent'] and view['id']==attemptView['id'] and view['base']['sha256']==loss['attemptedNewer']['baseSHA256'] and newSHA==loss['attemptedNewer']['markdownSHA256'] and view.get('submitted') is None
   comparisons[mode]=dict(counterexampleAfter=not ok,beforeLoss=loss,after=new,reopen=reopen,sameOperationID=view['id']==attemptView['id'],draftSHA256=newSHA,operationID=view['id'])
unchanged=all(sha(Path(p))==h for p,h in inputs.items());priorUnchanged=all(sha(Path(p))==h for p,h in protected.items())
passed=len(results)==3 and all(x['exitCode']==0 for x in results) and len(comparisons)==2 and all(not x['counterexampleAfter'] for x in comparisons.values()) and unchanged and priorUnchanged
report=dict(schema='ccr.pdf-product-repair/v1',commit=commit,tree=tree,sourceClean=True,passed=passed,results=results,comparisons=comparisons,inputs=inputs,inputsUnchanged=unchanged,originalReviewFiles=protected,originalReviewUnchanged=priorUnchanged,Store76Repeated=False,module147Repeated=False,SDKRepeated=False,actualStore=True,actualPDFKit=True,actualRecoveryFileIO=True,closuresInsteadOfHTTP=True,HTTP=False,GUI=False,device=False,Host=False,independentReview='Planck-pending')
(out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print('REPAIR_RECEIPT',out/'result.json',flush=True)
raise SystemExit(0 if passed else 1)
