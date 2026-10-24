"""실제 InputOverlay memberwise initializer의 기존 Vision 호출 호환성을 컴파일한다."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
here = Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    out = ROOT / '.build/checks/ipad-input-epoch' / sys.argv[1]
    modules = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    producer = load('producer', here / 'producer.py').fixture(ROOT, include_adapter=False)
    producer = producer.replace('class FakeUIView: NSObject {', '''class FakeUIView: NSObject {
    override init() { super.init() }
    convenience init(frame: CGRect) { self.init() }
''')
    producer = producer.replace('final class InputOverlayView: FakeUIView {', '''final class InputOverlayView: FakeUIView {
    var videoSize = CGSize.zero
    var onDockSwipe: () -> Void = {}
    var latchedModifiers: KeyModifiers = []
    var sendGesture: (TrackpadGestures.Gesture, Int) -> Bool = { _, _ in false }
    var onModifiersConsumed: (() -> Void)?
    var onKeyboardShownChange: ((Bool) -> Void)?
''')
    adapter = '''import Foundation
import CoreGraphics
import StreamProtocol
protocol UIViewRepresentable {}
typealias Context = Void
enum TrackpadGestures { enum Gesture { case swipe } }
final class Box<Value> { var value: Value; init(_ value: Value) { self.value = value } }
@propertyWrapper struct Binding<Value> {
    let box: Box<Value>
    init(_ value: Value) { box = Box(value) }
    var wrappedValue: Value { get { box.value } nonmutating set { box.value = newValue } }
}
final class InputOverlayProxy { weak var view: InputOverlayView? }
'''
    extract = load('extract', ROOT / 'Tests/checks/vision-input-controls/extract.py')
    adapter += extract.block((ROOT / 'iOSClient/InputOverlay.swift').read_text(), 'struct InputOverlay: UIViewRepresentable')
    adapter += '\n' + extract.block((ROOT / 'iOSClient/TrackpadView.swift').read_text(), 'struct TrackpadView: UIViewRepresentable')
    main_source = '''import Foundation
import StreamProtocol
let proxy = InputOverlayProxy()
let legacyVision = InputOverlay(videoSize: .zero, send: { _ in },
    setOwnPointer: { _, _ in }, proxy: proxy, isKeyboardShown: Binding(false),
    latchedModifiers: [], onModifiersConsumed: {})
let view = legacyVision.makeUIView(context: ())
legacyVision.updateUIView(view, context: ())
precondition(view.captureInputSender == nil)
print("PASS 기존 Vision InputOverlay initializer와 capture 기본값 호환")
let legacyPad = TrackpadView(send: { _ in }, setPointer: { _ in }, feed: { (nil, 0) },
    onFingers: { _ in }, latched: [], onModifiersConsumed: {})
let pad = legacyPad.makeUIView(context: ())
legacyPad.updateUIView(pad, context: ())
precondition(pad.captureInputSender == nil)
print("PASS 기존 TrackpadView initializer와 capture 기본값 호환")
'''
    for name, text in [('Producer.swift', producer), ('Adapter.swift', adapter), ('main.swift', main_source)]:
        (out / name).write_text(text)
    commands = [
        ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(modules / 'cache'), '-I', str(modules),
         str(out / 'Producer.swift'), str(out / 'Adapter.swift'), str(ROOT / 'iOSClient/KeyChords.swift'),
         str(out / 'main.swift'), str(modules / 'StreamProtocol.o'), '-o', str(out / 'check')],
        [str(out / 'check')],
    ]
    results = []
    for index, command in enumerate(commands):
        p = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        (out / f'{index}.log').write_text(p.stdout)
        results.append({'phase': index, 'exitCode': p.returncode})
        print(p.stdout, end='', flush=True)
        if p.returncode: break
    (out / 'result.json').write_text(json.dumps({'commands': results, 'scope': '실제 struct·기존 Vision 호출의 타입 호환. SwiftUI 렌더·실물 증거 아님.'}, ensure_ascii=False, indent=2) + '\n')
    return int(results[-1]['exitCode'] != 0)


if __name__ == '__main__':
    sys.exit(main())
