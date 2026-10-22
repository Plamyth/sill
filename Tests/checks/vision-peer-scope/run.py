from pathlib import Path
import sys, subprocess, tempfile, hashlib, json

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'Tests/checks/vision-input-controls'))
from extract import block
sys.path.insert(0, str(root / 'Tests/checks'))
from swift_platform import select_platform

with tempfile.TemporaryDirectory(prefix='vision-peer-scope-') as tmp:
    out = Path(tmp)
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    markers = ['func command(', 'func sendGesture(', 'private func sendVisionPeerCommand<',
               'func subscribeToMenus(', 'func fetchTopMenu(', 'func fetchMenu(_ row:',
               'private func fetchMenu(id:', 'func pressMenuItem(', 'private func receiveMenus(',
               'private func reconcileVisionPeerMenus(', 'private func resetVisionPeerStreams(', 'func prepareVisionPeerSourceChange(',
               'func cancelVisionInputs(', 'private static func visionInputBytes(', 'private func visionPresentationChanged(',
               'private func request(_ source:', 'func launch(bundleID:']
    methods = '\n'.join(select_platform(block(stream, m), vision=True).replace('private ', '') for m in markers)
    methods = methods.replace('func prepareVisionPeerSourceChange(', '@discardableResult\nfunc prepareVisionPeerSourceChange(')
    stub = (root / 'Tests/checks/vision-peer-scope/Standins.swift').read_text()
    deferred = block((root / 'iOSClient/MacMenuElements.swift').read_text(), 'static func deferred(')
    (out / 'Client.swift').write_text(stub.replace('// METHODS', methods).replace('// DEFERRED', deferred))
    (out / 'Lease.swift').write_text('import Foundation\n' + block((root / 'visionOSClient/VisionCableBootstrap.swift').read_text(), 'struct VisionWindowLease:'))
    sources = ['iOSClient/MacMenuState.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift',
               'iOSClient/TrackpadGestures.swift', 'visionOSClient/VisionInputDebt.swift', 'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionDisplaySelection.swift',
               'Tests/checks/vision-peer-scope/main.swift']
    hashes = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources + ['iOSClient/StreamClient.swift', 'iOSClient/MacMenuElements.swift', 'visionOSClient/StreamClient+VisionDisplaySelection.swift']}
    def run(args):
        p = subprocess.run(args, cwd=out, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(p.stdout, end='', flush=True)
        if p.returncode: raise SystemExit(p.returncode)
    run(['xcrun', 'swiftc', '-swift-version', '5', '-emit-library', '-emit-module', '-module-name', 'Network',
         str(root / 'Tests/checks/vision-input-controls/Network.swift'), '-o', str(out / 'libNetwork.dylib')])
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
         *[str(p) for p in sorted((root / 'Sources/StreamProtocol').glob('*.swift'))], '-o', str(out / 'libStreamProtocol.dylib')])
    flags = ['xcrun', 'swiftc', '-swift-version', '5', '-I', str(out), '-L', str(out), '-lNetwork', '-lStreamProtocol',
             '-Xlinker', '-rpath', '-Xlinker', str(out)]
    run(flags + [str(root / p) for p in sources] + [str(out / 'Client.swift'), str(out / 'Lease.swift'), '-o', str(out / 'scope-checks')])
    run([str(out / 'scope-checks'), *sys.argv[1:]])
    legacy = out / 'legacy'
    legacy.mkdir()
    (legacy / 'main.swift').write_text('import StreamProtocol\n' + (root / 'Tests/checks/menu-state/main.swift').read_text())
    run(flags + [str(root / 'iOSClient/MacMenuState.swift'), str(legacy / 'main.swift'), '-o', str(out / 'legacy-menu-checks')])
    run([str(out / 'legacy-menu-checks')])
    assert all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    print(json.dumps({'sourceUnchanged': True, 'extractedMethods': {m: hashlib.sha256(block(stream, m).encode()).hexdigest() for m in markers},
                      'deferredSHA256': hashlib.sha256(deferred.encode()).hexdigest(), 'sourceSHA256': hashes,
                      'scope': 'production Vision command and menu methods with inert Network; no device or host effects'}))
