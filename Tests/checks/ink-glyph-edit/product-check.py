#!/usr/bin/env python3
"""실제 결합 source의 shape·Files 회귀 및 Obsidian 파일를 격리 실행한다."""
from pathlib import Path
import subprocess, os, json, hashlib, concurrent.futures, uuid, argparse
root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--verification',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(p.exists() and os.path.samefile(p,route['path']) for p in [args.output,*args.output.parents])
args.output.mkdir(parents=True,exist_ok=True)
args.output=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())
current=json.loads(args.verification.read_text())
output=args.output/('combined-'+str(uuid.uuid4()))
output.mkdir(parents=True,exist_ok=True)
tmp=output/'tmp';tmp.mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(tmp)+'/')
mac=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-sdk',mac,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',str(output/'modules')]
files=[root/'iOSClient/CanvasBridge'/n for n in ['CanvasModel.swift','CanvasStore.swift','CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','CanvasInkMathProposal.swift']]
suites={
 'shape':root/'Tests/checks/ink-shape-proposal/main.swift',
 'files-regression':root/'Tests/checks/canvas-file-workspace/main.swift',
 'files-safety':root/'Tests/checks/canvas-file-workspace/safety.swift'}
tracked=list(dict.fromkeys(files+list(suites.values())+[here/'Info.plist',here/'obsidian-roundtrip.cjs',Path(__file__).resolve()]))
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
before=hashes()
def suite(name,source):
 home=output/(name+'-home');home.mkdir(exist_ok=True)
 runenv=dict(env,HOME=str(home),CFFIXED_USER_HOME=str(home),INK_SHAPE_OUTPUT=str(output))
 command=base+list(map(str,files))+[str(source),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(here/'Info.plist'),'-o',str(output/name)]
 r=subprocess.run(command,env=runenv,capture_output=True,text=True,timeout=240)
 (output/(name+'-compile.log')).write_text(r.stdout+r.stderr)
 if r.returncode:return {'name':name,'compile':r.returncode,'log':r.stdout+r.stderr}
 args=[str(output/name)] + ([] if name=='shape' else [str(output/(name+'-fixtures'))])
 r=subprocess.run(args,env=runenv,capture_output=True,text=True,timeout=120)
 (output/(name+'.log')).write_text(r.stdout+r.stderr)
 print(name,r.returncode,(r.stdout+r.stderr)[-2500:],flush=True)
 return {'name':name,'compile':0,'exitCode':r.returncode,'command':command}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 results=list(pool.map(lambda item:suite(*item),suites.items()))
obsidian=[]
if all(r.get('exitCode')==0 for r in results):
 for flow,folder in [('glyph',Path(current['output'])),('shape',output)]:
  r=subprocess.run(['node',str(here/'obsidian-roundtrip.cjs'),str(folder),flow],env=env,capture_output=True,text=True,timeout=60)
  (output/('obsidian-'+flow+'.log')).write_text(r.stdout+r.stderr)
  obsidian.append({'flow':flow,'exitCode':r.returncode,'receipt':str(folder/('obsidian-'+flow+'-roundtrip.json'))})
  print('Obsidian',flow,r.returncode,r.stdout+r.stderr,flush=True)
record={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceTree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),'sourceClean':not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),'sourceHashes':before,'sourceHashesAfter':hashes(),'sourceUnchanged':before==hashes(),'results':results,
 'obsidian':obsidian,'passed':before==hashes() and all(r.get('exitCode')==0 for r in results) and len(obsidian)==2 and all(r['exitCode']==0 for r in obsidian),'output':str(output),'nativeRecognitionRepeated':False,'deviceHost':False}
(output/'combined-verification.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
for r in results:
 if r.get('log'):print(r['log'][-5000:])
print('COMBINED_OUTPUT',output,flush=True)
raise SystemExit(0 if record['passed'] else 1)
