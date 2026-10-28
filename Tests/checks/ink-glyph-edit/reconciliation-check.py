#!/usr/bin/env python3
"""실제 Relay/Store의 보존 충돌 반례. HTTP는 URLProtocol fixture이며 네트워크/인식 호출은 없다."""
from pathlib import Path
import argparse, subprocess, os, json, uuid, hashlib
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);args=p.parse_args()
route=json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))
assert any(x.exists() and os.path.samefile(x,route['path']) for x in [args.output,*args.output.parents])
args.output.mkdir(parents=True,exist_ok=True)
out=Path(subprocess.check_output(['/bin/pwd','-P'],cwd=args.output,text=True).strip())/('reconciliation-'+str(uuid.uuid4()));out.mkdir()
for n in ['home','tmp']:(out/n).mkdir()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
sources=[root/'iOSClient/CanvasBridge'/n for n in ['CanvasModel.swift','CanvasStore.swift','CanvasInkTextEditing.swift','CanvasInkShapeProposal.swift','CanvasInkMathProposal.swift','CanvasRelay.swift','ControlRoomProjection.swift']]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',here/'ReconciliationCheck.swift']

wire=here/'reconciliation-wire-example.json'
wireHash=hashlib.sha256(wire.read_bytes()).hexdigest()
inputs=sources+[here/'reconciliation-wire-example.json',here/'reconciliation-provenance.json']+[root/'Sources/StreamProtocol/TestDestinations.swift',root/'iOSClient/CanvasBridge/CanvasWorkspace.swift',here/'WorkspaceReconciliationHarness.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before=hashes();sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
base=['xcrun','swiftc','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',str(out/'modules')]
commands=[('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',root/'Sources/StreamProtocol/TestDestinations.swift','-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),
 ('compile',base+['-I',out,*sources,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',here/'Info.plist','-o',out/'check']),
 ('actual-relay-store',[out/'check',out,here/'reconciliation-wire-example.json'])]
def extract(text, marker):
 start=text.index(marker);opening=text.index('{',start);depth=1;end=opening+1
 while depth:
  depth += (text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
workspace=(root/'iOSClient/CanvasBridge/CanvasWorkspace.swift').read_text()
markers=['private enum CanvasConflictChoiceState:', 'private struct CanvasConflictChoice:', 'private func conflictChoiceURL()',
 'private func readCanvasConflictNote()', 'private func resolveCanvasConflict(', 'private func readNewConflictMaterials()',
 'private func sceneBytes()', 'private static func canvasVaultCheckpointURL()', 'private func saveCanvasVaultCheckpoint()',
 'private func synchronizeCanvasToVault()', 'private func refreshCanvasFromVault()']
members=[extract(workspace,k) for k in markers]
template=(here/'WorkspaceReconciliationHarness.swift').read_text().replace('// EXACT_PRODUCT_MEMBERS','\n'.join(members))
template+='\n@MainActor enum SceneRenderer { static var calls=0; static func png(scene:CanvasScene) async -> Data? { calls += 1; return nil } }\n'
(out/'WorkspaceHarness.swift').write_text(template)
commands[1][1].insert(-2,out/'WorkspaceHarness.swift')
records=[]
for name,cmd in commands:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240)
 log=r.stdout+r.stderr;(out/(name+'.log')).write_text(log);print(name,r.returncode,log[-7500:],flush=True)
 records.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
record=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),sourceClean=not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),sourceHashes=before,sourceHashesAfter=hashes(),sourceUnchanged=before==hashes(),output=str(out),results=records,passed=len(records)==3 and all(r['exitCode']==0 for r in records) and before==hashes(),extractedMembers={k:hashlib.sha256(v.encode()).hexdigest() for k,v in zip(markers,members)},transport='URLProtocol fixture; actual Workspace actions, native Store/file API; not paired HTTP or SwiftUI runtime',wireExample=str(wire),wireExampleSHA256=wireHash,wireUnchanged=wireHash==hashlib.sha256(wire.read_bytes()).hexdigest(),recognizerExecuted=False,installation=False,deviceHostChanges=0)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print('VAULT_CONFLICT_OUTPUT',out,flush=True)
raise SystemExit(0 if record['passed'] else 1)
