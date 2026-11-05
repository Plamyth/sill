"""Pure policy and unmodified extracted client methods, with deterministic I/O stand-ins."""
from pathlib import Path
import ast, os, subprocess, tempfile, plistlib
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
parsed = ast.parse((ROOT/'iOSClient/Tests/remote-default/run.py').read_text())
ns = {}
exec(compile(ast.Module(body=[n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name == 'block'], type_ignores=[]), 'extractor', 'exec'), ns)
source = (ROOT/'iOSClient/StreamClient.swift').read_text()
markers = ['func ownerWiredBinding(', 'func ownerWiredValid(', 'func cancelOwnerWiredResolution(', 'private func ownerWiredKey(', 'func beginOwnerWired(', 'private func dialOwnerWiredOrTailnet(', 'func ownerWiredChanged()', 'private func moveProbed(', 'private func homeListProbed(', 'private func moveSaidGoodbye(']
methods = '\n'.join(ns['block'](source, m) for m in markers).replace('#if os(iOS)', '#if true').replace('private func ', 'func ')
# Execute the real startMove state handler, including its TLS-ready branch. Parameters and
# DNS/TLS I/O are test doubles; production callback and catalog admission branches are unchanged.
move = ns['block'](source, 'private func startMove(')
handler = ns['block'](move, 'c.stateUpdateHandler =')
methods += '\nfunc installActualMoveHandler(_ c: NWConnection) {\n let kind = MoveKind.fromRemote; let homeViewport: Data? = nil; var wasReady = false; let fallback: NWEndpoint? = nil; let givesUp = false\n' + handler + '\n}'
remote = (ROOT/'iOSClient/StreamClient+Remote.swift').read_text()
methods += '\n' + '\n'.join(ns['block'](remote, m) for m in ['func sessionEnded(', 'private func endWithNotice(']).replace('#if os(iOS)', '#if true').replace('private func ', 'func ')
failure_callback = ns['block'](ns['block'](remote, 'func dialSaved('), 'connector.onFailed =')
methods += '\nfunc installActualFailureCallback(_ connector: RemoteConnector, ownerWired: OwnerWiredTarget?) { let macID = "owner"; let why = DialReason.automatic; remoteDial = connector\n' + failure_callback + '\n}'
policy = (ROOT/'iOSClient/RemoteDialPolicy.swift').read_text()
dial_policy = 'enum RemoteDialPolicy { static func ownerTailnetScope(_ saved: SavedMac?) -> Bool { saved?.method == "owner" }\n'
dial_policy += '\n'.join(ns['block'](policy, m) for m in ['enum End:', 'enum RetryDisposition', 'enum Failure:', 'static func retryDisposition('])
dial_policy += '\nstatic let dnsNoSuchName: Int32 = -65538, dnsNoSuchRecord: Int32 = -65554\nstruct Candidate {}\nstatic func classify(_ end: End, candidate: Candidate, usedTunnel: Bool?) -> Failure? { .notSill }\n}'
fixture = (HERE/'Standins.swift').read_text().replace('/* ACTUAL_METHODS */', methods)
fixture = fixture.replace('/* ACTUAL_DIAL_POLICY */', dial_policy)
fixture = fixture.replace('/* ACTUAL_GOODBYE */', ns['block']((ROOT/'Sources/StreamProtocol/Remote.swift').read_text(), 'public struct Goodbye:'))
fixture = fixture.replace('/* ACTUAL_GOODBYE_POLICY */', (ROOT/'iOSClient/GoodbyePolicy.swift').read_text().replace('import StreamProtocol', ''))
fixture = fixture.replace('/* ACTUAL_VERSION */', ns['block']((ROOT/'Sources/StreamProtocol/Compatibility.swift').read_text(), 'public struct SillVersion:'))
fixture = fixture.replace('/* ACTUAL_ERROR_END */', ns['block']((ROOT/'iOSClient/RemoteConnector.swift').read_text(), 'static func end(of'))
fixture += '\n' + (HERE/'scenarios.swift').read_text()
project = plistlib.loads((ROOT/'SillVision.xcodeproj/project.pbxproj').read_bytes())['objects']
vision_sources = {project[project[item]['fileRef']]['path'] for value in project.values() if value['isa'] == 'PBXSourcesBuildPhase' for item in value['files']}
required = {'iOSClient/OwnerWiredPolicy.swift', 'iOSClient/OwnerWiredResolver.swift'}
project_ok = required <= vision_sources
print('Vision target owner source closure:', 'PASS' if project_ok else 'FAIL missing ' + repr(required - vision_sources), flush=True)
generator = ast.parse((ROOT/'Scripts/make-vision-project.py').read_text())
client_list = next(ast.literal_eval(node.value) for node in generator.body if isinstance(node, ast.Assign) and any(isinstance(t,ast.Name) and t.id=='CLIENT' for t in node.targets))
generator_ok = {'OwnerWiredPolicy','OwnerWiredResolver'} <= set(client_list)
print('Vision generator preserves source closure:', 'PASS' if generator_ok else 'FAIL', flush=True)
with tempfile.TemporaryDirectory(prefix='owner-wired-') as tmp:
    out = Path(tmp); (out/'main.swift').write_text(fixture)
    subprocess.run(['swiftc', '-module-cache-path', str(out/'cache'), str(ROOT/'iOSClient/DiscoveryPolicy.swift'), str(ROOT/'iOSClient/OwnerWiredPolicy.swift'), str(ROOT/'Sources/StreamProtocol/SafeText.swift'), str(out/'main.swift'), '-o', str(out/'checks')], check=True)
    subprocess.run([str(out/'checks')], check=True)

assert project_ok and generator_ok, 'Vision source registration or regeneration regression'
