"""Verify the merge's source contracts without compilers, apps, or network access."""
import argparse
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_platform import select_platform

VISION = 'f331d8d307fb301e1c0f2bfd71e4a83a76d62dbc'
IPAD = '3bd3c0b4cdf91a2b16f1fd68be9265700acaaff5'
MANIFEST = ROOT / 'docs/sill-unified-preservation.json'
results = {}


def git(*args):
    return subprocess.check_output(['git', '--no-lazy-fetch', *args], cwd=ROOT)


def check(name, value):
    results[name] = bool(value)
    assert value, name


def text(path):
    return (ROOT / path).read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def load_fixture(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tree(revision):
    entries = {}
    for record in git('ls-tree', '-rz', revision).split(b'\0'):
        if record:
            metadata, path = record.split(b'\t', 1)
            mode, kind, blob = metadata.decode().split()
            entries[path.decode()] = {'mode': mode, 'blob': blob}
    return entries


def preserved(revision, paths):
    entries = tree(revision)
    selected = {}
    for path in sorted(paths):
        expected = entries[path]
        local = ROOT / path
        content = os.readlink(local).encode() if local.is_symlink() else local.read_bytes()
        actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        check('preserved ' + path, actual == expected['blob'])
        if expected['mode'] == '120000':
            check('symlink ' + path, local.is_symlink())
        else:
            check('mode ' + path, bool(local.stat().st_mode & 0o111) == (expected['mode'] == '100755'))
        selected[path] = {**expected, 'sha256': hashlib.sha256(content).hexdigest()}
    return {'parent': revision, 'files': selected}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--write-manifest', action='store_true')
args = parser.parse_args()
peer_tree, vision_tree = tree(IPAD), tree(VISION)
vision_common = {
    'iOSClient/DiscoveryPolicy.swift', 'iOSClient/StreamClient+Remote.swift',
    'iOSClient/StreamClient+Viewport.swift', 'iOSClient/HEVCDisplayView.swift',
    'iOSClient/InputOverlay.swift', 'iOSClient/SessionLink.swift',
}
fixture_changes = {'Tests/checks/delayed-source-input/run.py', 'Tests/checks/iPad-remote-audio/fixture.py'}
peer_sources = {p for p in peer_tree if p.startswith('Sources/') and not p.startswith('Sources/StreamProtocol/')}
peer_tests = {p for p in peer_tree if p.startswith('Tests/') and p not in fixture_changes | {'Tests/touchrig/run.sh'}}
peer_ui = {p for p in peer_tree if p.startswith('iOSClient/') and p not in vision_common | {'iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Audio.swift'}}
protocol = {p for p in peer_tree if p.startswith('Sources/StreamProtocol/')}
native = {p for p in vision_tree if p.startswith(('visionOSClient/', 'SillVision.xcodeproj/'))} | vision_common | {'Scripts/make-vision-project.py', 'Package.swift', 'Tests/touchrig/run.sh'}
groups = {
    'peer_host_and_probes': preserved(IPAD, peer_sources),
    'peer_existing_tests': preserved(IPAD, peer_tests),
    'peer_iPad_UI_store_player_controller_project': preserved(IPAD, peer_ui),
    'protocol_both_parents': preserved(IPAD, protocol),
    'native_application_input_audio_policy_packaging': preserved(VISION, native),
}
check('protocol inventory identical between parents', protocol == {p for p in vision_tree if p.startswith('Sources/StreamProtocol/')})
check('protocol blobs identical between parents', all(peer_tree[p] == vision_tree[p] for p in protocol))
check('host products and probe declarations exact peer', text('Package.swift').replace(', .visionOS("2.5")', '') == git('show', IPAD + ':Package.swift').decode())

stream = text('iOSClient/StreamClient.swift')
old = git('show', VISION + ':iOSClient/StreamClient.swift').decode()
peer = git('show', IPAD + ':iOSClient/StreamClient.swift').decode()
native_stream = select_platform(stream, vision=True)
ipad_stream = select_platform(stream, vision=False)
check('native excludes iPad audio classes and hooks', all(token not in native_stream for token in ['RemoteAudioPlayer', 'remoteAudioControl.', 'remoteAudioStatus', 'receiveRemoteAudio(']))
for marker in ['var connection: NWConnection?', 'func sendInput(', 'private func request(']:
    for debug in [False, True]:
        check('iPad actual method matches peer ' + marker + ' debug=' + str(debug), select_platform(block(stream, marker), vision=False, debug=debug) == select_platform(block(peer, marker), vision=False, debug=debug))
for marker in ['private func finishMove(', 'private func applyVisionInputCatalog(', 'func cancelVisionInputs(', 'private static func visionInputBytes(', 'private func sendVisionAudio(', 'private func deliver(']:
    check('native method preserved ' + marker, select_platform(block(stream, marker), vision=True) == select_platform(block(old, marker), vision=True))
check('native connection setter exact f331', block(native_stream, 'var connection: NWConnection?') == select_platform(block(old, 'var connection: NWConnection?'), vision=True))
check('native audio adapter empty and iPad adapter exact peer', select_platform(text('iOSClient/StreamClient+Audio.swift'), vision=True) == '' and select_platform(text('iOSClient/StreamClient+Audio.swift'), vision=False) == git('show', IPAD + ':iOSClient/StreamClient+Audio.swift').decode())
handle = block(ipad_stream, 'private func handle(')
check('iPad hook takes actual origin', 'if receiveRemoteAudio(header, data, from: peer) { return }' in handle and 'let from: NWConnection? = peer' in handle)
check('iPad catalog guards origin before consent and generation', handle.index('guard self.connection === from') < handle.index('self.remoteAudioControl.receive(list, from: ObjectIdentifier(peer))') < handle.index('self.inputGeneration = list.inputGeneration'))
check('native catalog keeps origin guard and typed helper', 'guard connection === peer else { return }' in native_stream and 'guard self.applyVisionInputCatalog(list, from: from) else { return }' in native_stream)
move = block(stream, 'private func finishMoveAfterInputDrain(')
check('iPad handover consent bound before link adoption', select_platform(move, vision=False).index('remoteAudioControl.setConnection(ObjectIdentifier(c))') < move.index('link.handOver('))
check('native no automatic source and viewport policy', 'private static let noAutoDesktop = true' in native_stream and 'sendViewport(' not in text('visionOSClient/SillVisionApp.swift'))
resume = block(stream, 'if let resume = self.resumeSource')
check('resume change only applies existing policy', resume.replace('list.active == .none, !Self.noAutoDesktop', 'list.active == .none') == block(old, 'if let resume = self.resumeSource'))

sample = '#if os(visionOS)\nvision\n#if DEBUG\ndebug\n#else\nrelease\n#endif\n#elseif DEBUG\nipad-debug\n#else\nipad-release\n#endif\n'
check('nested platform selection and elseif', select_platform(sample, vision=True) == 'vision\nrelease\n' and select_platform(sample, vision=False, debug=True) == 'ipad-debug\n' and select_platform(sample, vision=False) == 'ipad-release\n')
for sample in ['#if UNKNOWN\nx\n#endif\n', '#else\n', '#if DEBUG\nx\n']:
    try:
        select_platform(sample, vision=True)
    except ValueError:
        pass
    else:
        raise AssertionError('invalid platform directive accepted')
check('platform selector fails closed', True)

extracted = load_fixture('unified_native', 'Tests/checks/vision-input-controls/extract.py')
files, hashes = extracted.fixture()
check('native extracted setter and input are actual selected methods', all(select_platform(block(stream, marker), vision=True) in files['Client.swift'] for marker in ['var connection: NWConnection?', 'func sendInput(']))
check('native fake SwiftUI annotation qualified', '@SwiftUI.Published private(set) var visionInputBinding' in files['Client.swift'])
check('resume fixture includes actual branch and both policies', select_platform(resume, vision=True) in files['Client.swift'] and all(token in files['main.swift'] for token in ['StreamClient.noAutoDesktop = true', 'StreamClient.noAutoDesktop = false', 'resumeClient.requested.isEmpty', 'resumeClient.resumeSource == nil']))
delayed = load_fixture('unified_delayed', 'Tests/checks/delayed-source-input/run.py')
generated = delayed.program({p: text(p) for p in delayed.FILES})
check('iPad delayed-source fixture uses actual method without native symbols', block(ipad_stream, 'func sendInput(') in generated and all(token not in generated for token in ['VisionInputBinding', 'visionInputDebt', 'visionMovePreparation']))
check('iPad fixture retains actual capture and Data coalescing', 'private var pendingMove: Data?' in ipad_stream and generated.index('let payload = SourceInput.payload(event, generation: inputGeneration)') < generated.index('self.pointerNoteSent(event)') and block(ipad_stream, 'private func flushPendingMove()') in generated)
project = plistlib.loads((ROOT / 'SillVision.xcodeproj/project.pbxproj').read_bytes())
paths = {o['path'] for o in project['objects'].values() if o.get('lastKnownFileType') == 'sourcecode.swift'}
check('native project excludes iPad player UI and adapter', all(not p.startswith('iOSClient/CanvasBridge/') and Path(p).stem not in ['RemoteAudioPlayer', 'IPadRemoteAudioController', 'StreamClient+Audio', 'ContentView', 'StreamScreen', 'HostSettingsPanel'] for p in paths))
check('native project source paths exist', all((ROOT / p).is_file() for p in paths))
python_paths = [
    'Tests/checks/swift_platform.py', 'Tests/checks/sill-unified-client/static.py',
    'Tests/checks/delayed-source-input/run.py', 'Tests/checks/iPad-remote-audio/fixture.py',
    'Tests/checks/vision-input-controls/extract.py', 'Tests/checks/vision-input-controls/static.py',
    'Tests/checks/reconnect-glue/extract.py', 'Tests/checks/reconnect-glue/static.py',
    'Tests/checks/vision-audio-consent/static.py', 'Tests/checks/vision-audio-player/static.py',
]
for path in python_paths:
    ast.parse(text(path), filename=path)
check('modified Python syntax valid', True)
decisions = {
    'iOSClient/StreamClient.swift': 'One shared transport; exact native debt and readiness; peer captured generic input and Data coalescing; actual-origin audio on both platforms; both Hello sourceInput 1; consume resume and require existing noAutoDesktop policy.',
    'iOSClient/StreamClient+Audio.swift': 'Exact peer adapter wrapped only in !os(visionOS). Native generator still excludes it.',
    'Package.swift': 'Exact f331 platform addition. Existing host products and probe declarations remain exact peer.',
    'Tests/touchrig/run.sh': 'Exact f331 protocol dependency packaging for Input.swift. UIKit fixture, no runtime execution here.',
}
manifest = {
    'workKey': 'sill-unified-client-20261016',
    'parents': [VISION, IPAD],
    'parentTrees': {revision: git('rev-parse', revision + '^{tree}').decode().strip() for revision in [VISION, IPAD]},
    'groups': groups,
    'changedContracts': {path: {'decision': decision, 'sha256': hashlib.sha256((ROOT / path).read_bytes()).hexdigest()} for path, decision in decisions.items()},
    'nativeExtractionSHA256': hashes,
    'scope': 'Exact source preservation and static composition. No compiler, runtime, device, network, audio, independent review, provenance acceptance, or publication.',
}
if args.write_manifest:
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
else:
    check('manifest matches current exact sources', json.loads(MANIFEST.read_text()) == manifest)
print(json.dumps({'count': len(results), 'groups': {name: len(group['files']) for name, group in groups.items()}, 'contracts': len(decisions), 'scope': manifest['scope']}, indent=2))
