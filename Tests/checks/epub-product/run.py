#!/usr/bin/env python3
"""계약 후보의 EPUB Store·Files 경계를 실제 native로 검사한다. 전체 iOS SDK는 부모의 최종 결합 검사다."""
import argparse,hashlib,json,os,plistlib,shutil,subprocess,uuid,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
out=a.output.resolve()/('native-'+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['home','tmp','modules','vault']: (out/n).mkdir()
canvas=root/'iOSClient/CanvasBridge'
names=['CanvasModel','CanvasDocument','CanvasDocumentFiles','CanvasStore','VaultPDFExcerpt','VaultPDFViewState','CanvasCardMerge','CanvasCardTags','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','CanvasRelay','CanvasDocumentRelay','ControlRoomProjection','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']
sources=[canvas/(n+'.swift') for n in names]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',Path(__file__).with_name('main.swift')]
protocol=root/'Sources/StreamProtocol/TestDestinations.swift'
reader=out/'PDFNativeReader.swift';reader.write_text((canvas/'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
inputs=sources+[protocol,canvas/'VaultPDFReader.swift',canvas/'CanvasWorkspace.swift',canvas/'PencilCanvas.swift',Path(__file__),Path(__file__).with_name('vault.cjs')]+list((root/'CanvasRelay/relay').glob('*.js'))+[root/'CanvasRelay/relay/vault-note-exchange.py',root/'CanvasRelay/test-guard.cjs']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
metadata=plistlib.loads((root/'Tests/checks/ink-glyph-edit/Info.plist').read_bytes());metadata.update(CCRSourceCommit=commit,CCRSourceTree=tree)
info=out/'Info.plist';info.write_bytes(plistlib.dumps(metadata))
identity=str(uuid.uuid4());support=out/'home/Library/Application Support';state=support/'CCRIntegrationTests'/identity/'state';state.mkdir(parents=True)
(state.parent/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='own-epub-product-fixture-01234567890123456789')))
protected={}
for n in ['CanvasScene.json','CanvasDocumentSource.json','CanvasWorkspace/bookmark.json','CanvasConflictRecovery/NoteConflictChoice.json','CanvasConflictRecovery/CanvasConflictChoice.json']:
 f=support/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(('normal sentinel '+n).encode());protected[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
# 모두 자체 합성 입력이며 원앱 자료는 복사하지 않는다.
for filename,hidden in [('book.epub',False),('hidden.epub',True)]:
 with zipfile.ZipFile(out/'vault'/filename,'w') as z:
  z.writestr('mimetype','application/epub+zip')
  z.writestr('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
  z.writestr('book.opf','<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>')
  for name in ['one','two']:
   attrs=' hidden="hidden" style="display:none"' if hidden else ''
   z.writestr(name+'.xhtml',f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>자체 원문</title></head><body><p id="target"{attrs}>동일 문구 😀 장 {name} 원문</p></body></html>')
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/',EPUB_PRODUCT_NODE=shutil.which('node') or '',EPUB_PRODUCT_BACKEND=str(Path(__file__).with_name('vault.cjs')),EPUB_PRODUCT_VAULT=str(out/'vault'))
assert env['EPUB_PRODUCT_NODE']
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules','-whole-module-optimization']
commands=[('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',protocol,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',base+['-I',out,*sources,reader,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'check']),('native-store-epub',[out/'check',out,'--ccr-test-runtime',identity])]
results=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(name+'.log')).write_text(r.stdout+r.stderr);print(name,r.returncode,(r.stdout+r.stderr)[-6500:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
children=[json.loads(line) for line in (out/'tmp/children.jsonl').read_text().splitlines()] if (out/'tmp/children.jsonl').exists() else []
children_ok=bool(children) and all(x['pidGone'] and x['exitCode']==0 for x in children)
after=hashes();normal=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in protected.items())
code=0 if len(results)==3 and all(x['exitCode']==0 for x in results) and before==after and normal and children_ok else 1
(out/'result.json').write_text(json.dumps(dict(commit=commit,tree=tree,dirty=subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),inputs=before,after=after,sourceUnchanged=before==after,normalProtectedFileHashes=protected,normalUnchanged=normal,atomicHelperChildren=children,atomicHelperChildrenGone=children_ok,commands=results,exitCode=code,actualStore=True,actualObsidianFiles=True,HTTP=False,GUI=False,physicalPencil=False,installed=False,wholeSDK='parent-final-union',wholeEPUBAccepted=False,moduleGate='e554 P2 repair consumed; Nash re-review pending',contractGate='parent decision pending'),indent=2)+'\n');print(out/'result.json');raise SystemExit(code)
