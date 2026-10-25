"""실제 입력 함수 → epoch·permit → 메모리 wire. UIKit·기기·Host 실행 없음."""
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


epoch = load('epoch', 'Tests/checks/ipad-input-epoch/run.py')
producer = load('producer', 'Tests/checks/ipad-input-epoch/producer.py')
extract = load('extract', 'Tests/checks/vision-input-controls/extract.py')


def fixture():
    source = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
    if '--base-pan' in sys.argv:
        source = subprocess.check_output(['git', 'show', 'a7bc49211b3fa975d5261e07b1dd14aeea154ff9:iOSClient/InputOverlay.swift'], cwd=ROOT, text=True)
    body = '\n'.join(extract.select_platform(extract.block(source, marker), vision=False, ios=True)
                     for marker in ['@objc private func handlePan(', 'private func startMomentum(',
                                    'private func strokeSilenced()', 'func insertText(', 'func deleteBackward()',
                                    'private func sendLatched(', 'private func consumeLatch()'])
    generated = producer.fixture(ROOT, include_adapter=False)
    generated = generated.replace('final class UIPanGestureRecognizer: UIGestureRecognizer {}', '''
final class UIPanGestureRecognizer: UIGestureRecognizer {
    var translation = CGPoint.zero
    var velocity = CGPoint.zero
    func translation(in view: FakeUIView) -> CGPoint { translation }
    func velocity(in view: FakeUIView) -> CGPoint { velocity }
}''')
    generated = generated.replace('let momentum = Momentum()', '''let momentum = Coast()
    var lastPanTranslation = CGPoint.zero
    enum EdgePan { case none, candidate, revealed }
    var edgePan = EdgePan.none
    var onDockSwipe: () -> Void = {}
    var latchedModifiers: KeyModifiers = []
    var onModifiersConsumed: (() -> Void)?
''')
    generated = generated.replace('\n}\nfinal class Haptic', '\n' + body.replace('private ', '').replace('@objc ', '') + '\n}\nfinal class Haptic')
    return generated + '\n' + extract.block((ROOT / 'iOSClient/PortraitStreamScreen.swift').read_text(), 'enum HIDKey')


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    files = {'Client.swift': epoch.fixture(), 'Producer.swift': fixture(),
             'Network.swift': (ROOT / 'Tests/checks/vision-input-controls/Network.swift').read_text(),
             'main.swift': Path(__file__).with_name('main.swift').read_text()}
    if '--epoch-regression' in sys.argv:
        files['Producer.swift'] = producer.fixture(ROOT)
        files['main.swift'] = (ROOT / 'Tests/checks/ipad-input-epoch/main.swift').read_text()
    elif '--gesture-admission' in sys.argv:
        files['Producer.swift'] = (ROOT / 'iOSClient/TrackpadGestures.swift').read_text()
        files['main.swift'] = Path(__file__).with_name('admission.swift').read_text()
    for name, source in files.items():
        (out / name).write_text(source)
    paths = list((ROOT / 'Sources/StreamProtocol').glob('*.swift')) + [
        ROOT / p for p in ['iOSClient/StreamClient.swift', 'iOSClient/InputOverlay.swift',
                          'iOSClient/TrackpadView.swift', 'iOSClient/SessionLink.swift',
                          'iOSClient/KeyChords.swift', 'visionOSClient/VisionInputDebt.swift',
                          'visionOSClient/VisionPresentation.swift']]
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    base = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache')]
    commands = [
        base + ['-parse-as-library', '-emit-module', '-emit-object', '-module-name', 'Network', str(out / 'Network.swift'), '-emit-module-path', str(out / 'Network.swiftmodule'), '-o', str(out / 'Network.o')],
        base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + [str(p) for p in sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))] + ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')],
        base + ['-I', str(out), str(out / 'Client.swift'), str(out / 'Producer.swift'), str(ROOT / 'iOSClient/SessionLink.swift'), str(ROOT / 'iOSClient/KeyChords.swift'), str(ROOT / 'visionOSClient/VisionInputDebt.swift'), str(ROOT / 'visionOSClient/VisionPresentation.swift'), str(out / 'main.swift'), str(out / 'Network.o'), str(out / 'StreamProtocol.o'), '-o', str(out / 'check')],
        [str(out / 'check')],
    ]
    if '--reuse-modules' in sys.argv:
        modules = Path(sys.argv[sys.argv.index('--reuse-modules') + 1]).resolve()
        previous = json.loads((modules / 'result.json').read_text())['sourceSHA256']
        assert all(previous[p] == h for p, h in before.items() if p.startswith('Sources/StreamProtocol/'))
        assert (modules / 'Network.swift').read_text() == files['Network.swift']
        commands = [[str(modules / 'cache') if p == str(out / 'cache') else str(modules) if p == str(out) else str(modules / Path(p).name)
                     if p in [str(out / 'Network.o'), str(out / 'StreamProtocol.o')] else p
                     for p in command] for command in commands[2:]]
    results = []
    for index, command in enumerate(commands):
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        output = run.stdout + run.stderr
        (out / f'{index}.log').write_text(output)
        results.append({'phase': index, 'exitCode': run.returncode})
        print(output, end='')
        if run.returncode:
            break
    unchanged = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in before.items())
    (out / 'result.json').write_text(json.dumps({'commands': results, 'sourceSHA256': before,
        'generatedSHA256': {name: hashlib.sha256(source.encode()).hexdigest() for name, source in files.items()},
        'basePan': 'a7bc49211b3fa975d5261e07b1dd14aeea154ff9' if '--base-pan' in sys.argv else None,
        'sourceUnchanged': unchanged, 'scope': __doc__}, ensure_ascii=False, indent=2) + '\n')
    return int(results[-1]['exitCode'] != 0 or not unchanged)


if __name__ == '__main__':
    sys.exit(main())
