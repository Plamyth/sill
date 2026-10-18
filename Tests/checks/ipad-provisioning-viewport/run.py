#!/usr/bin/env python3
"""Pure source checks through volatile Mini input. Prints evidence without writing reports."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def sha(data):
    return hashlib.sha256(data).hexdigest()


paths = [p for folder in ['Sources/SillHost', 'Sources/StreamProtocol', 'iOSClient']
         for p in (ROOT / folder).glob('*.swift')]
paths += list(HERE.glob('*'))
paths += list((HERE.parent / 'extended-viewport-safety').glob('*'))
paths = [p for p in paths if p.is_file()]
before = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
source_ref = sys.argv[sys.argv.index('--client-ref') + 1] if '--client-ref' in sys.argv else None
host_ref = sys.argv[sys.argv.index('--host-ref') + 1] if '--host-ref' in sys.argv else None


def client_source(name):
    if source_ref and name == 'StreamClient.swift':
        return subprocess.check_output(['git', 'show', source_ref + ':iOSClient/' + name], cwd=ROOT, text=True)
    return (ROOT / 'iOSClient' / name).read_text()


screen = client_source('StreamScreen.swift')
stream = client_source('StreamClient.swift')
client_viewport = client_source('StreamClient+Viewport.swift')
coordinator = (subprocess.check_output(['git', 'show', host_ref + ':Sources/SillHost/StreamCoordinator.swift'], cwd=ROOT, text=True)
               if host_ref else (ROOT / 'Sources/SillHost/StreamCoordinator.swift').read_text())
switcher = (ROOT / 'Sources/StreamProtocol/Switcher.swift').read_text()
viewport = (ROOT / 'Sources/StreamProtocol/Viewport.swift').read_text()
video = (ROOT / 'iOSClient/HEVCDisplayView.swift').read_text()
overlay = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
main = '\n'.join((HERE / name).read_text() for name in ['main.swift', 'replacement.swift', 'staged-window.swift', 'wire.swift', 'quality-transition.swift'])
if '--quality-only' in sys.argv:
    main = main.replace('// QUALITY_ONLY', 'if CommandLine.arguments.count > 0 { await qualityTransitionChecks(); print("QUALITY_CHECKS \\(count)"); return }')
if '--staged-only' in sys.argv:
    main = main.replace('// STAGED_ONLY', 'if CommandLine.arguments.count > 0 { await stagedWindowChecks(); return }')
main = main.replace('// WIRE', block(switcher, 'public enum Wire {'))
old_viewport = subprocess.check_output(['git', 'show', '7ade74d:Sources/StreamProtocol/Viewport.swift'], cwd=ROOT, text=True)
old_desktop = subprocess.check_output(['git', 'show', '7ade74d:Sources/SillHost/ExtendedDesktop.swift'], cwd=ROOT, text=True)
main = main.replace('// OLD_VIEWPORT', block(old_viewport, 'public struct Viewport:').replace('Viewport', 'OldViewport'))
main = main.replace('// OLD_DIMENSIONS', block(old_desktop, 'struct Dimensions:').replace('Dimensions', 'OldDimensions').replace('Viewport', 'OldViewport'))
client_methods = ['func sendViewport(', 'func forgetViewport(', 'func setLocalCursor(']
main = main.replace('// CURSOR_DEBOUNCE', next(line.strip().replace('private ', '') for line in client_viewport.splitlines() if 'private static let localCursorDebounce' in line))
main = main.replace('// VIEWPORT_CLIENT', '\n'.join(block(client_viewport, signature) for signature in client_methods))
main = main.replace('// RESCUE', block(stream, 'private func rescue(').replace('private func', 'func', 1))
main = main.replace('// HOLD', block(stream, 'private func holdSends('))
finish = block(stream, 'private func finishMoveAfterInputDrain(')
main = main.replace('// HANDOVER', finish[finish.index('let reconnected ='):finish.index('// The Mac takes')])
snapshot_replay = 'if let v = kind' in finish
main = main.replace('// RESEND_PANEL', block(finish, 'if let v = kind' if snapshot_replay else 'if var v = lastViewport')
                    + ('\n' + block(finish, 'if kind == .fromRemote { homeMoveViewport') if snapshot_replay else ''))
move_home = block(stream, 'private func moveHome(to')
snapshot = ('homeMoveViewport = lastViewport.map ' + block(move_home, '{ v -> Viewport in')
            if 'homeMoveViewport = lastViewport.map' in move_home else '')
main = main.replace('// HOME_SNAPSHOT', snapshot)
start_move = block(stream, 'private func startMove(')
preflight = ''
if 'let homeViewport:' in start_move:
    preflight = 'let kind = MoveKind.fromRemote\n' + start_move[start_move.index('let homeViewport:'):start_move.index('var wasReady =')]
    preflight += block(start_move, 'if let homeViewport')
main = main.replace('// HOME_PREFLIGHT', preflight)
viewport_case = coordinator.split('case .viewport:', 1)[1].split('case .pairingWanted:', 1)[0]
main = main.replace('// HOST_VIEWPORT_CASE', viewport_case)
main = main.replace('// HOST_APPLY_VIEWPORT', block(coordinator, 'private func applyViewportToActiveWindow('))
main = main.replace('// HOST_WANTED_STAGE', block(coordinator, 'private func wantedStage('))
registration = block(coordinator, 'server.onClientConnected =')
main = main.replace('// QUALITY_REGISTRATION', registration)
main = main.replace('// QUALITY_METHODS', '\n'.join(block(coordinator, signature) for signature in
    ['private func routesChanged(', 'private func flipAwaits(', 'private func applyPending(',
     'private func restartNeeded(', 'private func adopt('])
    + '\n' + block(coordinator, 'private func applyViewportToActiveWindow(')
    + '\n' + block(coordinator, 'private func wantedStage('))
select = block(coordinator, 'func select(')
main = main.replace('// QUALITY_SELECT_EFFECTS', select[select.index('videoEpoch = nil'):select.index('// Input held for the old source')])
main = main.replace('// QUALITY_SELECT_COMMIT', select[select.index('var leftStage = false'):select.index('// The devices\' links: judged afresh')])
away = (ROOT / 'Sources/SillHost/AwayPolicy.swift').read_text()
main = main.replace('// QUALITY_AWAY_POLICY', block(away, 'enum AwayPolicy {'))
stage = (ROOT / 'Sources/SillHost/VirtualStage.swift').read_text()
main = main.replace('// STAGE_GEOMETRY', '\n'.join(block(stage, signature) for signature in
    ['func matches(', 'static func windowSize(', 'static func envelope(', 'static func clamp(']))
main = main.replace('// HOST_VIEWPORT', block(coordinator, 'private func updateExtendedDesktopViewport(')
                    .replace('private func', 'func', 1))
main = main.replace('// CLIENT_VIEWPORT', block(screen, 'private func sendViewport(')
                    .replace('private func', 'func', 1))
main = main.replace('// SIZING', block(screen, 'enum IPadViewportSizing {'))
main = main.replace('// VIDEO_RECT', 'enum HEVCDisplayView {\n' + block(video, 'static func videoRect(') + '\n}')
main = main.replace('// INPUT_MAPPING', 'struct InputFixture {\nlet bounds: CGRect\nlet videoSize: CGSize\n'
                    + block(overlay, 'private var videoRect:') + '\n'
                    + block(overlay, 'private func normalized(').replace('private func', 'func', 1) + '\n}')
inputs = {
    'main.swift': main,
    'Types.swift': 'import Foundation\n' + '\n'.join(block(switcher, signature) for signature in
        ['public enum StreamSource:', 'public struct DisplayInfo:', 'public struct DisplaySelection:'])
        + '\n' + block(viewport, 'public struct Viewport:'),
    'ExtendedDesktop.swift': (ROOT / 'Sources/SillHost/ExtendedDesktop.swift').read_text()
        .split('// MARK: macOS display adapter')[0].replace('import StreamProtocol\n', ''),
    'DisplayInventory.swift': (ROOT / 'Sources/SillHost/DisplayInventory.swift').read_text()
        .replace('import StreamProtocol\n', ''),
    'SessionLink.swift': (ROOT / 'iOSClient/SessionLink.swift').read_text().replace('import Network\n', ''),
    'HostConfig.swift': (ROOT / 'Sources/SillHost/HostConfig.swift').read_text().replace('package ', ''),
}
policy = (ROOT / 'iOSClient/DiscoveryPolicy.swift').read_text()
inputs['DiscoveryPolicy.swift'] = 'import Foundation\nenum DiscoveryPolicy {\n' + '\n'.join(
    block(policy, signature) for signature in ['enum Method:', 'struct PathInput:', 'enum Keep:', 'enum PathPlan:',
        'static func pathGone(', 'static func pathPlan(', 'static func upWait(']) + '\n' + '\n'.join(
    line for line in policy.splitlines() if any('static let ' + name + ' =' in line
    for name in ['cableSettle', 'pathHysteresis', 'pongSilence', 'upBackoffCap'])) + '\n}'
if not source_ref:
    for name, source in [('iOSClient/StreamClient.swift', stream), ('Sources/SillHost/StreamCoordinator.swift', coordinator)]:
        base = subprocess.check_output(['git', 'show', '7ade74d:' + name], cwd=ROOT, text=True)
        assert source == base, name + ' must retain the original lifecycle byte-for-byte'
    assert 'viewportForProvisioning' not in client_viewport + stream
    assert 'provisioningSize' not in client_viewport + stream + screen
    assert finish.index('guard connected, let old = connection') < finish.index('link.handOver(') < finish.index('sendViewport(v)')
    assert finish.index('link.adopt(c)') < finish.index('sendViewport(v)')
    assert start_move.index('sendHello(on: c)') < start_move.index('self.probeMove(')
    assert 'await revokeRemoteAudio(reason: "source changed")' in block(coordinator, 'func select(')
    assert 'homeSessionReady' in stream and 'remoteSessionReady' in stream
    home = (ROOT / 'iOSClient/StreamClient+Home.swift').read_text()
    assert 's.home?.tls == true' in block(home, 'func homeSessionReady(')
    assert 'homeInfoChecks(macInfo)' in block(stream, 'private func moveProbed(')
    assert 'guard connected,' in block(screen, 'private func sendViewport(').replace('client.connected', 'connected')
assert '.ignoresSafeArea(.keyboard, edges: .bottom)' in screen
assert '.onChange(of: geo.size, initial: true) { _, size in availableSize = size }' in screen
assert '.onChange(of: availableSize)' in screen
assert '.padding(IPadViewportSizing.panelPadding)' in screen
assert 'InputOverlay(videoSize: client.videoSize,' in screen
assert 'displayLayer.videoGravity = .resizeAspect' in video
assert 'lastViewport = nil' in block(client_viewport, 'func forgetViewport(')

if '--baseline' in sys.argv:
    baseline = HERE.parent / 'extended-viewport-safety/run.py'
    namespace = {'__file__': str(baseline)}
    exec(compile(baseline.read_text().split('with tempfile.TemporaryDirectory(', 1)[0], str(baseline), 'exec'), namespace)
    inputs = namespace['sources']

if '--host-policy' in sys.argv:
    host_checks = HERE.parent / 'extended-desktop/run.py'
    namespace = {'__file__': str(host_checks)}
    exec(compile(host_checks.read_text().split('\npaths = [ROOT', 1)[0], str(host_checks), 'exec'), namespace)
    inputs = namespace['inputs']

hashes = {name: sha(source.encode()) for name, source in inputs.items()}
payload = json.dumps({'sources': {name: base64.b64encode(source.encode()).decode() for name, source in inputs.items()},
                      'hashes': hashes}).encode()
runner = (HERE.parent / 'extended-desktop/remote.py').read_text()
start, end = runner.index('def run(command, timeout):'), runner.index("record['before'] = health()")
runner = runner[:start] + '''def run(command, timeout):
    global child
    print('COMMAND ' + json.dumps(command), flush=True)
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True, env=environment)
    try:
        output, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate(timeout=5)
    print(output.decode(errors='replace'), flush=True)
    record['commands'].append({'exitCode': child.returncode, 'command': command})
    return child.returncode == 0


''' + runner[end:]


def containers():
    process = subprocess.run(['docker', '--context', 'cargo24-mini', 'ps', '--format', '{{.ID}} {{.Names}} {{.Status}}'],
                             capture_output=True, text=True, check=True, timeout=20)
    return [' '.join(line.split()[:2]) + (' healthy' if '(healthy)' in line else ' unverified')
            for line in process.stdout.splitlines()]


services_before = containers()
process = subprocess.run(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--',
                          'python3', '-B', '-c', runner], input=payload, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, timeout=240)
log = process.stdout.decode(errors='replace')
print(log)
records = [json.loads(line.removeprefix('RESULT_JSON ')) for line in log.splitlines() if line.startswith('RESULT_JSON ')]
unchanged = all(sha((ROOT / name).read_bytes()) == value for name, value in before.items())
services_after = containers()
print(json.dumps({'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'testedSourceRef': source_ref or 'working tree',
    'testedHostRef': host_ref or 'working tree',
    'sourceUnchanged': unchanged, 'inputHashes': hashes,
    'sourceManifestSHA256': sha(json.dumps(before, sort_keys=True).encode()),
    'protectedBaselineHashes': {name: value for name, value in before.items() if 'extended-viewport-safety/' in name},
    'senderReceiverMatch': 'INPUT_SHA256 ' + sha(payload) in log,
    'containersBefore': services_before, 'containersAfter': services_after,
    'scope': 'independent pure extracted-source checks, not source-guard transfer, app build or physical acceptance'}, indent=2))
assert unchanged and 'INPUT_SHA256 ' + sha(payload) in log
assert sorted(services_before) == sorted(services_after), 'existing container state changed'
assert process.returncode == 0 and records
assert records[-1]['sourceRemoved'] and records[-1]['inputHashesMatched'] and records[-1]['memoryInputUnchanged']
