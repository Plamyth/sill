#!/usr/bin/env python3
"""Ohm 소유 Scripts를 고치지 않고 결합 Store의 컴파일 입력만 보충해 native 검사한다."""
from pathlib import Path
import argparse, subprocess, json, os, uuid, hashlib, importlib.util, sys, unittest
sys.dont_write_bytecode=True
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(p.exists() and os.path.samefile(p,route['path']) for p in [args.output,*args.output.parents])
args.output.mkdir(parents=True,exist_ok=True);out=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())/('adapter-'+str(uuid.uuid4()));out.mkdir()
for name in ['home','tmp','native']:(out/name).mkdir()
os.environ.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/',CCR_NATIVE_ADAPTER_TEST_DIR=str(out/'native'),PYTHONDONTWRITEBYTECODE='1')
inputs=[root/'Scripts/ipad-test-runtime'/n for n in ['adapter.py','test_adapter.py','README.md']]+[root/'iOSClient/CanvasBridge'/n for n in ['CanvasModel.swift','CanvasStore.swift','CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','CanvasInkMathProposal.swift']]+[Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs};before=hashes()
real_run=subprocess.run;injections=[];route_normalizations=[];forbidden=[]
def joined_run(command,*a,**kw):
 cmd=list(map(str,command)) if isinstance(command,(tuple,list)) else command
 if isinstance(cmd,list):
  if (cmd[0]=='xcrun' and len(cmd)>1 and cmd[1] in ['devicectl','simctl','xcodebuild']) or cmd[0] in ['xcodebuild','codesign']:
   forbidden.append(cmd[:3]);raise RuntimeError('actual device/signing commands are forbidden in this source check')
  if cmd[:2]==['xcrun','swiftc'] and str(root/'iOSClient/CanvasBridge/CanvasStore.swift') in cmd:
   extra=[str(root/'iOSClient/CanvasBridge'/n) for n in ['CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','CanvasInkMathProposal.swift']]
   cmd+=extra;injections.append(extra)
  result=real_run(cmd,*a,**kw)
  if cmd and cmd[0]=='/Users/ambrion/.local/bin/storage-route' and result.returncode==0 and result.stdout:
   text=result.stdout.decode() if isinstance(result.stdout,bytes) else result.stdout
   payload=json.loads(text)
   if 'path' in payload:
    canonical=subprocess.check_output(['/bin/pwd','-P'],cwd=payload['path'],text=True).strip()
    assert os.path.samefile(canonical,payload['path'])
    payload['path']=canonical;normalized=json.dumps(payload)+'\n'
    result.stdout=normalized.encode() if isinstance(result.stdout,bytes) else normalized
    route_normalizations.append(True)
  return result
 return real_run(command,*a,**kw)
subprocess.run=joined_run
spec=importlib.util.spec_from_file_location('joined_adapter_tests',root/'Scripts/ipad-test-runtime/test_adapter.py');module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
with (out/'tests.log').open('w') as log:
 suite=unittest.defaultTestLoader.loadTestsFromModule(module)
 result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
subprocess.run=real_run
record=dict(schema='ccr.adapter-source-combination/v1',commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),skipped=len(result.skipped),compilerDependencies=injections,pathNormalizationSamefileValidated=len(route_normalizations),forbiddenExternalCalls=forbidden,actualInstallation=False,functionalAcceptance=False,passed=result.wasSuccessful() and not result.skipped and len(injections)==1 and not forbidden and before==hashes(),output=str(out))
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print((out/'tests.log').read_text()[-8000:]);print('ADAPTER_OUTPUT',out,flush=True)
raise SystemExit(0 if record['passed'] else 1)
