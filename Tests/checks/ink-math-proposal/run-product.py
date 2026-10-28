#!/usr/bin/env python3
"""최종 실제 제품 소스와 격리 Files에서 수식 접합만 검사. 인식 API 재호출 없음."""
from pathlib import Path
import argparse, subprocess, os, json, hashlib, uuid
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);args=p.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(x.exists() and os.path.samefile(x,route['path']) for x in [args.output,*args.output.parents])
args.output.mkdir(parents=True,exist_ok=True);dest=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())/('math-'+str(uuid.uuid4()));dest.mkdir()
home=dest/'home';home.mkdir();tmp=dest/'tmp';tmp.mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(tmp)+'/',INK_MATH_OUTPUT=str(dest))
source=[root/'iOSClient/CanvasBridge'/n for n in ['CanvasModel.swift','CanvasStore.swift','CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','CanvasInkMathProposal.swift']]
inputs=source+[here/'main.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
cmd=['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',str(dest/'modules'),*map(str,source),str(here/'main.swift'),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(root/'Tests/checks/ink-glyph-edit/Info.plist'),'-o',str(dest/'check')]
records=[]
for name,command,timeout in [('compile',cmd,240),('actual-product',[str(dest/'check'),'--integration-only'],120)]:
 r=subprocess.run(command,cwd=root,env=env,capture_output=True,text=True,timeout=timeout)
 log=r.stdout+r.stderr;(dest/(name+'.log')).write_text(log);print(name,r.returncode,log[-8500:],flush=True)
 records.append(dict(name=name,command=command,exitCode=r.returncode))
 if r.returncode:break
record=dict(schema='ccr.math-product-check/v1',commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),output=str(dest),results=records,passed=before==hashes() and len(records)==2 and all(r['exitCode']==0 for r in records),nativeRecognizerExecuted=False,recognitionEvidenceInjected=True,originalArithmeticAndNativeEvidence='/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/rea-completion-20261028/math-checks/result.json',deviceHostChanges=0,sharedRelayChanged=False)
(dest/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('MATH_PRODUCT_OUTPUT',dest,flush=True)
raise SystemExit(0 if record['passed'] else 1)
