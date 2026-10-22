#!/usr/bin/env python3
"""생산 source handlers/select/startPipeline 및 publication을 inert I/O로 실행한다."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent

def block(s, marker):
    a=s.index(marker); b=s.index('{',a)+1; depth=1
    while depth:
        depth+=(s[b]=='{')-(s[b]=='}'); b+=1
    return s[a:b]

def generate(coordinator_file=None):
    host=(ROOT/'Sources/SillHost/StreamCoordinator.swift').read_text()
    if coordinator_file: host=Path(coordinator_file).read_text()
    server=(ROOT/'Sources/SillHost/StreamServer.swift').read_text()
    signatures=['private func sourcePeerIsLive(', 'private func automaticSelectionIsAllowed(',
        'private func replaceSourcePublication(', 'private func retainAutomaticDisplay(', 'private func recoverAutomaticDisplayIfNeeded(', 'private func reserveSourceIntent(', 'private func admissionIsCurrent(', 'private func rejectSourceIntent(',
        'private func cancelSourcePicks(', 'private func sourcePeerDeparted(', 'private func handleSourceSelection(',
        'private func handlePick(', 'private func displaysChanged(', 'private func listMessage(', 'func select(_ source:', 'private func selectStream(', 'private func startPipeline(']
    signatures=[marker for marker in signatures if marker in host]
    types='\n'.join(block(host,s).replace('private ','') for s in [marker for marker in ['struct SourcePick {','private struct PendingLaunch','private struct AutomaticDisplayRecovery','private enum PipelineEpochError'] if marker in host])
    if 'private struct AutomaticDisplayRecovery' not in host:
        types+='\nstruct AutomaticDisplayRecovery { var pending = false }'
    methods='\n'.join(block(host,s).replace('private ','') for s in signatures)
    receive=host[host.index('        case .selectDisplay:\n'):host.index('        case .windowCommand:\n')]
    launch=host[host.index('        case .launchApp:\n'):host.index('        case .input:\n')]
    methods+='\nfunc receiveMessage(_ message: StreamMessage, from connection: NWConnection) async {\nswitch message.kind {\n'+receive+launch+'default: break\n}\n}'
    completion=host[host.index('        if let pending = pendingLaunch, let w = infos.first'):host.index('        if case .window(let id) = active {',host.index('    private func windowsChanged('))]
    fixture=(HERE/'Host.swift').read_text().replace('// HOST_TYPES',types).replace('// HOST_METHODS',methods).replace('// LAUNCH_COMPLETION',completion)
    inputs={p.name:p.read_text() for p in (ROOT/'Sources/StreamProtocol').glob('*.swift') if p.name != 'RemoteTLS.swift'}
    inputs['Host.swift']=fixture
    for name in ['DisplayInventory','SourceInputFence']:
        inputs[name+'.swift']=(ROOT/('Sources/SillHost/'+name+'.swift')).read_text().replace('import StreamProtocol','')
    inputs['SourcePublicationAdmission.swift']='import Foundation\n'+block(server,'final class SourcePublicationAdmission')
    inputs['main.swift']=(HERE/'main.swift').read_text()
    return inputs,host,server

def main():
    p=argparse.ArgumentParser();p.add_argument('--baseline',action='store_true');p.add_argument('--emit-only',action='store_true');p.add_argument('--coordinator-file');p.add_argument('--suite', choices=['host','protocol','publication','topology'], default='host');args=p.parse_args()
    if args.baseline:
        inputs={'Switcher.swift':(HERE/'Baseline.swifttext').read_text(),
            'main.swift':'''import Foundation
@main struct Baseline { static func main() {
let id = UUID()
let invalid = "{\\"displayID\\":13,\\"inventoryID\\":\\"\\(id.uuidString)\\",\\"selectionOrigin\\":\\"automatic\\"}"
let accepted = Wire.decode(DisplaySelection.self, from: Data(invalid.utf8)) != nil
print("baseline invalid automatic without revision accepted=\\(accepted)")
assert(accepted)
} }
'''}
        # Baseline Switcher refers to StreamMessage's byte helpers.
        inputs.update({p.name:p.read_text() for p in (ROOT/'Sources/StreamProtocol').glob('*.swift') if p.name != 'Switcher.swift'})
    else:
        inputs,_,_=generate(args.coordinator_file)
        if args.suite == 'protocol':
            main=inputs['main.swift'].split('        for kind211 in [false, true]')[0]
            main=main[:main.index('        func idle(')]+main[main.index('        let uuid = UUID()'):]
            main+='        print("protocol checks passed=\\(checks)")\n    }\n}\n'
            inputs={name:text for name,text in inputs.items() if name not in ['Host.swift','DisplayInventory.swift','SourceInputFence.swift','SourcePublicationAdmission.swift']}
            inputs['main.swift']=main
    if args.suite == 'publication' and not args.baseline:
        server=(ROOT/'Sources/SillHost/StreamServer.swift').read_text()
        methods='\n'.join(block(server,mark).replace('private ','') for mark in [
            'func prepareVideo(', 'func commitVideo(', 'func sendCatalog(', 'private func replayCatalog(', 'func sendMicrophoneCatalog(', 'private func send(_ raw:'])
        fixture=(HERE/'Publication.swift').read_text()
        if 'private enum VideoLane:' in server:
            lane_types='\n'.join(block(server,mark).replace('private ','') for mark in ['private enum VideoLane:', 'private final class PeerVideo {'])
            helpers='\n'.join(block(server,mark).replace('private ','') for mark in ['private func currentVideoAdmission(', 'private func catalogMatches(', 'private static func isVideo('])
            fixture=fixture.replace('final class Client {',lane_types+'\nfinal class Client {\n    var videoLane = VideoLane.legacy\n    let peerVideo = PeerVideo()')
            methods += '\n'+helpers
        fixture=fixture.replace('// PUBLICATION_METHODS',methods)
        inputs={p.name:p.read_text() for p in (ROOT/'Sources/StreamProtocol').glob('*.swift') if p.name != 'RemoteTLS.swift'}
        inputs['Publication.swift']=fixture
        inputs['Admission.swift']='import Foundation\n'+block(server,'final class SourcePublicationAdmission')
    if args.suite == 'topology': inputs['main.swift']=(HERE/'Topology.swift').read_text()
    if args.emit_only:
        print(json.dumps({name:hashlib.sha256(value.encode()).hexdigest() for name,value in inputs.items()},sort_keys=True));return
    with tempfile.TemporaryDirectory(prefix='source-intent-') as scratch:
        scratch=Path(scratch)
        for name,text in inputs.items(): (scratch/name).write_text(text)
        subprocess.run(['xcrun','swiftc','-whole-module-optimization','-parse-as-library','-package-name','Sill','-module-cache-path',str(scratch/'module-cache'),*map(str,sorted(scratch.glob('*.swift'))),'-o',str(scratch/'checks')],check=True)
        subprocess.run([str(scratch/'checks'), *([str(HERE/'topology-trace.json')] if args.suite == 'topology' else [])],check=True)
    print('source-intent scratch removed='+str(not scratch.exists()).lower())
if __name__=='__main__':main()
