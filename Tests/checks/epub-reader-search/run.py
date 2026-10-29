#!/usr/bin/env python3
"""기존 EPUB native 검사 방식으로 검색 경계와 최종 전체 Canvas iOS27만 검증한다."""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,uuid,zipfile
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
out=a.output.resolve()/('run-'+str(uuid.uuid4()));out.mkdir(parents=True)
for name in ['home','tmp','ios']:(out/name).mkdir()
def archiveBytes(file,changed=False):
 with zipfile.ZipFile(file,'w',compression=zipfile.ZIP_STORED) as z:
  for name,value in {
   'mimetype':'application/epub+zip',
   'META-INF/container.xml':'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
   'book.opf':'<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>',
   'one.xhtml':'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>자체 첫 장</title></head><body><p id="a">앞말 😀 가나다 Alpha e\u0301 '+('수정' if changed else '원문')+'</p><p id="b">다음 가나다 문단</p><p>'+'needle '*205+'</p><p>'+'exact '*200+'</p></body></html>',
   'two.xhtml':'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>자체 둘째 장</title></head><body><p id="c">둘째 😀 가나다 Beta é 끝</p></body></html>'
  }.items():
   info=zipfile.ZipInfo(name,date_time=(2026,10,29,0,0,0));z.writestr(info,value.encode())
archiveBytes(out/'own.epub');archiveBytes(out/'changed.epub',True)
canvas=root/'iOSClient/CanvasBridge';sources=[canvas/(n+'.swift') for n in ['CanvasModel','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']]
proto=root/'Sources/StreamProtocol/TestDestinations.swift';main=here/'main.swift'
iosSources=sorted(canvas.glob('*.swift'))+[root/'iOSClient'/(n+'.swift') for n in ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
inputs=list(dict.fromkeys([*sources,proto,main,Path(__file__),*iosSources,root/'iOSClient/Sill.xcodeproj/project.pbxproj']))
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest();before={str(f.relative_to(root)):sha(f) for f in inputs};fixtures={str(f):sha(f) for f in [out/'own.epub',out/'changed.epub']}
sentinels={}
for name in ['CanvasScene.json','CanvasDocumentSource.json','CanvasWorkspace/bookmark.json','CanvasPDFExcerptCreate/recovery.json','CanvasConflictRecovery/NoteConflictChoice.json']:
 f=out/'home/Library/Application Support'/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(('normal sentinel '+name).encode());sentinels[str(f)]=sha(f)
 actual=Path.home()/'Library/Application Support'/name;sentinels[str(actual)]=sha(actual) if actual.is_file() else None
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
mac=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip();ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-D','DEBUG','-swift-version','5','-sdk',mac,'-target','arm64e-apple-macos27.0','-parse-as-library','-module-cache-path',out/'modules']
ib=['xcrun','swiftc','-D','DEBUG','-swift-version','5','-sdk',ios,'-target','arm64-apple-ios27.0','-module-cache-path',out/'ios-modules']
commands=[('protocol',base+['-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol',proto,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',base+['-I',out,*sources,main,out/'StreamProtocol.o','-o',out/'check']),('native-reader-search',[out/'check',out]),('project',['plutil','-lint',root/'iOSClient/Sill.xcodeproj/project.pbxproj']),('ios-protocol',ib+['-emit-module','-module-name','StreamProtocol',proto,'-emit-module-path',out/'ios/StreamProtocol.swiftmodule']),('ios27-canvas-typecheck',ib+['-parse-as-library','-I',out/'ios','-typecheck',*iosSources])]
results=[]
for n,c in commands:
 r=subprocess.run(list(map(str,c)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(n+'.log')).write_text(r.stdout+r.stderr);results.append(dict(name=n,exitCode=r.returncode,command=list(map(str,c))));print(n,r.returncode,(r.stdout+r.stderr)[-3500:],flush=True)
 if r.returncode:break
after={str(f.relative_to(root)):sha(f) for f in inputs};normal=all((sha(Path(f)) if Path(f).is_file() else None)==h for f,h in sentinels.items());unchanged=all(sha(Path(f))==h for f,h in fixtures.items())
passed=len(results)==len(commands) and all(x['exitCode']==0 for x in results) and before==after and normal and unchanged
record=dict(passed=passed,commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),dirty=subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),inputs=before,after=after,sourceUnchanged=before==after,normalSentinelHashes=sentinels,normalSentinelsUnchanged=normal,fixtureHashes=fixtures,fixturesUnchanged=unchanged,results=results,wholeCanvasIOS27=True,HOMEpreserved=env.get('HOME')==os.environ.get('HOME'),GUI=False,HTTP=False,device=False,Host=False,installation=False,notifications=False,independentReview='pending',actualStoreWorkspaceUIIntegrated=False)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('RECEIPT',out/'result.json');raise SystemExit(0 if passed else 1)
