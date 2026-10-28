#!/usr/bin/env python3
"""Actual DEBUG launch + CanvasLocalFile, with all homes/context/source-independent outputs on routed SSD."""
from pathlib import Path
import argparse,subprocess,os,json,uuid,hashlib,plistlib
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(x.exists() and os.path.samefile(x,route['path']) for x in [a.output,*a.output.parents])
a.output.mkdir(parents=True,exist_ok=True)
out=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=a.output,text=True).strip())/('recovery-isolation-'+str(uuid.uuid4()));out.mkdir()
for n in ['compiler-home','tmp']:(out/n).mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'compiler-home'),CFFIXED_USER_HOME=str(out/'compiler-home'),TMPDIR=str(out/'tmp')+'/')
sources=[root/'iOSClient/CanvasBridge/CanvasModel.swift',here/'ConflictRecoveryIsolation.swift']
inputs=sources+[root/'iOSClient/CanvasBridge/CanvasWorkspace.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();records=[];sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
info=out/'Info.plist';info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.ambrion.ConflictRecoveryCheck','CFBundleName':'ConflictRecoveryCheck','CCRSourceCommit':'a'*40,'CCRSourceTree':'b'*40}))
def run(name,cmd,runenv):
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=runenv,capture_output=True,text=True,timeout=240)
 log=r.stdout+r.stderr;(out/(name+'.log')).write_text(log);print(name,r.returncode,log[-6500:],flush=True)
 records.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 return r.returncode
base=['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
normal_preserved=True
for debug in [True,False]:
 binary=out/('debug-check' if debug else 'release-check')
 cmd=base+(['-D','DEBUG'] if debug else [])+sources+['-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',binary]
 if run(binary.name+'-compile',cmd,env):break
 for mode in (['normal','valid','invalid','parent-link'] if debug else ['normal']):
  home=out/(binary.name+'-'+mode);support=home/'Library/Application Support';support.mkdir(parents=True)
  identity='12345678-1234-4234-8234-123456789abc';context=support/'CCRIntegrationTests'/identity;state=context/'state';state.mkdir(parents=True)
  context.joinpath('context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=('c' if mode=='invalid' else 'a')*40,tree='b'*40,relayAddress='http://192.168.88.88:4242',token='own-fixture-token-012345678901')))
  relative=['CanvasScene.json','CanvasOutbox/ledger.json','CanvasConflictRecovery/CanvasConflictChoice.json','CanvasConflictRecovery/CanvasConflictLocal-11111111-1111-4111-8111-111111111111.json','CanvasConflictRecovery/CanvasConflictAttempt-22222222-2222-4222-8222-222222222222.json']
  for n in relative:
   f=support/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(('원래 정상 앱 fixture: '+n).encode())
  originals={n:hashlib.sha256((support/n).read_bytes()).hexdigest() for n in relative}
  if mode=='parent-link':(state/'CanvasConflictRecovery').symlink_to(support/'CanvasConflictRecovery',target_is_directory=True)
  args=[binary]+(['--ccr-test-runtime',identity] if debug and mode!='normal' else [])
  runenv=dict(env,HOME=str(home),CFFIXED_USER_HOME=str(home),RECOVERY_TEST_MODE=mode)
  if run(binary.name+'-'+mode,args,runenv):break
  unchanged=all(hashlib.sha256((support/n).read_bytes()).hexdigest()==digest for n,digest in originals.items());normal_preserved &= unchanged
  records[-1]['protectedNormalFixtureUnchanged']=unchanged
 if any(r['exitCode'] for r in records):break
result=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),output=str(out),results=records,normalFixturesUnchanged=normal_preserved,actualLaunch='CanvasRuntime.launch reads actual process --ccr-test-runtime and embedded Info.plist; no LaunchState injection',passed=len(records)==7 and all(r['exitCode']==0 for r in records) and normal_preserved and before==hashes(),network=False,installation=False,deviceHostUI=0)
(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print('RECOVERY_ISOLATION_OUTPUT',out,flush=True)
raise SystemExit(0 if result['passed'] else 1)
