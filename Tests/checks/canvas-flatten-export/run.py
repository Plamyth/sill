#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = Path(json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
if not output.is_relative_to(archive): raise SystemExit('승인된 외장 증거 경로가 필요합니다.')
output.mkdir(parents=True,exist_ok=True)
source = root/'iOSClient/CanvasBridge/SceneFile.swift'
body = source.read_text().split('struct RenderedSceneFile:',1)[1]
extracted = output/'RenderedSceneFile.swift'
extracted.write_text('import SwiftUI\nimport UniformTypeIdentifiers\nimport ImageIO\nstruct RenderedSceneFile:'+body)
inputs = [source,root/'iOSClient/CanvasBridge/CanvasWorkspace.swift',Path(__file__),Path(__file__).with_name('main.swift')]
hashes = {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
command = ['xcrun','swiftc','-sdk',sdk,'-target','arm64-apple-macos27.0','-swift-version','5','-parse-as-library',
    '-module-cache-path',str(output/'modules'),str(extracted),str(Path(__file__).with_name('main.swift')),'-o',str(output/'check')]
records = []
for label,argv in [('compile',command),('runtime',[str(output/'check'),str(output)])]:
    result = subprocess.run(argv,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
    (output/(label+'.log')).write_text(result.stdout)
    records.append({'stage':label,'exitCode':result.returncode})
    print(result.stdout,end='')
    if result.returncode: break
unchanged = all(hashlib.sha256((root/p).read_bytes()).hexdigest() == value for p,value in hashes.items())
passed = len(records)==2 and all(r['exitCode']==0 for r in records) and unchanged
(output/'result.json').write_text(json.dumps({'passed':passed,'sourceHashes':hashes,'sourceUnchanged':unchanged,
    'processes':records,'helper':'exact product RenderedSceneFile declaration; unrelated SceneFile excluded',
    'sceneRendererRuntime':False,'UI':False,'device':False,'install':False,'Pencil':False},indent=2)+'\n')
raise SystemExit(0 if passed else 1)
