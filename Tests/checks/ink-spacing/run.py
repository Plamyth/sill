#!/usr/bin/env python3
"""기기·UI·네트워크 없이 표준 PencilKit 시험획과 격리 파일만 검사한다."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import signal
import shutil
import tempfile
root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
archive = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(archive): raise SystemExit('승인된 외장 경로만 사용합니다.')
output.mkdir(parents=True,exist_ok=True)
inputdir = output/'input'
subprocess.run([sys.executable,str(here/'integration.py'),str(inputdir)],check=True)
files = sorted((root/'iOSClient/CanvasBridge').glob('*.swift'))
files += [root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',root/'iOSClient/IPadAudioSession.swift',root/'iOSClient/IPadAudioLeaseState.swift',root/'iOSClient/IPadAudioLeaseCoordinator.swift']
inputs = files + [root/'Sources/StreamProtocol/TestDestinations.swift',here/'main.swift',here/'integration.py',here/'integration.patch',Path(__file__)]
hashes = {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
for p in files:
    target=inputdir/p.relative_to(root)
    if not target.exists():
        target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(p,target)
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
records=[]
def run(command,name,timeout=180):
    child=subprocess.Popen(list(map(str,command)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    try: log,_=child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid,signal.SIGKILL); log,_=child.communicate()
    (output/name).write_text(log)
    print(log,end='',flush=True)
    records.append({'name':name,'command':list(map(str,command)),'exit':child.returncode})
    return child.returncode
mac=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
protocol=root/'Sources/StreamProtocol/TestDestinations.swift'
codes=[]
for label,sdk,target in [('mac',mac,'arm64e-apple-macos27.0'),('ios',ios,'arm64-apple-ios27.0')]:
    if label=='ios' and '--mac-only' in sys.argv[2:]: continue
    dest=output/label;dest.mkdir(exist_ok=True)
    common=['xcrun','swiftc','-sdk',sdk,'-target',target,'-swift-version','5','-parse-as-library','-module-cache-path',output/(label+'-modules')]
    code=run(common+['-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol',protocol,'-emit-module-path',dest/'StreamProtocol.swiftmodule','-o',dest/'StreamProtocol.o'],label+'-module.log')
    if code: codes.append(code);continue
    canvas=inputdir/'iOSClient/CanvasBridge'
    if label=='mac':
        source=[canvas/x for x in ['CanvasModel.swift','CanvasStore.swift','CanvasInkSpacingProposal.swift','CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','PencilTextCorrection.swift','CanvasDocument.swift','CanvasDocumentRelay.swift','CanvasRelay.swift','ControlRoomProjection.swift']]+[inputdir/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',here/'main.swift']
        code=run(common+['-I',dest,dest/'StreamProtocol.o',*source,'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',root/'Tests/checks/ink-undo/Info.plist','-o',dest/'check'],'mac-compile.log')
        if code==0:
            home=Path(tempfile.mkdtemp(prefix='home-',dir=output))
            env.update(HOME=str(home),CFFIXED_USER_HOME=str(home))
            code=run([dest/'check'],'runtime.log',60)
    else:
        source=[inputdir/p.relative_to(root) for p in files]
        code=run(common+['-I',dest,'-typecheck',*source],'ios-typecheck.log',240)
    codes.append(code)
unchanged=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==value for p,value in hashes.items())
result={'sourceHashes':hashes,'sourceUnchanged':unchanged,'processes':records,'exitCode':0 if all(c==0 for c in codes) and unchanged else 1,'deviceUI':False,'install':False,'hostChanged':False,'network':False,'personalDataChanged':False,'physicalPencil':False,'parentGoal':'../GOAL_PROMPT.md','independentReview':'pending parent reviewer','macOnly':'--mac-only' in sys.argv[2:],'nativeEvidenceSuccessIsSeparate':True}
(output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
sys.exit(result['exitCode'])
