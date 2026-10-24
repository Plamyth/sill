import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--preflight', action='store_true')
parser.add_argument('--suite', choices=['client','host'], default='client')
args = parser.parse_args()
out = Path(args.output)
if not out.is_absolute() or out.exists(): raise SystemExit('fresh routed output required')
out.mkdir()
here = Path(__file__).resolve().parent
root = here.parents[2]
source = root / 'iOSClient/StreamClient.swift'
text = source.read_text()
def block(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
methods = '\n'.join(block(text,s) for s in ['func select(_ source:', 'func selectDisplay(', 'private func requestDisplay(', 'private func request(', 'func launch(bundleID:', 'private func noteSourceIntent(', 'private func automaticTicket(', 'private func requestAutomatic(', 'private func observeSourceIntent(', 'private func beginAutomaticConnectionOpportunity(', 'private func authenticatedDisplayMacID(', 'private func observeDisplaySelection(', 'private func requestInitialDisplay(', 'private func requestAutomaticDisplay(', 'private func observeSourceSelectionAdmission(', 'private func revokeAutomaticSelection(', 'private func automaticTicketIsCurrent('])
client = (here/'Client.swift').read_text().replace('// CLIENT_METHODS', methods.replace('private ','').replace('UserDefaults.standard', 'defaults'))
client = client.replace('// SOURCE_ADMISSION_STATE', block(text, 'private struct SourceSelectionObservation').replace('private ', '') + '\n' + '\n'.join(line.strip().replace('private ', '') for line in text.splitlines() if 'private var sourceSelectionObservation:' in line or 'private var pendingAutomaticSourceTicket:' in line))
client = client.replace('// EXPECTED_SOURCE_STATE', next(line.strip().replace('private ', '') for line in text.splitlines() if 'private var expectedSourceIntent:' in line))
client = client.replace('// EXPECTED_SOURCE', block(text, 'private enum ExpectedSourceIntent').replace('private ',''))
client = client.replace('// AUTOMATIC_TICKET', '\n'.join(block(text, s).replace('private ','') for s in ['private struct AutomaticSourceTicket', 'private struct AutomaticConnectionOpportunity']))
client = client.replace('// DISPLAY_TYPES', '\n'.join(block(text, s).replace('private ','') for s in ['private struct InitialDisplayOpportunity', 'private struct RememberedDisplay', 'private struct PendingDisplaySelection']))
client = client.replace('// DISPLAY_MEMORY_STATE', next(line.strip().replace('private ', '') for line in text.splitlines() if 'private static var rememberedDisplays:' in line))
client = client.replace('// RESUME_SOURCE',block(text,'if let resume = self.resumeSource'))
client = client.replace('// IDLE_FALLBACK',block(text,'if let ticket = self.automaticTicket'))
inputs = {name:(root/'Sources/StreamProtocol'/name).read_text() for name in ['Switcher.swift','Sentry.swift','SentryControl.swift','AudioPrivacy.swift','AudioForwarding.swift','StreamMessage.swift','AudioRouting.swift']}
golden_path = here/'source-selection-admission-v1-golden.json'
golden_bytes = golden_path.read_bytes()
golden_sha = hashlib.sha256(golden_bytes).hexdigest()
if golden_sha != 'e4443004c443fa7c452df3e784b66127bd4993ffbc75753749867510c1e37818':
    raise SystemExit('shared admission golden hash mismatch')
golden_evidence = {'path': str(golden_path.relative_to(root)), 'sha256': golden_sha, 'bytes': len(golden_bytes)}
inputs[golden_path.name] = golden_bytes.decode('utf-8')
inputs['AdmissionGolden.swift'] = 'import Foundation\nlet sourceSelectionAdmissionGoldenJSON = Data(base64Encoded: "' + base64.b64encode(golden_bytes).decode() + '")!\n'
inputs['Client.swift'] = client
inputs['main.swift'] = (here/'main.swift').read_text()
if args.suite == 'client': inputs['AutomaticDisplay.swift'] = (here/'AutomaticDisplay.swift').read_text()
inputs['SessionLink.swift'] = (root/'iOSClient/SessionLink.swift').read_text().replace('import Network\n','')
if args.suite == 'host':
    inputs.pop('SessionLink.swift')
    coordinator = (root/'Sources/SillHost/StreamCoordinator.swift').read_text()
    methods = '\n'.join(block(coordinator, signature) for signature in [
        'private func reserveSourceIntent(', 'private func admissionIsCurrent(', 'private func admitSourceMessage(',
        'private func sourcePeerDeparted(', 'private func rejectSourceIntent(', 'private func stopIfStillEmpty(', 'private func expirePendingLaunch(', 'private func launchCompleted(', 'private func reconcilePendingLaunch(', 'private func cancelSourcePicks(', 'private func handlePick(', 'func select(_ source:', 'private func startPipeline('])
    declarations = '\n'.join(block(coordinator, signature) for signature in [
        'private struct PendingLaunch', 'enum PickOrigin', 'private struct SourcePick', 'private enum OwnedDesktopRecovery', 'private enum PipelineEpochError'])
    launch = 'if await reconcilePendingLaunch(infos) { return }'
    host = (here/'Host.swift').read_text().replace('// HOST_METHODS', methods.replace('NWConnection','NSObject').replace('private func admitSourceMessage','func admitSourceMessage')).replace('// HOST_TYPES', declarations.replace('private ','')).replace('// LAUNCH_COMPLETION', launch)
    inputs['Host.swift'] = host
    inputs.pop('Client.swift')
    inputs['main.swift'] = (here/'host-main.swift').read_text()
    for name in ['SourceInputFence', 'DisplayInventory']:
        inputs[name+'.swift'] = (root/('Sources/SillHost/'+name+'.swift')).read_text().replace('import StreamProtocol\n','')
    inputs['ProductCoordinator.swiftparse'] = coordinator
    inputs['ProductClient.swiftparse'] = text
    inputs['Ingress.swift'] = 'import Foundation\n' + block(coordinator, 'private final class CoordinatorIngress').replace('private final class', 'final class', 1)
    inputs['SourcePublicationAdmission.swift'] = 'import Foundation\n' + block((root/'Sources/SillHost/StreamServer.swift').read_text(), 'final class SourcePublicationAdmission')
sha = lambda data: hashlib.sha256(data).hexdigest()
hashes = {name:sha(value.encode()) for name,value in inputs.items()}
payload = json.dumps({'sources':{name:base64.b64encode(value.encode()).decode() for name,value in inputs.items()},'hashes':hashes}).encode()
runner = (here.parent/'extended-desktop/remote.py').read_text()
start = runner.find('    collision = subprocess.run(')
if start != -1:
    end = runner.index('    disk = subprocess.check_output(', start)
    runner = runner[:start] + runner[end:]
runner = runner.replace("not name.endswith('.swift')", "not (name.endswith(('.swift', '.swiftparse')) or name == 'source-selection-admission-v1-golden.json')")
runner = runner.replace('command += [str(mount / name) for name in hashes]', 'command += [str(mount / name) for name in hashes if name.endswith(".swift")]')
runner = runner.replace('    ok = run(command, timeout=100)', '    parsed = all(run(["/usr/bin/xcrun", "swiftc", "-frontend", "-parse", str(mount / name)], timeout=20) for name in hashes if name.endswith(".swiftparse"))\n    ok = run(command, timeout=100) if parsed else False')
paths = [root/'iOSClient/SessionLink.swift', root/'Sources/SillHost/StreamServer.swift', source, root/'Sources/SillHost/StreamCoordinator.swift'] + list(here.glob('*.swift')) + [here/'run.py', here/'transport.py', golden_path, here.parent/'extended-desktop/remote.py'] + list((root/'Sources/StreamProtocol').glob('*.swift'))
before = {str(p.relative_to(root)):sha(p.read_bytes()) for p in paths}
if args.preflight:
    import sys
    (out/'inputs').mkdir(exist_ok=True)
    for name, value in inputs.items(): (out/'inputs'/name).write_text(value)
    (out/'preflight.json').write_text(json.dumps({'sourceHashes': before, 'inputHashes': hashes, 'runtime': 'pending', 'sharedGolden': golden_evidence}, indent=2)+'\n')
    print('PREFLIGHT '+str(out/'preflight.json'))
    raise SystemExit(0)
p = subprocess.run(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],input=payload,capture_output=True,timeout=240,env=dict(os.environ, CODEX_THREAD_ID='01a13ace-e372-7ed1-9946-149df37ee1c3'))
log = (p.stdout + p.stderr).decode(errors='replace')
(out/'run.log').write_text(log)
records = [json.loads(line[12:]) for line in log.splitlines() if line.startswith('RESULT_JSON ')]
receipt = {'suite':args.suite,'sharedGolden':golden_evidence,'scope':'actual client methods and SessionLink or full host selection/admission/pipeline; controlled OS/audio/wire endpoints; Mini RAM independent test, not SDK/native/sourceguard transfer acceptance','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceHashes':before,'sourceUnchanged':all(sha(p.read_bytes()) == before[str(p.relative_to(root))] for p in paths),'transportHashMatched':'INPUT_SHA256 '+sha(payload) in log,'inputHashes':hashes,'remote':records[-1] if records else None,'exit':p.returncode}
(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(log)
print('RECEIPT '+str(out/'result.json'))
remote = receipt['remote'] or {}
verified = receipt['sourceUnchanged'] and receipt['transportHashMatched'] and all(remote.get(key) for key in ['inputHashesMatched','memoryInputUnchanged','childrenReaped','sourceRemoved'])
raise SystemExit(p.returncode or (0 if verified and remote.get('exitCode') == 0 else 2))
