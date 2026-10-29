#!/usr/bin/env python3
"""Store PDF 보기 접합만 검사한다. 전체 iOS SDK는 부모의 최종 결합 검사다."""
import argparse,hashlib,json,os,plistlib,shutil,subprocess,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);mode=p.add_mutually_exclusive_group();mode.add_argument('--bookmarks',action='store_true');mode.add_argument('--cloze',action='store_true');a=p.parse_args()
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
out=a.output.resolve()/('native-'+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['home','tmp','modules','vault']: (out/n).mkdir()
canvas=root/'iOSClient/CanvasBridge'
names=['CanvasModel','CanvasDocument','CanvasDocumentFiles','CanvasStore','VaultPDFExcerpt','VaultPDFViewState','CanvasCardMerge','CanvasCardTags','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','CanvasRelay','CanvasDocumentRelay','ControlRoomProjection','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']
main=root/'Tests/checks/obsidian-review-cards/ClozeChecks.swift' if a.cloze else Path(__file__).with_name('BookmarkChecks.swift' if a.bookmarks else 'main.swift')
sources=[canvas/(n+'.swift') for n in names]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',main]
extra=[]
if a.bookmarks or a.cloze:
 support=out/'PDFCheckSupport.swift';support.write_text(Path(__file__).with_name('main.swift').read_text().split('@main struct PDFProductChecks')[0]);extra.append(support)
if a.bookmarks:
 legacyBytes=subprocess.check_output(['git','show','cd5e79105904e25438c50a53b845c2d17a2b6b3e:iOSClient/CanvasBridge/VaultPDFViewState.swift'],cwd=root)
 legacy=out/'LegacyPDFViewState.swift';legacy.write_text(legacyBytes.decode().replace('VaultPDFViewState','LegacyPDFViewState'));extra.append(legacy)
 (out/'legacy-input.json').write_text(json.dumps(dict(commit='cd5e79105904e25438c50a53b845c2d17a2b6b3e',path='iOSClient/CanvasBridge/VaultPDFViewState.swift',sha256=hashlib.sha256(legacyBytes).hexdigest(),adaptation='type name only; exact old codec emits legacy Markdown and Codable request'),indent=2))
if a.cloze:
 workspace=(canvas/'CanvasWorkspace.swift').read_text()
 assert 'VaultReviewFields(store:store,session:session,showRawMarkdown:{ vaultRawMarkdown = true })\n                                .id(session.inputSessionID)' in workspace, 'field identity must survive selection changes'
 fields=workspace.split('private struct VaultReviewFields: View {')[1].split('private struct VaultReviewSheet: View {')[0]
 def function(signature):
  start=fields.index(signature);opening=fields.index('{',start);depth=1
  for index in range(opening+1,len(fields)):
   depth+=(fields[index]=='{')-(fields[index]=='}')
   if depth==0:return fields[start:index+1].replace('private ','',1)
 bindings=out/'ClozeUIBindings.swift'
 bindings.write_text('''import Foundation
import SwiftUI
@propertyWrapper struct ClozeState<Value> {
 final class Box { var value:Value; init(_ v:Value){value=v} }
 private let box:Box
 init(wrappedValue:Value){box=Box(wrappedValue)}
 var wrappedValue:Value { get{box.value} nonmutating set{box.value=newValue} }
}
@MainActor struct ClozeUIBindings {
 let store:CanvasStore
 let session:CanvasStore.VaultReviewEditSession
 let showRawMarkdown:()->Void
 @ClozeState var frontSelection=NSRange(location:0,length:0)
 @ClozeState var backSelection=NSRange(location:0,length:0)
 @ClozeState var frontBusy=false
 @ClozeState var backBusy=false
'''+ '\n'.join(function(s) for s in ['    private func inputBusy(', '    private func text(', '    private var questionSelection:', '    private var answerSelection:'])+'\n}\n')
 extra.append(bindings)

protocol=root/'Sources/StreamProtocol/TestDestinations.swift'
reader=out/'PDFNativeReader.swift';reader.write_text((canvas/'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
inputs=sources+[protocol,canvas/'VaultPDFReader.swift',canvas/'CanvasWorkspace.swift',canvas/'PencilCanvas.swift',Path(__file__),Path(__file__).with_name('main.swift'),Path(__file__).with_name('vault.cjs')]+list((root/'CanvasRelay/relay').glob('*.js'))+[root/'CanvasRelay/relay/vault-note-exchange.py',root/'CanvasRelay/test-guard.cjs']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip();tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
metadata=plistlib.loads((root/'Tests/checks/ink-glyph-edit/Info.plist').read_bytes());metadata.update(CCRSourceCommit=commit,CCRSourceTree=tree)
info=out/'Info.plist';info.write_bytes(plistlib.dumps(metadata))
identity=str(uuid.uuid4());support=out/'home/Library/Application Support';state=support/'CCRIntegrationTests'/identity/'state';state.mkdir(parents=True)
(state.parent/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='own-pdf-product-fixture-01234567890123456789')))
protected={}
for n in ['CanvasScene.json','CanvasDocumentSource.json','CanvasWorkspace/bookmark.json','CanvasConflictRecovery/NoteConflictChoice.json','CanvasConflictRecovery/CanvasConflictChoice.json']:
 f=support/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(('normal sentinel '+n).encode());protected[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/',PDF_VIEW_NODE=shutil.which('node') or '',PDF_VIEW_BACKEND=str(Path(__file__).with_name('vault.cjs')),PDF_VIEW_VAULT=str(out/'vault'))
assert env['PDF_VIEW_NODE']
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
commands=[('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',protocol,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),('compile',base+['-I',out,*sources,*extra,reader,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'check']),('native-store-pdf',[out/'check',out,'--ccr-test-runtime',identity])]
results=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(name+'.log')).write_text(r.stdout+r.stderr);print(name,r.returncode,(r.stdout+r.stderr)[-6500:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
children=[json.loads(line) for line in (out/'tmp/children.jsonl').read_text().splitlines()] if (out/'tmp/children.jsonl').exists() else []
children_ok=bool(children) and all(x['pidGone'] and x['exitCode']==0 for x in children)
after=hashes();normal=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in protected.items())
code=0 if len(results)==3 and all(x['exitCode']==0 for x in results) and before==after and normal and children_ok else 1
(out/'result.json').write_text(json.dumps(dict(commit=commit,tree=tree,dirty=subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True),inputs=before,after=after,sourceUnchanged=before==after,normalProtectedFileHashes=protected,normalUnchanged=normal,atomicHelperChildren=children,atomicHelperChildrenGone=children_ok,commands=results,exitCode=code,actualStore=True,actualObsidianFiles=True,HTTP=False,GUI=False,physicalPencil=False,installed=False,wholeSDK='parent-final-union'),indent=2)+'\n');print(out/'result.json');raise SystemExit(code)
