#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--output',required=True)
parser.add_argument('--suite',choices=['native','monitor-selection','recovery'],default='native')
args=parser.parse_args()
out=Path(args.output)
if not out.is_absolute() or out.exists(): raise SystemExit('fresh routed output path required')
out.mkdir()
here=Path(__file__).resolve().parent
root=here.parents[2]
source=root/'Sources/SillHost/ExtendedDesktop.swift'
text=source.read_text()
def block(text, signature):
    start=text.index(signature)
    end=text.index('{',start)+1
    depth=1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}')
        end+=1
    return text[start:end]

adapter='\n'.join(block(text, s).replace('private static func','static func',1) for s in [
    'private static func valid(', 'private static func configure(',
    'private static func recoveryBounds(', 'static func originRight('])
# Only CG boundary symbols are remapped; the extracted production algorithm is unchanged.
for name in ['CGDisplayIsActive','CGDisplayMirrorsDisplay','CGDisplayIsInMirrorSet','CGDisplayCopyDisplayMode','CGDisplayBounds','kCGNullDirectDisplay',
    'CGBeginDisplayConfiguration','CGConfigureDisplayMirrorOfDisplay','CGConfigureDisplayOrigin',
    'CGCancelDisplayConfiguration','CGCompleteDisplayConfiguration']:
    adapter=adapter.replace(name,'fixture'+name)
fixture=(here/'Fixtures.swift').read_text().replace('// VALID_ADAPTER',adapter)
inventory=root/'Sources/SillHost/DisplayInventory.swift'
protocol=(root/'Sources/StreamProtocol/Switcher.swift').read_text()
inputs={'Fixtures.swift':fixture,'main.swift':(here/'main.swift').read_text(),
    'DisplayInventory.swift':inventory.read_text().replace('import StreamProtocol\n',''),
    'DisplayTypes.swift':'import Foundation\n'+block(protocol,'public struct DisplayInfo:')+'\n'+block(protocol,'public struct DisplaySelection:'),
    'DesktopLifecycle.swift':text.split('// MARK: macOS display adapter')[0].replace('import StreamProtocol\n',''),
    'Viewport.swift':'import Foundation\n'+block((root/'Sources/StreamProtocol/Viewport.swift').read_text(),'public struct Viewport:')}
coordinator=(root/'Sources/SillHost/StreamCoordinator.swift').read_text()
recovery = ''
if 'private enum OwnedDesktopRecovery' in coordinator:
    recovery = block(coordinator, 'private enum OwnedDesktopRecovery') + '\nprivate var ownedDesktopRecovery = OwnedDesktopRecovery.idle\n'
    recovery += block(coordinator, 'private func recoverOwnedDesktop(')
fixture=fixture.replace('// COORDINATOR_ADAPTER', recovery + '\n' + block(coordinator,'private func displaysChanged(').replace('private func','func',1))
inputs['Fixtures.swift']=fixture
assert 'ownedBounds = display.bounds' in block(text,'isValid: {')
catalog=(root/'Sources/SillHost/WindowCatalog.swift').read_text()
assert 'invalidate(preservingDisplay: self.extendedDesktopID)' in catalog
assert 'frames: displays.map(\\.frame)' in catalog
assert 'preservingDisplay: extendedDesktopID' in catalog
if args.suite == 'monitor-selection':
    inputs={p.name:p.read_text() for p in (root/'Sources/StreamProtocol').glob('*.swift')}
    for path in ['Sources/SillHost/DisplayInventory.swift','Sources/SillHost/SourceInputFence.swift']:
        p=root/path
        inputs[p.name]=p.read_text().replace('import StreamProtocol\n','')
    regression=(here.parent/'monitor-selection/main.swift').read_text().replace('import Foundation\n','').replace('import StreamProtocol\n','')
    regression=regression.split('let peer = NSObject()',1)[0]
    regression+='print("MONITOR_SELECTION_CHECKS total=\\(checks)")\n'
    inputs['main.swift']='import Foundation\n@main struct RegressionChecks { @MainActor static func main() {\n'+regression+'\n} }\n'
if args.suite == 'recovery':
    select = block(coordinator, 'func select(_ source:')
    prefix = select[:select.index('        rectCache = nil')]
    pipeline = block(coordinator, 'private func startPipeline(')
    validation = block(pipeline, 'if let desktopSelection {')
    fixture = (here/'Recovery.swift').read_text()
    pick = block(coordinator, 'enum PickOrigin') + '\n' + block(coordinator, 'private struct SourcePick').replace('private struct', 'struct', 1) + '\nvar pickSequence: UInt64 = 0\nvar settledPickSequence: UInt64 = 0\nvar pickArrivedWhileSwitching: SourcePick?\n'
    pick += block(coordinator, 'private func cancelSourcePicks(').replace('private func', 'func', 1)
    pick += '\n' + block(coordinator, 'private func reserveSourceIntent(').replace('private func', 'func', 1)
    fixture = fixture.replace('// SOURCE_PICK', pick)
    fixture = fixture.replace('// SELECT_PREFIX', prefix + """
        if source == .none { active = .none; return }
        do { try await startPipeline(source: source) } catch { active = .none }
        broadcastList()
    }
""")
    fixture = fixture.replace('// PIPELINE_VALIDATION', validation)
    fixture = fixture.replace('// DISPLAYS_CHANGED', block(coordinator, 'private func displaysChanged(').replace('private func','func',1))
    fixture = fixture.replace('// HANDLE_PICK', block(coordinator, 'private func handlePick(').replace('private func handlePick', 'private func productionHandlePick', 1))
    fixture = fixture.replace('// OWNED_RECOVERY', recovery)
    inputs = {'Recovery.swift': fixture, 'main.swift': (here/'recovery-main.swift').read_text(),
        'DisplayInventory.swift': inventory.read_text().replace('import StreamProtocol\n',''),
        'SourceInputFence.swift': (root/'Sources/SillHost/SourceInputFence.swift').read_text().replace('import StreamProtocol\n',''),
        'DisplayTypes.swift': 'import Foundation\n' + block(protocol, 'public enum StreamSource:') + '\n' + block(protocol, 'public struct DisplayInfo:') + '\n' + block(protocol, 'public struct DisplaySelection:')}
sha=lambda b:hashlib.sha256(b).hexdigest()
hashes={k:sha(v.encode()) for k,v in inputs.items()}
payload=json.dumps({'sources':{k:base64.b64encode(v.encode()).decode() for k,v in inputs.items()},'hashes':hashes}).encode()
runner=(here.parent/'extended-desktop/remote.py').read_text()
start=runner.index("    collision = subprocess.run(")
end=runner.index("    disk = subprocess.check_output(",start)
runner=runner[:start]+runner[end:]
source_paths=[source,inventory,root/'Sources/SillHost/WindowCatalog.swift',root/'Sources/SillHost/StreamCoordinator.swift']
source_paths += list(here.glob('*.swift')) + [here/'run.py',here.parent/'extended-desktop/remote.py']
source_paths += [root/'Sources/StreamProtocol/Viewport.swift',root/'Sources/StreamProtocol/Switcher.swift']
if args.suite == 'recovery':
    source_paths += [root/'Sources/SillHost/SourceInputFence.swift']
if args.suite == 'monitor-selection':
    source_paths += list((root/'Sources/StreamProtocol').glob('*.swift'))
    source_paths += [root/'Sources/SillHost/SourceInputFence.swift',here.parent/'monitor-selection/main.swift']
before={str(p.relative_to(root)):sha(p.read_bytes()) for p in source_paths}
proc=subprocess.run(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],input=payload,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=240)
log=proc.stdout.decode(errors='replace')
(out/'run.log').write_text(log)
records=[json.loads(l.removeprefix('RESULT_JSON ')) for l in log.splitlines() if l.startswith('RESULT_JSON ')]
receipt={'suite':args.suite,'scope':'actual adapter and inventory/coordinator methods under controlled boundaries in volatile Mini RAM; not native UI/Pencil/sourceguard transfer acceptance','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceSHA256':before,'sourceUnchanged':all(sha(p.read_bytes())==before[str(p.relative_to(root))] for p in source_paths),'inputHashes':hashes,'transportHashMatched':'INPUT_SHA256 '+sha(payload) in log,'remote':records[-1] if records else None,'exit':proc.returncode}
(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(log)
print('RECEIPT '+str(out/'result.json'))
remote=receipt['remote'] or {}
verified=receipt['sourceUnchanged'] and receipt['transportHashMatched'] and all(remote.get(key) for key in [
    'inputHashesMatched','memoryInputUnchanged','childrenReaped','sourceRemoved'])
raise SystemExit(proc.returncode or (0 if verified and remote.get('exitCode') == 0 else 2))
