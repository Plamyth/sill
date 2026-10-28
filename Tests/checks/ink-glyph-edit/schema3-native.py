#!/usr/bin/env python3
from pathlib import Path
import subprocess, os, json, uuid, concurrent.futures, argparse, hashlib
root=Path(__file__).resolve().parents[3]; here=Path(__file__).resolve().parent
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
parser=argparse.ArgumentParser();parser.add_argument('--combined-verification',type=Path,required=True);args=parser.parse_args()
latest=json.loads(args.combined_verification.read_text()); output=Path(latest['output'])
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(p.exists() and os.path.samefile(p,route['path']) for p in output.parents)
home=output/'native-home';home.mkdir(exist_ok=True);tmp=output/'native-tmp';tmp.mkdir(exist_ok=True)
env.update(HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(tmp)+'/')
inputs=[root/'iOSClient/CanvasBridge'/n for n in ['CanvasModel.swift','CanvasRelay.swift','CanvasPeleView.swift','Pele/bridge.js','Pele/diagram.html','Pele/pele.global.js']]+[here/'WebKitShapeCheck.swift',here/'RelayScene3Check.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs};before=hashes()
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-parse-as-library','-swift-version','5','-module-cache-path',str(output/'schema3-modules')]
def run(name,cmd):
 r=subprocess.run(list(map(str,cmd)),env=env,cwd=root,capture_output=True,text=True,timeout=180)
 (output/(name+'.log')).write_text(r.stdout+r.stderr); print(name,r.returncode,(r.stdout+r.stderr)[-3500:],flush=True)
 return dict(name=name,exitCode=r.returncode,command=list(map(str,cmd)))
def web():
 c=run('webkit-compile',base+[here/'WebKitShapeCheck.swift','-o',output/'webkit-check'])
 return [c]+([run('webkit',[output/'webkit-check',root/'iOSClient/CanvasBridge/Pele',output])] if c['exitCode']==0 else [])
def relay():
 c=run('mac-protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',root/'Sources/StreamProtocol/TestDestinations.swift','-emit-module-path',output/'StreamProtocol.swiftmodule','-o',output/'StreamProtocol.o'])
 if c['exitCode']:return [c]
 d=run('relay-compile',base+['-I',output,root/'iOSClient/CanvasBridge/CanvasModel.swift',root/'iOSClient/CanvasBridge/CanvasRelay.swift',root/'iOSClient/CanvasBridge/ControlRoomProjection.swift',root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',here/'RelayScene3Check.swift',output/'StreamProtocol.o','-o',output/'relay-check'])
 return [c,d]+([run('relay',[output/'relay-check'])] if d['exitCode']==0 else [])
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 results=[r for group in pool.map(lambda f:f(),[web,relay]) for r in group]
record=dict(sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sourceTree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),output=str(output),fixtureHashes={n:hashlib.sha256((output/n).read_bytes()).hexdigest() for n in ['projection-scene.json','projection-snapshot.json']},sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),results=results,passed=before==hashes() and all(r['exitCode']==0 for r in results),network=False,deviceHostEffects=0)
(output/'schema3-native-verification.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
raise SystemExit(0 if record['passed'] else 1)
