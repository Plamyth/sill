#!/usr/bin/env python3
"""공유 실제 HTTP fixture + 실제 Swift Relay/codec/PKDrawing/ImageIO + iOS27 검사."""
import argparse, hashlib, json, os, pathlib, plistlib, subprocess, uuid
root=pathlib.Path(__file__).resolve().parents[3]; here=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--sdk-check',action='store_true');a=p.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(x.exists() and x.samefile(route['path']) for x in [a.output,*a.output.parents])
a.output.mkdir(parents=True,exist_ok=True);out=a.output/('run-'+str(uuid.uuid4()));out.mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
(out/'tmp').mkdir();canvas=root/'iOSClient/CanvasBridge'
sources=[canvas/(n+'.swift') for n in ['CanvasModel','VaultPDFExcerpt','CanvasDocument','CanvasDocumentRelay','CanvasRelay','ControlRoomProjection']]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
proto=root/'Sources/StreamProtocol/TestDestinations.swift';project=root/'iOSClient/Sill.xcodeproj/project.pbxproj'
ios=sorted(canvas.glob('*.swift'))+[root/'iOSClient'/(n+'.swift') for n in ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
inputs=list(dict.fromkeys(sources+[proto,project,here/'main.swift',pathlib.Path(__file__),*sorted((here/'wire').glob('*.json'))]+(ios if a.sdk_check else [])))
hashes=lambda:{str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
before=hashes();commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
info=plistlib.loads((root/'Tests/checks/ink-glyph-edit/Info.plist').read_bytes());info.update(CCRSourceCommit=commit,CCRSourceTree=tree);(out/'Info.plist').write_bytes(plistlib.dumps(info))
identity=str(uuid.uuid4());context=out/'home/Library/Application Support/CCRIntegrationTests'/identity;context.mkdir(parents=True)
(context/'state').mkdir();(context/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='own-document-fixture-token-0123456789')))
fixture=json.loads((here/'wire/manifest.json').read_text())
for f in fixture['responseFixtures']:
 b=(here/'wire'/f['path']).read_bytes();assert hashlib.sha256(b).hexdigest()==f['sha256'];d=json.loads(b);import base64
 assert hashlib.sha256(base64.b64decode(d['responseJSONBase64'],validate=True)).hexdigest()==f['responseSha256']
macsdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip();base=['xcrun','swiftc','-D','DEBUG','-sdk',macsdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
commands=[('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',proto,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',base+['-I',out,*sources,here/'main.swift',out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',out/'Info.plist','-o',out/'check']),('native-urlprotocol',[out/'check',here,'--ccr-test-runtime',identity]),('project-plist',['plutil','-lint',project])]
if a.sdk_check:
 sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip();(out/'ios').mkdir()
 iosbase=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64-apple-ios27.0','-swift-version','5','-module-cache-path',out/'ios-modules']
 commands += [('ios-protocol',iosbase+['-emit-module','-module-name','StreamProtocol',proto,'-emit-module-path',out/'ios/StreamProtocol.swiftmodule']),('ios-product-typecheck',iosbase+['-parse-as-library','-I',out/'ios','-typecheck',*ios])]
results=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=300);log=r.stdout+r.stderr;(out/(name+'.log')).write_text(log);print(name,r.returncode,log[-5500:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
record=dict(commit=commit,tree=tree,sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),results=results,passed=len(results)==len(commands) and all(r['exitCode']==0 for r in results) and before==hashes(),fixtureCommit='9c60a7f99c458115ae1f41c0ec60da9ec3604cdd',wireSourceCommit=fixture['sourceCommit'],actualRecordedHTTPResponses=19,actualURLSession=True,URLProtocol=True,actualNativePKDrawing=True,actualImageIO=True,newLiveHTTP=False,StoreIntegrated=False,UI=False,device=False,Host=False,liveVault=False,installation=False)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('RECEIPT',out/'result.json',flush=True)
raise SystemExit(0 if record['passed'] else 1)
