#!/usr/bin/env python3
"""초점의 실제 Store/원본/격리 환경설정/Files 경계만 검사한다."""
import argparse,hashlib,json,os,plistlib,subprocess,uuid
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--sdk-check',action='store_true');p.add_argument('--sdk-only',action='store_true');p.add_argument('--aba-only',action='store_true');a=p.parse_args()
if a.sdk_only:a.sdk_check=True
root=Path(__file__).resolve().parents[3];canvas=root/'iOSClient/CanvasBridge'
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
out=a.output.resolve()/('focus-'+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['home','tmp','modules']:(out/n).mkdir()
names=['CanvasModel','CanvasDocument','CanvasDocumentFiles','CanvasDocumentRelay','VaultPDFExcerpt','VaultPDFViewState','CanvasCardTags','CanvasStore','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','CanvasCardMerge','CanvasRelay','ControlRoomProjection']
sources=[canvas/(n+'.swift') for n in names]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',Path(__file__).with_name('main.swift')]
proto=root/'Sources/StreamProtocol/TestDestinations.swift';reader=out/'PDFNativeReader.swift';reader.write_text((canvas/'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
iosSources=sorted(canvas.glob('*.swift'))+[root/'iOSClient'/(n+'.swift') for n in ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
inputs=list(dict.fromkeys(sources+[proto,canvas/'VaultPDFReader.swift',canvas/'CanvasWorkspace.swift',canvas/'PencilCanvas.swift',Path(__file__)]+(iosSources if a.sdk_check else [])))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(root)):sha(p) for p in inputs}
commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True,cwd=root).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True,cwd=root).strip()
info=plistlib.loads((root/'Tests/checks/ink-glyph-edit/Info.plist').read_bytes());info.update(CCRSourceCommit=commit,CCRSourceTree=tree);(out/'Info.plist').write_bytes(plistlib.dumps(info))
identity=str(uuid.uuid4());support=out/'home/Library/Application Support';state=support/'CCRIntegrationTests'/identity/'state';state.mkdir(parents=True)
(state.parent/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='own-focus-fixture-01234567890123456789')))
protected={}
for n in ['CanvasScene.json','CanvasPreferences.json','CanvasWorkspace/bookmark.json','CanvasConflictRecovery/CanvasConflictChoice.json','CanvasNoteEdit/recovery.json']:
 f=support/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(('normal sentinel '+n).encode());protected[str(f)]=sha(f)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
b=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-whole-module-optimization','-module-cache-path',out/'modules']
commands=[('protocol',b+['-emit-module','-emit-object','-module-name','StreamProtocol',proto,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',b+['-I',out,*sources,reader,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',out/'Info.plist','-o',out/'check']),('native-focus',[out/'check',out,'--ccr-test-runtime',identity])]
if a.aba_only:commands[-1][1].append('--aba-only')
if a.sdk_only:commands=[('project-plist',['plutil','-lint',root/'iOSClient/Sill.xcodeproj/project.pbxproj'])]
if a.sdk_check:
 ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip();(out/'ios').mkdir()
 ib=['xcrun','swiftc','-D','DEBUG','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5','-module-cache-path',out/'ios-modules']
 commands += [('ios-protocol',ib+['-emit-module','-module-name','StreamProtocol',proto,'-emit-module-path',out/'ios/StreamProtocol.swiftmodule']),('ios27-store-ui',ib+['-parse-as-library','-I',out/'ios','-typecheck',*iosSources])]
results=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(name+'.log')).write_text(r.stdout+r.stderr);print(name,r.returncode,(r.stdout+r.stderr)[-7000:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
after={str(p.relative_to(root)):sha(p) for p in inputs};normal=all(sha(Path(p))==h for p,h in protected.items());passed=len(results)==len(commands) and all(x['exitCode']==0 for x in results) and before==after and normal
(out/'result.json').write_text(json.dumps(dict(commit=commit,tree=tree,dirty=subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),inputs=before,after=after,sourceUnchanged=before==after,normalSentinels=protected,normalUnchanged=normal,results=results,passed=passed,SDKRequested=a.sdk_check,SDKOnly=a.sdk_only,ABAOnly=a.aba_only,actualStore=not a.sdk_only,GUI=False,HTTP=False,device=False,Host=False,installation=False,wholeOriginalAppAccepted=False,independentReview='pending'),ensure_ascii=False,indent=2)+'\n');print('FOCUS_RECEIPT',out/'result.json');raise SystemExit(0 if passed else 1)
