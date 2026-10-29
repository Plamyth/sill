#!/usr/bin/env python3
"""계약 후보의 EPUB Store·Files 경계를 실제 native로 검사한다. 전체 iOS SDK는 부모의 최종 결합 검사다."""
import argparse,hashlib,json,os,plistlib,shutil,subprocess,uuid,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--contract-boundaries',action='store_true');p.add_argument('--source-repairs',action='store_true');p.add_argument('--source-composition',action='store_true');p.add_argument('--choice-input',type=Path);a=p.parse_args()
assert sum([a.contract_boundaries,a.source_repairs,a.source_composition])<=1
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
out=a.output.resolve()/(('source-composition-' if a.source_composition else 'source-repairs-' if a.source_repairs else 'contract-' if a.contract_boundaries else 'native-')+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['home','tmp','modules','vault']: (out/n).mkdir()
canvas=root/'iOSClient/CanvasBridge'
names=['CanvasModel','CanvasDocument','CanvasDocumentFiles','CanvasStore','VaultPDFExcerpt','VaultPDFViewState','CanvasCardMerge','CanvasCardTags','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','CanvasRelay','CanvasDocumentRelay','ControlRoomProjection','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']
sources=[canvas/(n+'.swift') for n in names]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',Path(__file__).with_name('source-repairs.swift' if a.source_repairs or a.source_composition else 'contract-boundaries.swift' if a.contract_boundaries else 'main.swift')]
protocol=root/'Sources/StreamProtocol/TestDestinations.swift'
reader=out/'PDFNativeReader.swift';reader.write_text((canvas/'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
inputs=sources+[protocol,canvas/'VaultPDFReader.swift',canvas/'CanvasWorkspace.swift',canvas/'PencilCanvas.swift',Path(__file__),Path(__file__).with_name('vault.cjs')]+list((root/'CanvasRelay/relay').glob('*.js'))+[root/'CanvasRelay/relay/vault-note-exchange.py',root/'CanvasRelay/test-guard.cjs']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
choice_input=None
if a.contract_boundaries:
 assert a.choice_input and not a.choice_input.is_symlink() and a.choice_input.resolve().is_relative_to(archive) and a.choice_input.stat().st_size<=2*1024*1024
 data=a.choice_input.read_bytes();(out/'prior-choice.json').write_bytes(data)
 choice_input=dict(path=str(a.choice_input.resolve()),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data))
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
commands=[('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',protocol,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',base+['-I',out,*sources,reader,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'check']),('native-store-epub',[out/'check',out,*([out/'vault/book.epub'] if a.source_repairs or a.source_composition else []),*(['--group-paper-only'] if a.source_composition else []),'--ccr-test-runtime',identity])]
results=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(name+'.log')).write_text(r.stdout+r.stderr);print(name,r.returncode,(r.stdout+r.stderr)[-6500:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
children=[json.loads(line) for line in (out/'tmp/children.jsonl').read_text().splitlines()] if (out/'tmp/children.jsonl').exists() else []
children_ok=(not children) if a.contract_boundaries or a.source_repairs or a.source_composition else bool(children) and all(x['pidGone'] and x['exitCode']==0 for x in children)
after=hashes();normal=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in protected.items())
code=0 if len(results)==3 and all(x['exitCode']==0 for x in results) and before==after and normal and children_ok else 1
(out/'result.json').write_text(json.dumps(dict(commit=commit,tree=tree,dirty=subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),inputs=before,after=after,sourceUnchanged=before==after,normalProtectedFileHashes=protected,normalUnchanged=normal,atomicHelperChildren=children,atomicHelperChildrenGone=children_ok,commands=results,exitCode=code,actualStore=True,actualObsidianFiles=not (a.contract_boundaries or a.source_repairs or a.source_composition),actualDocumentFiles=a.source_composition,contractBoundaries=a.contract_boundaries,sourceRepairBoundaries=a.source_repairs,sourceComposition=a.source_composition,choiceInput=choice_input,HTTP=False,GUI=False,physicalPencil=False,installed=False,wholeSDK='parent-final-union',wholeEPUBAccepted=False,moduleGate='e554 P2 repair consumed; Nash re-review pending',contractGate='parent confirmed raw endpoint and optional recovery sourceKind; service unchanged'),indent=2)+'\n');print(out/'result.json');raise SystemExit(code)
