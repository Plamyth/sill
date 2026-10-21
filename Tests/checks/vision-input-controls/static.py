import ast
import json
import plistlib
import subprocess
from pathlib import Path
from extract import ROOT, block, fixture, select_platform

results = {}


def check(name, passed):
    results[name] = bool(passed)
    assert passed, name


def baseline(path):
    return subprocess.check_output(['git', '--no-lazy-fetch', 'show', '51f241522268ddc71d974056f1a3484645d7aa17:' + path], cwd=ROOT).decode()


stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
send = block(stream, 'func sendInput(')
check('iPad input encoder unchanged', select_platform(send, vision=False) == select_platform(block(baseline('iOSClient/StreamClient.swift'), 'func sendInput('), vision=False))
check('iPad move coalescer unchanged', block(stream, 'private func flushPendingMove()') == block(baseline('iOSClient/StreamClient.swift'), 'private func flushPendingMove()'))
check('native capture owns immutable permit before enqueue', send.index('let permit = visionInputPermit') < send.index('queue.async') and 'onlyOn: expected, permit: permit' in send)
check('native actual-send debt callback remains weak', 'self?.visionInputDebt.record(input, on: expected)' in send)
hello = block(stream, 'private static let helloPayload: Data =')
check('only Vision advertises presentation capability', 'let presentationInput: Int? = 1' in select_platform(hello, vision=True) and 'let presentationInput: Int? = nil' in select_platform(hello, vision=False))
check('both clients retain optional source codec negotiation', all('sourceInput: 1' in select_platform(hello, vision=v) for v in [False, True]))
session = (ROOT / 'visionOSClient/VisionInputSession.swift').read_text()
pointer = (ROOT / 'visionOSClient/VisionPointer.swift').read_text()
spatial = (ROOT / 'visionOSClient/VisionSpatialInput.swift').read_text()
admission = block(session, 'var canSend: Bool')
check('native controls retain all admission fences', all(guard in admission for guard in ['!client.visionDisplaySelection.inputBlocked', 'allowed', '!moving', 'client.connected', 'client.active != .none', 'client.visionInputBinding.isConfirmed']))
for marker in ['func spatial(', 'func magnify(', 'func rotate(']:
    callback = block(session, marker)
    check(marker + ' requires current revision geometry and admission', all(guard in callback for guard in ['revision == gestureRevision', 'self.geometry == geometry', 'guard canSend']))
check('context cancellation retires gesture revision and reducer', all(guard in block(session, 'private func cancelPointer()') for guard in ['gestureRevision = UUID()', 'magnification = nil', 'pointer.cancel()', 'pointer = VisionPointer()']))
check('keyboard events cancel pointer without consuming keyboard debt', 'cancelPointer()' in block(session, 'func overlayInput(') and 'takeReleases()' not in block(session, 'func overlayInput('))
check('emergency reset retains keyboard and actual transport debt', 'takeVisionKeyReleases()' in block(session, 'func takeReleases()') and 'client?.cancelVisionInputs()' in block(session, 'func releaseAll()'))
workspace = (ROOT / 'visionOSClient/SillVisionApp.swift').read_text()
emergency = block(workspace, 'Button("누른 입력 해제")')
controls = block(workspace, 'private var controls: some View')
check('emergency release remains outside disabled controls with window ownership', 'withWindowOwnership { input.releaseAll() }' in emergency and emergency not in controls and '.disabled(!input.canSend || draftShown)' in controls)
check('no native input mode state picker or callers remain', all(token not in workspace + session + pointer for token in ['VisionPointer.Mode', 'var mode =', 'enum Mode', 'mode: mode', 'Picker("조작"', 'input.tap(', 'input.drag(', 'input.endGesture(']))
check('native gesture adapter replaces exclusive tap drag', 'VisionSpatialInput(input: input' in workspace and 'SpatialTapGesture' not in workspace and 'DragGesture' not in workspace and '.simultaneously(with: MagnifyGesture().simultaneously(with: RotateGesture()))' in spatial)
adapter = block(spatial, 'extension VisionPointer.Sample {')
check('native contact mapping retains id timestamp local location and cancellation', all(token in adapter for token in ['AnyHashable(event.id)', 'timestamp: event.timestamp', 'location: event.location', 'case .cancelled: phase = .cancelled', '@unknown default: phase = .cancelled']))
check('native contact kinds refuse hover pointer', 'case .directPinch, .indirectPinch, .touch: break' in adapter and 'default: return nil' in adapter)
check('native magnification wins arbitration before contact tails', all(block(spatial, marker).index('input.magnify(') < block(spatial, marker).index('input.spatial(') for marker in ['.onChanged {', '.onEnded {']))
check('native zoom precedes rotation and contact dispatch', all(
    block(spatial, marker).index('input.magnify(') < block(spatial, marker).index('input.rotate(') < block(spatial, marker).index('input.spatial(')
    for marker in ['.onChanged {', '.onEnded {']))
rotation = block(session, 'private struct Rotation {')
rotate = block(session, 'func rotate(')
finish = block(session, 'func finishGesture(')
check('rotation captures angle time client peer binding source and display token', all(
    token in rotation for token in ['var degrees: Double', 'var time: TimeInterval', 'let client: StreamClient',
                                  'let peer: ObjectIdentifier', 'let scope: VisionInputBinding',
                                  'let source: StreamSource', 'let token: VisionDisplaySelection.Token?']))
check('rotation rejects invalid numbers anchors and late values', all(
    token in rotate for token in ['degrees.isFinite', 'time.isFinite', 'viewport.point(anchor, in: geometry) != nil',
                                 'time >= (rotation?.time ?? -.infinity)', 'finishGesture(revision: revision)']))
check('rotation cancels pointer and scroll before capturing scope', rotate.index('momentum.stop()') < rotate.index('pointer.cancel()') < rotate.index('rotation = Rotation('))
check('only completion selects once through captured client after input cleanup',
      'selectAdjacentVisionDisplay' not in rotate and 'completed && magnification?.blocksRotation != true ? rotation : nil' in finish and
      finish.count('selectAdjacentVisionDisplay') == 1 and finish.index('let events = cancelPointer()') < finish.index('selectAdjacentVisionDisplay') and
      all(token in finish for token in ['client === turn.client', 'turn.client.connection.map(ObjectIdentifier.init) == turn.peer',
                                       'turn.client.visionInputBinding == turn.scope', 'turn.client.active == turn.source',
                                       'turn.client.visionDisplaySelection.token == token', 'abs(turn.degrees) >= 25',
                                       'turn.client.selectAdjacentVisionDisplay(by: turn.degrees > 0 ? 1 : -1, expected: token)']))
check('client replacement retires old input before rebinding', block(session, 'func bind(').index('releaseAll()') < block(session, 'func bind(').index('self.client = client'))
check('rotation has no remote gain owner ticket preview or commit', all(token not in session for token in ['gainOwner', 'gainTicket', 'VisionAudioGain']))
check('eight percent zoom history suppresses rotation', all(token in block(session, 'func magnify(') for token in [
    'zoom.blocksRotation || factor <= 0.92 || factor >= 1.08', 'if magnification?.blocksRotation == true { rotation = nil }']))
check('Korean guidance describes monitor rotation and optional modifier drag', 'Mac 모니터' in spatial and '25도' in spatial and
      '보조 키를 선택하고 길게 집은 뒤' in spatial and 'Mac 모니터 한 칸 전환' in workspace and '보조 키를 선택하고 길게 집은 뒤' in workspace)
check('native anchor and captured revision survive recognizer cancellation', all(token in spatial for token in ['zoom.startLocation', '@State private var revision: UUID?', 'let ticket = revision ?? input.gestureRevision', '.onChange(of: recognizing)', 'input.finishGesture(revision: ticket)', '.onChange(of: geometry, initial: true)']))
check('stream transform and viewport inverse agree on centered scale and offset', all(token in workspace for token in ['.scaleEffect(input.viewport.scale, anchor: .center)', '.offset(input.viewport.offset)']) and all(token in pointer for token in ['point.x - geometry.bounds.midX - offset.width', 'point.y - geometry.bounds.midY - offset.height', '/ scale', 'clamp || geometry.bounds.contains(point)', 'clamp || rect.contains', 'min(4, max(1, scale * factor))']))
check('no gaze polling grid or new tracking permission', all(token not in spatial + pointer for token in ['onContinuousHover', 'ARKitSession', 'queryDeviceAnchor', 'eyeTracking', 'hoverGrid']))
project = plistlib.loads((ROOT / 'SillVision.xcodeproj/project.pbxproj').read_bytes())['objects']
refs = {key for key, value in project.items() if value.get('isa') == 'PBXFileReference' and value.get('path') == 'visionOSClient/VisionSpatialInput.swift'}
builds = {key for key, value in project.items() if value.get('isa') == 'PBXBuildFile' and value.get('fileRef') in refs}
app_targets = [value for value in project.values() if value.get('isa') == 'PBXNativeTarget' and value.get('productType') == 'com.apple.product-type.application']
check('generated project builds native adapter exactly once per app target', len(refs) == len(builds) == 1 and
      {target.get('name') for target in app_targets} == {'SillVision', 'SillVisionReleaseTest'} and
      all(sum(key in project[phase].get('files', []) for phase in target.get('buildPhases', []) for key in builds) == 1
          for target in app_targets) and "'VisionSpatialInput'" in (ROOT / 'Scripts/make-vision-project.py').read_text())
check('move and teardown await fresh catalog', all('visionInputBinding = .awaitingCatalog' in block(stream, marker) for marker in ['private func finishMoveAfterInputDrain(', 'func tearDown(status:']))
files, manifest = fixture()
check('fixture substitutions resolved', all(marker not in files['Client.swift'] for marker in ['// EXTRACTED', '// OVERLAY_DRAIN', '// MOVE_INPUT_RESET', '// BINDING_STATE']))
check('fixture uses production SourceInputFence', files['Tests/checks/vision-input-controls/SourceInputFence.swift'] == (ROOT / 'Sources/SillHost/SourceInputFence.swift').read_text())
check('fixture includes native presentation state', files['visionOSClient/VisionPresentation.swift'] == (ROOT / 'visionOSClient/VisionPresentation.swift').read_text())
check('fixture adjacency uses production display selection instead of a token only stub',
      files['visionOSClient/VisionDisplaySelection.swift'] == (ROOT / 'visionOSClient/VisionDisplaySelection.swift').read_text() and
      'var visionDisplaySelection = VisionDisplaySelection()' in files['Client.swift'] and
      'visionDisplaySelection.adjacentCommand(by: step, expected: expected)' in files['Client.swift'])
check('fixture executes actual reducer session and framework contact adapter', files['visionOSClient/VisionPointer.swift'] == pointer and files['visionOSClient/VisionInputSession.swift'] == session and files['SpatialAdapter.swift'] == 'import SwiftUI\n' + adapter + '\n')
runner = (Path(__file__).parent / 'run.py').read_text()
check('actual runner executes contact adapter session and viewport reducer tests', "'SpatialAdapter.swift'" in runner and "'Tests/vision-pointer/main.swift'" in runner and "'runtime-pointer'" in runner)
check('fixture has actual scoped input and hello paths', all(marker in files['Client.swift'] for marker in ['private func observeVisionInputCatalog(', 'private func visionPresentationChanged(', 'private static let helloPayload:', 'private static let iPadHelloPayload:']))
pairs = [('debt', 'Client.swift'), ('route', 'iOSClient/SessionLink.swift'), ('capture', 'Client.swift'), ('generation', 'visionOSClient/VisionInputDebt.swift'), ('admission', 'Client.swift'), ('controls', 'visionOSClient/VisionInputSession.swift')]
check('all six prior runtime mutants change source', all(files['mutants/' + name + '/' + Path(path).name] != files[path] for name, path in pairs))
resume = block(stream, 'if let resume = self.resumeSource')
check('automatic resume remains guarded', resume.index('self.resumeSource = nil') < resume.index('if list.active == .none, !Self.noAutoDesktop') < resume.index('self.request(pick)'))
for path in Path(__file__).parent.glob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
check('fixture Python syntax valid', True)
print(json.dumps({'checks': results, 'count': len(results), 'extractionSHA256': manifest,
                  'scope': 'Static source parity and fixture generation only. Swift compilation and runtime are not executed.'}, indent=2))
