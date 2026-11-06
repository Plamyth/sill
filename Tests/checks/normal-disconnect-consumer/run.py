import hashlib,json,os,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]; here=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=False)
paths=[root/'Sources/SillHost'/f'{n}.swift' for n in ['HostAudioForwardingRuntime','SentryAdmission','AudioForwardingContract','AudioForwardingCoordinator','AudioForwardingParticipants','AudioForwardingProtection','LocalAudioParticipants','HostAudioPrivacyModel']]
inputs=paths+[root/'Sources/SillHost/LocalAudioReturn.swift',root/'Sources/SillHost/StreamCoordinator.swift',root/'Sources/SillHost/LocalAudioRelay.swift']+list((root/'Sources/StreamProtocol').glob('*.swift'))+list(here.glob('*'))
before={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
def block(text,marker):
 s=text.index(marker);e=text.index('{',s)+1;depth=1
 while depth:
  depth+=(text[e]=='{')-(text[e]=='}');e+=1
 return text[s:e]
local=(root/'Sources/SillHost/LocalAudioReturn.swift').read_text().split('@MainActor\nfinal class LocalAudioAuthentication')[0].replace('import LocalAuthentication\n','').replace('import LocalAuthenticationEmbeddedUI\n','')
(out/'Local.swift').write_text(local + '\n' + block((root/'Sources/SillHost/LocalAudioRelay.swift').read_text(), 'enum AudioForwardingEvidenceOperation:'))
runtime=paths[0].read_text();candidate='normalDisconnectReturn' in runtime
(out/'Runtime.swift').write_text(runtime+'''\nextension HostAudioForwardingRuntime {
 func fixtureInstall(_ context: AudioForwardingConnectionContext, value: AudioForwardingSnapshot) {
  sessions[context.connectionID] = Session(context: context, credential: try! .init(pairedDeviceId: context.peer.id, pairingGeneration: context.peer.pairingGeneration, credential: String(repeating: "a", count: 43)))
  snapshot = value
  preparingBinding = value.binding
 }
 func fixtureAdditional(_ context: AudioForwardingConnectionContext) {
  sessions[context.connectionID] = Session(context: context, credential: try! .init(pairedDeviceId: context.peer.id, pairingGeneration: context.peer.pairingGeneration, credential: String(repeating: "a", count: 43)))
 }
 func fixtureEnrolling(_ context: AudioForwardingConnectionContext) async { _ = await enroll(context) }
}\n''')
coordinator=(root/'Sources/SillHost/StreamCoordinator.swift').read_text()
wiring=block(coordinator,'private func configureNormalDisconnectReturn(').replace('private func','func') if candidate else 'func configureNormalDisconnectReturn(_ runtime: HostAudioForwardingRuntime) {}'
revocation=block(coordinator,'privacy.revokeForLocalReturn = {')
(out/'Wiring.swift').write_text('''import Foundation
import StreamProtocol
@MainActor final class Consumer {
 final class Server { let sentryAdmission = SentryAdmission() }
 let server = Server()
 var shuttingDown = false
 let audioPrivacy: HostAudioPrivacy?
 let forwardingRuntime: HostAudioForwardingRuntime?
 var manualDrains = 0
 var normalDrainHook: (() async -> Void)?
 var normalDrains = 0
 init(_ privacy: HostAudioPrivacy, _ runtime: HostAudioForwardingRuntime) {
  audioPrivacy = privacy;forwardingRuntime = runtime
  '''+revocation+'''
  configureNormalDisconnectReturn(runtime)
 }
 func prepareLocalAudioReturn() async -> Bool { manualDrains += 1; return true }
 func prepareNormalDisconnectAudioReturn() async -> Bool {
  normalDrains += 1
  if let normalDrainHook { await normalDrainHook() }
  #if NORMAL_CONSUMER
  return await forwardingRuntime?.quiesceForNormalDisconnect() == true
  #else
  return false
  #endif
 }
 '''+wiring+'\n}\n')
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
base=['xcrun','swiftc','-swift-version','5','-package-name','Sill','-sdk',sdk,'-module-cache-path',str(out/'cache')]
if candidate:base+=['-D','NORMAL_CONSUMER']
commands=[('protocol',base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name','StreamProtocol',*map(str,sorted((root/'Sources/StreamProtocol').glob('*.swift'))),'-emit-module-path',str(out/'StreamProtocol.swiftmodule'),'-o',str(out/'protocol.o')]),
 ('parse', ['xcrun','swiftc','-frontend','-parse','-sdk',sdk,*map(str,[paths[0],paths[1],root/'Sources/SillHost/StreamCoordinator.swift',root/'Sources/SillHost/LocalAudioRelay.swift'])]),
 ('compile',base+['-parse-as-library','-I',str(out),*map(str,paths[1:]),str(out/'Runtime.swift'),str(out/'Local.swift'),str(out/'Wiring.swift'),str(here/'Seams.swift'),str(here/'Main.swift'),str(out/'protocol.o'),'-o',str(out/'checks')]),('checks',[str(out/'checks')])]
record={'sourceSHA256':before,'SDK':sdk,'candidate':candidate,'commands':[],'actualHALHostCoreDeviceUIKeychainActions':0}
for name,cmd in commands:
 r=subprocess.run(cmd,text=True,capture_output=True,timeout=240,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
 (out/(name+'.log')).write_text(r.stdout+r.stderr);print(r.stdout+r.stderr,end='',flush=True)
 record['commands'].append({'name':name,'exitCode':r.returncode})
 if r.returncode:break
record['sourceUnchanged']=all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in before.items())
record['exitCode']=r.returncode if record['sourceUnchanged'] else 2
(out/'result.json').write_text(json.dumps(record,indent=2));print('CONSUMER_RESULT '+json.dumps(record),flush=True)
sys.exit(record['exitCode'])
