import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--suite', choices=['client', 'host', 'reconnect', 'queue', 'publication'], required=True)
parser.add_argument('--preflight', action='store_true')
parser.add_argument('--output', required=True)
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(args.output)
SUITE = args.suite
LABEL = SUITE

def augment_review(inputs, block, root, here):
    if SUITE=='host':
        original=(root/'Sources/SillHost/StreamServer.swift').read_text()
        methods='\n'.join(block(original,s) for s in ['func resetForNewStream()', 'func prepareVideo(', 'func isVideoCommitted(', 'func commitVideo('])
        server='''final class WireConnection { enum State { case ready }; var state = State.ready }
final class VideoClient { var needsKeyframe=false; var awaitingFirstKeyframe=false; var catalogSent=true; let connection=WireConnection(); var latestCatalog: StreamMessage?; var catalogAdmission: SourcePublicationAdmission?; var microphoneCatalogGrant: Int? }
final class Server {
    let queue=DispatchQueue(label:"review.actual-server")
    var videoAdmission=VideoEpochAdmission.stopped
    var lastParameterSets: Int?
    var clients: [Int: VideoClient]=[:]
    var committed: [StreamSource]=[]
    var prepared=0
    func drain() { queue.sync {} }
    func send(_ data: Data, to client: VideoClient) {}
    func broadcast(_ message: StreamMessage, epoch: UUID) {}
'''+methods.replace('            videoAdmission = .preparing(epoch)','            prepared += 1\n            videoAdmission = .preparing(epoch)').replace('            videoAdmission = .committed(epoch)','            committed.append(epoch.source)\n            videoAdmission = .committed(epoch)')+'\n}\n'
        h=inputs['Host.swift']; start=h.index('@MainActor final class Server'); end=h.index('@MainActor final class Injector',start)
        inputs['Host.swift']=h[:start]+server+h[end:]
        m=inputs['main.swift']
        m=m.replace('func settle() async { for _ in 0..<100 { await Task.yield() } }', 'func settle() async { for _ in 0..<100 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(25)) }')
        extra='''
        let commitRace=AdmissionHost(); commitRace.join(peer)
        commitRace.server.queue.suspend()
        commitRace.receive(.init(source:.window(71),origin:.automatic,selectionRevision:commitRace.selectionRevision),peer:peer)
        await settle()
        expect(commitRace.active == .window(71), "precondition old automatic completed capture before async server commit")
        commitRace.receive(.init(source:.window(72),origin:.human),peer:peer)
        let humanRevision=commitRace.selectionRevision
        commitRace.server.queue.resume()
        commitRace.server.queue.sync {}
        print("COUNTEREXAMPLE commit-after-human revision=\\(humanRevision) committed=\\(commitRace.server.committed)")
        expect(!commitRace.server.committed.contains(.window(71)),"network-queue commit must recheck immutable admission after newer human admission")
        await settle()
'''
        inputs['main.swift']=m.replace('        print("SOURCE_REQUEST_HOST_CHECKS',extra+'        print("SOURCE_REQUEST_HOST_CHECKS',1)
    elif SUITE=='client':
        inputs['SessionLink.swift'] = (root/'iOSClient/SessionLink.swift').read_text().replace('import Network\n','')
        m=inputs['main.swift'].replace('NSObject()','NWConnection()')
        extra='''
        let held=Client(); held.active = .none
        let hp=held.connection!
        _=held.link.hold(hp)
        let ht=held.automaticTicket(peer:hp,list:list)!
        held.requestAutomatic(.window(1001),ticket:ht)
        held.select(.none)
        expect(hp.packets.isEmpty,"precondition automatic packet remains in actual SessionLink hold")
        _=held.link.unhold(hp)
        let sentHeld=hp.packets.compactMap { Wire.decode(SourceRequest.self,from:Data($0.dropFirst(StreamMessage.headerLength))) }
        print("COUNTEREXAMPLE held-after-None origins=\\(sentHeld.map { String(describing:$0.origin) }) sources=\\(sentHeld.map(\\.source))")
        expect(!sentHeld.contains { $0.origin == .automatic },"explicit intent must invalidate automatic packet still held by actual SessionLink")
        print("COUNTEREXAMPLE delayed-stale-audio currentRevision=\\(String(describing:closing.selectionRevision)) sentRevision=\\(String(describing:automatic.first?.selectionRevision)) teardownCalls=\\(closing.remoteAudioControl.changes)")
        expect(closing.remoteAudioControl.changes == 0,"real delayed callback must not revoke audio for a revision already known stale")
        for choice in ["window", "display", "launch"] {
            let client = Client(); client.active = .none
            let peer = client.connection!
            _ = client.link.hold(peer)
            client.requestAutomatic(.desktop, ticket: client.automaticTicket(peer: peer, list: list)!)
            switch choice {
            case "window": client.select(.window(1002))
            case "display": client.selectDisplay(client.displays[0])
            default: client.launch(bundleID: "test.new")
            }
            _ = client.link.unhold(peer)
            let requests = peer.packets.compactMap { Wire.decode(SourceRequest.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
            expect(!requests.contains { $0.origin == .automatic }, "every explicit entry point cancels held automatic submission")
            expect(peer.packets.count == 1, "held explicit choice is preserved exactly once")
        }

'''
        inputs['main.swift']=m.replace('        print("SOURCE_REQUEST_CLIENT_CHECKS',extra+'        print("SOURCE_REQUEST_CLIENT_CHECKS',1)

def augment(inputs, block, root, here):
    global SUITE
    mode = SUITE
    SUITE = 'client' if mode == 'reconnect' else 'host' if mode == 'queue' else mode
    if mode == 'reconnect':
        inputs['Client.swift'] = client_input(block, root, here)
    augment_review(inputs, block, root, here)
    SUITE = mode
    if mode == 'reconnect':
        h=inputs['Client.swift']
        product=(root/'iOSClient/StreamClient.swift').read_text()
        start=product.index('            let released = link.adopt(c)')
        end=product.index('            #if DEBUG',start)
        move=product[start:end]
        move='    func moveWithoutFence(to c: NWConnection) {\n        let old=connection!\n'+move+'    }\n    func closeSoon(_ peers: [NWConnection]) {}\n'
        at=h.rfind('\n}')
        inputs['Client.swift']=h[:at]+'\n'+move+h[at:]
        at=inputs['Host.swift'].rfind('\n}')
        inputs['Host.swift']=inputs['Host.swift'][:at]+'''\n    func lastPeerDeparted() { catalog.clientCount=0; cancelSourcePicks() }\n'''+inputs['Host.swift'][at:]
        inputs['main.swift']='''import Foundation
    @main struct Composition {
     @MainActor static func main() async throws {
      var checks=0; var failed=0
      func expect(_ good: Bool,_ label: String) { checks += 1; if !good { failed += 1; print("FAIL " + label) } }
      func settle() async { for _ in 0..<100 { await Task.yield() } }
      let client=Client(); client.selectionRevision="host:0"; client.sessionHost="host"; client.active = .window(1001)
      let old=client.connection!; let new=NWConnection()
      let host=AdmissionHost(); host.active = .window(1001); host.join(old)
      host.inputFence.leave(ObjectIdentifier(old)); host.connections.removeValue(forKey:ObjectIdentifier(old))
      host.lastPeerDeparted()
      await host.select(.none)
      expect(host.selectionRevision != client.selectionRevision,"precondition real host cancel increments dedicated CAS at last departure")
      host.catalog.clientCount=1; host.join(new)
      client.moveWithoutFence(to:new)
      var list=WindowList(macName:"fixture",windows:[WindowInfo(id:1001,title:"old",appName:"fixture",bundleID:"test",width:640,height:480)],active:.none,launchID:"host",selectionRevision:host.selectionRevision)
      client.deliverIdleCatalog(list)
      let requests=new.packets.compactMap { Wire.decode(SourceRequest.self,from:Data($0.dropFirst(StreamMessage.headerLength))) }
      expect(requests.count == 1 && requests[0].source == .window(1001),"precondition actual unfenced handover emits remembered window")
      for request in requests { host.receive(request,peer:new) }
      await settle()
      print("COUNTEREXAMPLE reconnect hostRevision=\\(host.selectionRevision) ticketRevision=\\(String(describing:requests.first?.selectionRevision)) active=\\(host.active) committed=\\(host.server.committed)")
      expect(host.server.committed == [.window(1001)],"genuine unfenced reconnect must restore remembered window across host zero-client cancellation")
      let delayed = Client(); delayed.active = .window(1001)
      let replacement = NWConnection(); delayed.moveWithoutFence(to: replacement)
      var first = list; first.active = .window(1001)
      delayed.deliverIdleCatalog(first)
      expect(delayed.resumeSource == .window(1001) && replacement.packets.isEmpty,
             "first nonidle catalog retains current lifecycle opportunity without submission")
      first.active = .none; delayed.deliverIdleCatalog(first)
      let delayedRequests = replacement.packets.compactMap { Wire.decode(SourceRequest.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
      expect(delayedRequests.count == 1 && delayedRequests[0].source == .window(1001),
             "later idle catalog at same lifecycle revision restores remembered window exactly once")
      let superseded = Client(); superseded.active = .window(1001)
      let changedPeer = NWConnection(); superseded.moveWithoutFence(to: changedPeer)
      first.active = .window(1001); superseded.deliverIdleCatalog(first)
      first.active = .none; first.selectionRevision = "new-human-intent"
      superseded.deliverIdleCatalog(first)
      expect(changedPeer.packets.isEmpty && superseded.resumeOpportunity == nil,
             "nonidle opportunity cannot rebase after newer host intent")
      let before=new.packets.count
      list.selectionRevision=host.selectionRevision
      client.deliverIdleCatalog(list)
      expect(new.packets.count == before,"rejected resume consumes eligibility and no later catalog retries")
      for choice in ["none", "failed"] {
       let interrupted = Client(); interrupted.active = .window(1001)
       let replacement = NWConnection()
       interrupted.moveWithoutFence(to: replacement)
       interrupted.select(choice == "none" ? .none : .window(999))
       interrupted.deliverIdleCatalog(list)
       let requests = replacement.packets.compactMap { Wire.decode(SourceRequest.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
       expect(!requests.contains { $0.origin == .automatic }, "new-peer opportunity cannot survive intervening explicit intent")
      }
      print("RECONNECT_COMPOSITION_CHECKS total=\\(checks) failed=\\(failed)")
      if failed>0 { exit(1) }
     }
    }
    '''
    elif mode == 'queue':
        h = inputs['Host.swift']
        at = h.rfind('\n}')
        inputs['Host.swift'] = h[:at] + '\n func reserveForReview(peer:ObjectIdentifier)->UInt64 { reserveSourceIntent(peer:peer) }\n' + h[at:]
        inputs['main.swift']='''import Foundation
       @main struct Check {
        @MainActor static func main() async {
         let host=AdmissionHost(); let peer=NSObject(); host.join(peer)
         let seq=host.reserveForReview(peer:ObjectIdentifier(peer))
         let ingress=CoordinatorIngress(); let read=DispatchSemaphore(value:0)
         let human: @MainActor ()->Void = { host.receive(.init(source:.window(72),origin:.human),peer:peer) }
         host.server.queue.async {
          ingress.submit(human)
          host.server.queue.suspend()
          read.signal()
         }
         read.wait()
         await host.select(.window(71),bringForward:true,intentSequence:seq,pickOrigin:.automatic,admissionPeer:ObjectIdentifier(peer))
         let preparedBeforeHuman=host.active == .window(71)
         for _ in 0..<100 { await Task.yield() }
         let newer=host.pickSequence > seq
         host.server.queue.resume()
         host.server.queue.sync {}
         print("QUEUE_INGRESS preparedBeforeHuman=\\(preparedBeforeHuman) newerAdmission=\\(newer) commits=\\(host.server.committed)")
         if !preparedBeforeHuman || !newer { print("FIXTURE_PRECONDITION_FAILED"); exit(2) }
         if host.server.committed.contains(.window(71)) { print("FAIL already-read human ingress admits before obsolete queued video publication"); print("QUEUE_INGRESS_CHECKS total=3 failed=1"); exit(1) }
         var failures = 0
         for rejection in ["missing-launch", "stale-display"] {
          let rejected = AdmissionHost(); rejected.join(peer)
          let sequence = rejected.reserveForReview(peer:ObjectIdentifier(peer))
          let events = CoordinatorIngress(); let held = DispatchSemaphore(value:0)
          let reject: @MainActor () -> Void = {
           if rejection == "missing-launch" { rejected.launch("missing", peer:peer) }
           else {
            _ = rejected.admitSourceMessage(.init(kind:.selectDisplay,timestamp:0,isKeyframe:false,
             payload:Wire.encode(DisplaySelection(displayID:13,inventoryID:UUID()))),from:peer)
           }
          }
          rejected.server.queue.async { events.submit(reject); rejected.server.queue.suspend(); held.signal() }
          held.wait()
          await rejected.select(.window(71),bringForward:true,intentSequence:sequence,pickOrigin:.automatic,
                                admissionPeer:ObjectIdentifier(peer))
          let prepared = rejected.active == .window(71)
          for _ in 0..<200 { await Task.yield() }
          let superseded = rejected.pickSequence > sequence
          rejected.server.queue.resume(); rejected.server.queue.sync {}
          for _ in 0..<200 { await Task.yield() }
          rejected.server.queue.sync {}
          if !prepared || !superseded { print("FIXTURE_PRECONDITION_FAILED \\(rejection)"); exit(2) }
          if rejected.active != .none || rejected.videoEpoch != nil || rejected.capture.running || rejected.server.videoAdmission != .stopped {
           failures += 1
           print("FAIL \\(rejection) must drain the unpublished predecessor and publish completed None")
          }
         }
         let late = AdmissionHost(); late.join(peer)
         late.receive(.init(source:.window(81),origin:.human),peer:peer)
         for _ in 0..<200 { await Task.yield() }
         late.server.drain()
         let priorEpoch = late.videoEpoch?.id
         if priorEpoch == nil || late.server.videoAdmission.current?.id != priorEpoch {
          print("FIXTURE_PRECONDITION_FAILED committed predecessor before held readback"); exit(2)
         }
         late.server.queue.suspend()
         late.launch("missing",peer:peer)
         for _ in 0..<200 { await Task.yield() }
         late.receive(.init(source:.window(82),origin:.human),peer:peer)
         for _ in 0..<200 { await Task.yield() }
         late.server.queue.resume(); late.server.drain()
         for _ in 0..<200 { await Task.yield() }
         late.server.drain()
         if late.active != .window(82) || late.videoEpoch?.id != late.server.videoAdmission.current?.id {
          failures += 1; print("FAIL late committed-epoch readback cannot replace a newer human selection")
         }
         print("QUEUE_INGRESS_CHECKS total=12 failed=\\(failures)")
         if failures > 0 { exit(1) }
        }
       }
       '''
    elif mode == 'publication':
        product = (root/'Sources/SillHost/StreamServer.swift').read_text()
        names = ['func resetForNewStream()', 'func prepareVideo(', 'func commitVideo(', 'func sendCatalog(',
                 'private func replayCatalog(', 'private func send(_ raw:']
        methods = '\n'.join(block(product, name).replace('private ', '') for name in names)
        fixture = (here/'Publication.swift').read_text().replace('// PUBLICATION_METHODS', methods)
        query = (here/'CatalogQuery.swift').read_text().replace('// QUERY_METHOD',
            block((root/'Sources/SillHost/StreamCoordinator.swift').read_text(), 'private func refreshCatalog(').replace('private ', ''))
        fixture = fixture.replace('// QUERY_FIXTURE', query)
        keep = ['Switcher.swift', 'AudioPrivacy.swift', 'AudioForwarding.swift', 'StreamMessage.swift', 'AudioRouting.swift', 'SourcePublicationAdmission.swift']
        selected = {name: inputs[name] for name in keep}
        inputs.clear(); inputs.update(selected)
        inputs['main.swift'] = fixture
    snapshot = OUT / 'inputs'
    snapshot.mkdir()
    for name, value in inputs.items():
        (snapshot / name).write_text(value)


def client_input(block, root, here):
    text = (root/'iOSClient/StreamClient.swift').read_text()
    signatures = ['func select(_ source:', 'func selectDisplay(', 'private func requestDisplay(', 'private func request(', 'func launch(bundleID:', 'private func noteSourceIntent(', 'private func automaticTicket(', 'private func requestAutomatic(', 'private func observeSourceIntent(', 'private func beginAutomaticConnectionOpportunity(', 'private func authenticatedDisplayMacID(', 'private func observeDisplaySelection(', 'private func requestInitialDisplay(', 'private func requestAutomaticDisplay(']
    methods = '\n'.join(block(text, s) for s in signatures)
    client = (here/'Client.swift').read_text().replace('// CLIENT_METHODS', methods.replace('private ', '').replace('UserDefaults.standard', 'defaults'))
    client = client.replace('// DISPLAY_TYPES', '\n'.join(block(text, s).replace('private ', '') for s in ['private struct InitialDisplayOpportunity', 'private struct RememberedDisplay', 'private struct PendingDisplaySelection']))
    client = client.replace('// EXPECTED_SOURCE_STATE', next(line.strip().replace('private ', '') for line in text.splitlines() if 'private var expectedSourceIntent:' in line))
    for marker, signature in [('// EXPECTED_SOURCE', 'private enum ExpectedSourceIntent'), ('// AUTOMATIC_TICKET', 'private struct AutomaticSourceTicket'), ('// RESUME_SOURCE', 'if let resume = self.resumeSource'), ('// IDLE_FALLBACK', 'if let ticket = self.automaticTicket')]:
        replacement = block(text, signature).replace('private ', '')
        if marker == '// AUTOMATIC_TICKET':
            replacement += '\n' + block(text, 'private struct AutomaticConnectionOpportunity').replace('private ', '')
        client = client.replace(marker, replacement)
    return client

program = ROOT/'Tests/checks/source-request/run.py'
code = program.read_text().replace('sha = lambda data:', 'augment(inputs, block, root, here)\nsha = lambda data:', 1)
code = code.replace('paths = [source,', "paths = [root/'iOSClient/SessionLink.swift', root/'Sources/SillHost/StreamServer.swift', root/'Tests/checks/source-request/transport.py', source,", 1)
code = code.replace("runner = runner.replace(\"not name.endswith('.swift')\"", "runner = runner.replace('stdout=subprocess.DEVNULL, timeout=20', 'stdout=subprocess.DEVNULL, timeout=60')\nrunner = runner.replace(\"not name.endswith('.swift')\"", 1)
sys_suite = 'client' if SUITE == 'client' else 'host'
import sys
sys.argv = [str(program), '--suite', sys_suite, '--output', str(OUT)] + (['--preflight'] if args.preflight else [])
exec(compile(code, str(program), 'exec'), {'__file__': str(program), 'augment': augment})
