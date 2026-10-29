#!/usr/bin/env python3
"""CanvasDocument 실제 PKDrawing/Files 검사. 출력은 승인 외장 경로에만 쓴다."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, subprocess, uuid
root = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--sdk-check', action='store_true')
p.add_argument('--store', action='store_true', help='실제 단일 Document Store/Files 제품 경로')
p.add_argument('--repairs', type=Path, help='DOC-R1/R2/R3 독립 검수 근거 폴더')
p.add_argument('--storage-reuse', action='store_true')
a = p.parse_args()
archive = Path(json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route','path','development-archive','--project','BT_CCR-ipad'],text=True))['path']).resolve()
assert a.output.resolve().is_relative_to(archive)
a.output.mkdir(parents=True,exist_ok=True)
out = a.output.resolve() / ('native-' + str(uuid.uuid4())); out.mkdir()
for name in ['home','tmp']: (out/name).mkdir()
env = dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp')+'/')
canvas = root/'iOSClient/CanvasBridge'
sources = [canvas/(n+'.swift') for n in ['CanvasModel','CanvasDocument','CanvasDocumentFiles']]
project = root/'iOSClient/Sill.xcodeproj/project.pbxproj'
info = root/'Tests/checks/ink-glyph-edit/Info.plist'
inputs = sources+[Path(__file__).with_name('main.swift'),Path(__file__),project,info]
review_files = []
if a.repairs:
    inputs.append(Path(__file__).with_name('regression.swift'))
    review_files = [a.repairs/'result.json',a.repairs/'DocumentBoundaryCases.swift',a.repairs/'NestedLockCases.swift',
                    a.repairs/'native/observations.json',a.repairs/'nested-lock/nested-lock-observations.json']
    review_files += [a.repairs/('nested-lock/unsupported-'+n+'.json') for n in ['nodes','links','annotations']]
    original = list((a.repairs/'native/directory-race').glob('*.sill'))
    assert len(original)==1
    pointer=original[0]/'current.json'; h=json.loads(pointer.read_text())
    review_files += [pointer,original[0]/'revisions'/h['generation'].lower()/'document.json']
def review_hashes(): return {str(x.relative_to(a.repairs)):hashlib.sha256(x.read_bytes()).hexdigest() for x in review_files}
review_before=review_hashes()
baseline_sha=None
if a.storage_reuse:
    assert a.repairs, '--storage-reuse requires the preserved reviewer input folder'
    inputs.append(Path(__file__).with_name('storage.swift'))
    baseline=subprocess.check_output(['git','show','782978d7bc574080ae72fd9ebd48b5699473f0ea:iOSClient/CanvasBridge/CanvasDocumentFiles.swift'],cwd=root)
    (out/'CanvasDocumentFiles-baseline.swift').write_bytes(baseline)
    baseline_sha=hashlib.sha256(baseline).hexdigest()
    for path in sources[:2]:
        assert path.read_bytes()==subprocess.check_output(['git','show','782978d7bc574080ae72fd9ebd48b5699473f0ea:'+str(path.relative_to(root))],cwd=root)

def hashes(): return {str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
before=hashes()
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip()
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
commands=[('compile',['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules',*sources,inputs[3],'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'check']),('native-files',[out/'check',out]),('project-plist',['plutil','-lint',project])]
if a.sdk_check:
    ios=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    commands.append(('ios27-unit-typecheck',['xcrun','swiftc','-D','DEBUG','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'ios-modules','-typecheck',*sources]))
if a.store:
    assert not a.repairs
    sources += [canvas/(n+'.swift') for n in ['CanvasStore','VaultPDFExcerpt','CanvasCardMerge','CanvasCardTags','CanvasInkTextEditing','CanvasInkShapeProposal','CanvasInkMathProposal','CanvasInkSpacingProposal','CanvasRelay','CanvasDocumentRelay','ControlRoomProjection']]
    sources += [root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift',Path(__file__).with_name('store.swift')]
    protocol = root/'Sources/StreamProtocol/TestDestinations.swift'
    ios_sources = sorted(canvas.glob('*.swift')) + [root/'iOSClient'/(n+'.swift') for n in ['IPadAudioSession','IPadAudioLeaseState','IPadAudioLeaseCoordinator']] + [root/'iOSClient/TestDestinations/TestDestinationsPolicy.swift']
    inputs += sources + [protocol,canvas/'PencilCanvas.swift',canvas/'CanvasWorkspace.swift'] + (ios_sources if a.sdk_check else [])
    before = hashes()
    metadata = plistlib.loads(info.read_bytes()); metadata.update(CCRSourceCommit=commit,CCRSourceTree=tree)
    info = out/'Info.plist'; info.write_bytes(plistlib.dumps(metadata))
    identity = str(uuid.uuid4())
    support = out/'home/Library/Application Support'
    state = support/'CCRIntegrationTests'/identity/'state'; state.mkdir(parents=True)
    (state.parent/'context.json').write_text(json.dumps(dict(schema='ccr.ipad-test-context/v1',id=identity,commit=commit,tree=tree,relayAddress='http://192.168.88.88:4242',token='own-document-fixture-01234567890123456789')))
    base = ['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
    commands = [('protocol',base+['-emit-module','-emit-object','-module-name','StreamProtocol',protocol,'-emit-module-path',out/'StreamProtocol.swiftmodule','-o',out/'StreamProtocol.o']),
        ('compile-store',base+['-I',out,*sources,out/'StreamProtocol.o','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'store-check']),
        ('native-store',[out/'store-check',out,'--ccr-test-runtime',identity]),('project-plist',['plutil','-lint',project])]
    if a.sdk_check:
        (out/'ios').mkdir()
        iosbase = ['xcrun','swiftc','-D','DEBUG','-sdk',ios,'-target','arm64-apple-ios27.0','-swift-version','5','-module-cache-path',out/'ios-modules']
        commands += [('ios-protocol',iosbase+['-emit-module','-module-name','StreamProtocol',protocol,'-emit-module-path',out/'ios/StreamProtocol.swiftmodule']),('ios27-store-ui-typecheck',iosbase+['-parse-as-library','-I',out/'ios','-typecheck',*ios_sources])]

if a.repairs:
    (out/'repair').mkdir()
    commands += [
        ('compile-repairs',['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules',*sources,Path(__file__).with_name('regression.swift'),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/'repair-check']),
        ('native-repairs',[out/'repair-check',out/'repair',a.repairs])
    ]
if a.storage_reuse:
    old_head=json.loads(pointer.read_text())
    raw_input=original[0]/'revisions'/old_head['generation'].lower()/'document.json'
    common=['xcrun','swiftc','-D','DEBUG','-sdk',sdk,'-target','arm64e-apple-macos27.0','-swift-version','5','-parse-as-library','-module-cache-path',out/'modules']
    for label,product in [('before',[*sources[:2],out/'CanvasDocumentFiles-baseline.swift']),('after',sources)]:
        target=out/('storage-'+label); target.mkdir()
        cmd=common+(['-D','STORAGE_BASELINE'] if label=='before' else [])+list(product)+[Path(__file__).with_name('storage.swift'),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',info,'-o',out/('storage-'+label+'-check')]
        commands += [('compile-storage-'+label,cmd),('native-storage-'+label,[out/('storage-'+label+'-check'),target,raw_input,out/'storage-before/normal'])]
results=[]
for name,cmd in commands:
    r=subprocess.run(list(map(str,cmd)),cwd=root,env=env,capture_output=True,text=True,timeout=240)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    print(name,r.returncode,(r.stdout+r.stderr)[-6500:],flush=True)
    results.append(dict(name=name,exitCode=r.returncode,command=list(map(str,cmd))))
    if r.returncode: break
after=hashes()
comparison={}
if a.repairs and (out/'repair/repair-observations.json').exists():
    old=json.loads((a.repairs/'native/observations.json').read_text())
    old_nested=json.loads((a.repairs/'nested-lock/nested-lock-observations.json').read_text())
    new=json.loads((out/'repair/repair-observations.json').read_text())
    assert old['directorySwap']['saveReturnedSuccess'] and all(not x['saveReturnedSuccess'] and x['pendingOnCanonical'] for x in new['directorySwap'])
    for before_case,after_case in zip(old_nested['nested'],new['nested']):
        assert before_case['originalInputSHA256']==after_case['originalInputSHA256']
        assert before_case['decodeAccepted'] and before_case['saveAccepted'] and before_case['reopenedFieldMissing']
        assert not after_case['decodeAccepted'] and not after_case['saveAccepted']
    assert old_nested['lock']['blockedWhileOtherProcessHoldsLock'] and new['lock']['returnedBusyBeforeUnlock']
    comparison=dict(beforeDirectory=old['directorySwap'],afterDirectory=new['directorySwap'],beforeNested=old_nested['nested'],afterNested=new['nested'],beforeLock=old_nested['lock'],afterLock=new['lock'])
storage={}
if a.storage_reuse and (out/'storage-after/storage-observations.json').exists():
    old=json.loads((out/'storage-before/storage-observations.json').read_text())
    new=json.loads((out/'storage-after/storage-observations.json').read_text())
    assert old['noOp']['deltaBytes']>0 and new['noOp']['deltaBytes']==0 and new['noOp']['newAllPaths']==0
    assert old['normal']['baseDirectoryCreated'] and not new['normal']['baseDirectoryCreated']
    assert new['normal']['deltaBytes'] < old['normal']['deltaBytes']
    storage=dict(before=old,after=new,baselineFilesSHA256=baseline_sha,baselineCommit='782978d7bc574080ae72fd9ebd48b5699473f0ea')
record=dict(commit=commit,tree=tree,sourceHashes=before,sourceHashesAfter=after,sourceUnchanged=before==after,results=results,output=str(out),passed=len(results)==len(commands) and all(x['exitCode']==0 for x in results) and before==after and review_before==review_hashes() and (not a.repairs or bool(comparison)) and (not a.storage_reuse or bool(storage)),actualPKDrawing=True,actualNativeFiles=True,injectedFailureHooks=True,reviewHashesBefore=review_before,reviewHashesAfter=review_hashes(),repairComparison=comparison,storageComparison=storage,StoreIntegrated=a.store,pairedRelay=False,UIWriteEnabled=False,installation=False,wholeProductAccepted=False)
(out/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print('RECEIPT',out/'result.json',flush=True)
raise SystemExit(0 if record['passed'] else 1)
