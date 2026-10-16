from pathlib import Path
import subprocess
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'iOSClient/IPadRemoteAudioController.swift').read_text()
fixture = (out / 'ClientFixture.swift').read_text()
player = (out / 'PlaybackFixture.swift').read_text()
mutants = [
    ('missing UUID fence', source.replace('guard answer.requestID == requestID else { return }', ''), fixture),
    ('pre ACK playback', source.replace('guard peer == origin, case .listening = status else { return }', 'guard peer == origin else { return }'), fixture),
    ('old peer playback', source.replace('guard peer == origin, case .listening = status else { return }', 'guard case .listening = status else { return }'), fixture),
    ('OFF uses fixed ID', source.replace('send(peer, RemoteAudioSubscription(enabled: false))', 'send(peer, RemoteAudioSubscription(enabled: false, requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))'), fixture),
    ('source changes retain consent', source.replace('if source != list.active || list.remoteAudio != 1', 'if list.remoteAudio != 1'), fixture),
    ('timeout does not revoke', source.replace('revoke()\n        status = .failed("Mac audio did not respond.")', 'status = .failed("Mac audio did not respond.")'), fixture),
    ('connection setter retains consent', source, fixture.replace('remoteAudioControl.setConnection(newValue.map(ObjectIdentifier.init))', '')),
    ('adapter drops ACK', source, fixture.replace('self.remoteAudioControl.receive(state, from: peer)', '_ = state')),
    ('adapter drops packets', source, fixture.replace('self.remoteAudioControl.receiveAudio(data, from: peer)', '_ = data')),
    ('background controller keeps consent', source.replace('func backgrounded() { revoke() }', 'func backgrounded() {}'), fixture),
    ('scene handler omits background revoke', source, fixture.replace('client.remoteAudioControl.backgrounded()', '')),
]
mutants = [(name, candidate, adapter, player) for name, candidate, adapter in mutants] + [
    ('stale decoded buffer survives OFF', source, fixture, player.replace('guard current == epoch else { return }', '')),
    ('OFF leaves engine running', source, fixture, player.replace('engine?.stop()', '')),
]
for index, (name, candidate, adapter, playback) in enumerate(mutants):
    mutant = out / f'mutant-{index}.swift'
    mutant.write_text(candidate)
    adapter_file = out / f'adapter-{index}.swift'
    adapter_file.write_text(adapter)
    playback_file = out / f'playback-{index}.swift'
    playback_file.write_text(playback)
    executable = out / f'mutant-{index}'
    command = ['xcrun', 'swiftc', '-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
               '-Xlinker', '-rpath', '-Xlinker', str(out), str(mutant), str(adapter_file),
               str(playback_file), str(root / 'Tests/checks/iPad-remote-audio/main.swift'), '-o', str(executable)]
    built = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if built.returncode:
        raise SystemExit(f'Invalid mutant {name}: {built.stdout}')
    result = subprocess.run([str(executable)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode == 0:
        raise SystemExit(f'SURVIVED {name}')
    if 'Fatal error: FAIL ' not in result.stdout:
        raise SystemExit(f'Non-assertion failure for {name}: {result.stdout[-2000:]}')
    print(f'CAUGHT {name}', flush=True)
print(f'{len(mutants)} of {len(mutants)} mutants caught')
