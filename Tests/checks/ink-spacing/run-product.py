#!/usr/bin/env python3
"""실제 제품 소스의 좁은 간격 접합/파일 검사와 iOS27 타입 검사. UI·기기·인식 호출 없음."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
archive = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
output = Path(sys.argv[1]).resolve()
assert output.is_relative_to(archive)
output.mkdir(parents=True,exist_ok=True)
output = Path(subprocess.check_output(['/bin/pwd','-P'],cwd=output,text=True).strip())
home = output/'home';home.mkdir(exist_ok=True)
tmp = output/'tmp';tmp.mkdir(exist_ok=True)
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(tmp)+'/',INK_SPACING_OUTPUT=str(output))
canvas = root/'iOSClient/CanvasBridge'
macSources = [canvas/(name+'.swift') for name in ['CanvasModel','CanvasStore','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal']]
iosSources = sorted(canvas.glob('*.swift'))
iosSources += [root/('iOSClient/'+name+'.swift') for name in ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']]
iosSources += [root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
protocol = root/'Sources/StreamProtocol/TestDestinations.swift'
projects = [root/'iOSClient/Sill.xcodeproj/project.pbxproj']
inputs = iosSources+projects+[protocol,here/'Product.swift',Path(__file__)]
hashes = lambda: {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
cache = archive/'rea-completion-20261028/ink-spacing-checks'
def run(command,name):
    r = subprocess.run(list(map(str,command)),env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=240)
    (output/(name+'.log')).write_text(r.stdout)
    print(name,r.returncode,r.stdout[-9000:],flush=True)
    return {'name':name,'exitCode':r.returncode,'command':list(map(str,command))}
def mac():
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
    base = ['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',cache/'mac-modules']
    results = [run(base+macSources+[here/'Product.swift','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',root/'Tests/checks/ink-glyph-edit/Info.plist','-o',output/'check'],'mac-compile')]
    if results[-1]['exitCode']==0:results.append(run([output/'check'],'product-runtime'))
    return results
def ios():
    sdk = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    base = ['xcrun','swiftc','-sdk',sdk,'-target','arm64-apple-ios27.0','-swift-version','5','-module-cache-path',cache/'ios-modules']
    results = [run(base+['-emit-module','-module-name','StreamProtocol',protocol,'-emit-module-path',output/'StreamProtocol.swiftmodule'],'ios-protocol')]
    if results[-1]['exitCode']==0:results.append(run(base+['-parse-as-library','-I',output,'-typecheck']+iosSources,'ios-product-typecheck'))
    return results
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures = [pool.submit(mac)] + ([] if "--mac-only" in sys.argv[2:] else [pool.submit(ios)])
    results = [r for f in futures for r in f.result()]
results.append(run(['plutil','-lint',*projects],'project-plist'))
unchanged = before==hashes()
record = {'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),
    'sourceHashes':before,'sourceUnchanged':unchanged,'results':results,'passed':unchanged and len(results)==(3 if '--mac-only' in sys.argv[2:] else 5) and all(r['exitCode']==0 for r in results),
    'macOnly':'--mac-only' in sys.argv[2:],'actualProductSources':True,'nativeRecognitionExecuted':False,'mappingEvidenceInjected':True,'filePreviewInjected':True,'deviceUI':False,'hostChanged':False,'network':False,'install':False,'parentIndependentReview':'pending'}
(output/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
sys.exit(0 if record['passed'] else 1)
