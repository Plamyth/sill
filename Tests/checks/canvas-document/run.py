#!/usr/bin/env python3
"""CanvasDocument 실제 PKDrawing/Files 검사. 출력은 승인 외장 경로에만 쓴다."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, uuid
root = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--sdk-check', action='store_true')
a = p.parse_args()
archive = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
a.output.mkdir(parents=True,exist_ok=True)
out = a.output.resolve() / ('native-' + str(uuid.uuid4())); out.mkdir()
for name in ['home','tmp']: (out/name).mkdir()
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
canvas = root/'iOSClient/CanvasBridge'
sources = [canvas/(n+'.swift') for n in ['CanvasModel','CanvasDocument','CanvasDocumentFiles']]
project = root/'iOSClient/Sill.xcodeproj/project.pbxproj'
info = root/'Tests/checks/ink-glyph-edit/Info.plist'
inputs = sources+[Path(__file__).with_name('main.swift'),Path(__file__),project,info]
def hashes(): return {str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
before=hashes()
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
commands=[('compile',['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules',*sources,inputs[3],'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'check']),('native-files',[out/'check',out]),('project-plist',['plutil','-lint',project])]
if a.sdk_check:
    ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    commands.append(('ios27-unit-typecheck',['xcrun','swiftc','-D','DEBUG','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'ios-modules','-typecheck',*sources]))
results=[]
for name,cmd in commands:
    r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    print(name,r.returncode,(r.stdout+r.stderr)[-6500:],flush=True)
    results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
    if r.returncode: break
after=hashes()
record=dict(commit=commit,tree=tree,sourceHashes=before,sourceHashesAfter=after,sourceUnchanged=before==after,results=results,output=str(out),passed=len(results)==len(commands) and all(x['exitCode']==0 for x in results) and before==after,actualPKDrawing=True,actualNativeFiles=True,injectedFailureHooks=True,StoreIntegrated=False,pairedRelay=False,UIWriteEnabled=False,installation=False,wholeProductAccepted=False)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print('RECEIPT',out/'result.json',flush=True)
raise SystemExit(0 if record['passed'] else 1)
