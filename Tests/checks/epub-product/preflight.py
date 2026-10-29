#!/usr/bin/env python3
"""계약 대기 중 core typecheck/자체 Vault raw 읽기만 확인한다. 전체 수용 검사가 아니다."""
import argparse,hashlib,json,os,plistlib,subprocess,uuid,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();root=Path(__file__).resolve().parents[3]
archive=Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']);assert any(x.exists() and x.samefile(archive) for x in [a.output,*a.output.parents])
out=a.output.resolve()/('preflight-'+str(uuid.uuid4()));out.mkdir(parents=True)
for n in ['home','tmp','modules','vault']:(out/n).mkdir()
canvas=root/'iOSClient/CanvasBridge'
names=['CanvasModel','CanvasDocument','CanvasDocumentFiles','CanvasStore','VaultPDFExcerpt','VaultPDFViewState','CanvasRelay','CanvasDocumentRelay','ControlRoomProjection','CanvasCardMerge','CanvasCardTags','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','VaultEPUB','VaultEPUBExcerpt','VaultEPUBReader']
sources=[canvas/(n+'.swift') for n in names]+[root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift'];proto=root/'Sources/StreamProtocol/TestDestinations.swift'
reader=out/'PDFNativeReader.swift';reader.write_text((canvas/'VaultPDFReader.swift').read_text().split('struct VaultPDFPageControls:')[0])
inputs=sources+[proto,canvas/'VaultPDFReader.swift',canvas/'CanvasWorkspace.swift',Path(__file__),Path(__file__).with_name('raw-vault.cjs'),root/'CanvasRelay/relay/obsidian-vault.js',root/'CanvasRelay/relay/server.js']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(root)):sha(p) for p in inputs}
# Valid, self-owned archive. No source copies or new original-app observations.
with zipfile.ZipFile(out/'vault/book.epub','w') as z:
 z.writestr('mimetype','application/epub+zip');z.writestr('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
 z.writestr('book.opf','<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>')
 z.writestr('one.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><head><title>자체 원문</title></head><body><p id="one">자체 EPUB 인용 😀 원문</p></body></html>')
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
b=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
cmds=[('protocol',b+['-emit-module','-module-name','StreamProtocol',proto,'-emit-module-path',out/'StreamProtocol.swiftmodule']),('core-typecheck',b+['-I',out,'-typecheck',*sources,reader]),('workspace-syntax',['xcrun','swiftc','-frontend','-parse',canvas/'CanvasWorkspace.swift']),('project-plist',['plutil','-lint',root/'iOSClient/Sill.xcodeproj/project.pbxproj']),('raw-vault',['node',Path(__file__).with_name('raw-vault.cjs'),out/'vault'])]
results=[]
for name,cmd in cmds:
 r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240);(out/(name+'.log')).write_text(r.stdout+r.stderr);print(name,r.returncode,(r.stdout+r.stderr)[-4500:],flush=True);results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
 if r.returncode:break
after={str(p.relative_to(root)):sha(p) for p in inputs};passed=len(results)==len(cmds) and all(x['exitCode']==0 for x in results) and before==after
(out/'result.json').write_text(json.dumps(dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sourceBefore=before,sourceAfter=after,sourceUnchanged=before==after,results=results,passed=passed,actualOwnVaultRawRead=True,StoreExecution=False,HTTP=False,GUI=False,device=False,installation=False,wholeSDK=False,wholeEPUBAccepted=False),ensure_ascii=False,indent=2)+'\n');print('PREFLIGHT',out/'result.json');raise SystemExit(0 if passed else 1)
