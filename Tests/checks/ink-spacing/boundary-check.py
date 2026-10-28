#!/usr/bin/env python3
"""86f425 반례 관측 또는 변경 모듈만 검사한다. 전체 SDK/40개 검사는 실행하지 않는다."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
archive = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(archive): raise SystemExit('승인된 외장 경로만 사용합니다.')
baseline = '--baseline' in sys.argv[2:]
output.mkdir(parents=True,exist_ok=True)
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
canvas = root/'iOSClient/CanvasBridge'
proposal = canvas/'CanvasInkSpacingProposal.swift'
if baseline:
    proposal = output/'CanvasInkSpacingProposal.swift'
    proposal.write_bytes(subprocess.check_output(['git','show','86f425bf7c604730d114b673ada6bcae4f989864:iOSClient/CanvasBridge/CanvasInkSpacingProposal.swift'],cwd=root))
sources = [canvas/'CanvasModel.swift',canvas/'CanvasInkTextEditing.swift',proposal]
records = []
def run(command,name):
    result = subprocess.run(list(map(str,command)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    (output/name).write_text(result.stdout)
    print(result.stdout,end='',flush=True)
    records.append({'name':name,'exit':result.returncode})
    if result.returncode: raise SystemExit(result.returncode)
mac = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
cache = archive/'rea-completion-20261028/ink-spacing-checks'
common = ['xcrun','swiftc','-swift-version','5','-parse-as-library']
run(common+['-sdk',mac,'-target','arm64e-apple-macos27.0','-module-cache-path',cache/'mac-modules',*sources,here/'BoundaryCases.swift',
    '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',root/'Tests/checks/ink-undo/Info.plist','-o',output/'check'],'compile.log')
home = tempfile.mkdtemp(prefix='home-',dir=output)
env.update(HOME=home,CFFIXED_USER_HOME=home)
run([output/'check']+(['--baseline'] if baseline else []),'runtime.log')
if not baseline:
    ios = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    run(common+['-sdk',ios,'-target','arm64-apple-ios27.0','-module-cache-path',cache/'ios-modules','-typecheck',*sources],'changed-module-ios-typecheck.log')
result = {'baseline':baseline,'sourceHashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[here/'BoundaryCases.swift',Path(__file__)]},'processes':records,
    'scope':'two counterexamples and integer guard regression; iOS changed module only','injectedEvidence':True,'nativeRecognitionAccepted':False,'deviceUI':False,'hostChanged':False,'network':False}
(output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
