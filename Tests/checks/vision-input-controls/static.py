"""Check source composition and fixture assembly without invoking a Swift compiler or runtime."""
import ast
import hashlib
import json
import subprocess
from pathlib import Path

from extract import ROOT, block, fixture

BASE = 'b403986efa84a0741400da2153d0d09b3b00bc81'
results = {}


def check(name, passed):
    results[name] = bool(passed)
    assert passed, name


def baseline(path, revision=BASE):
    return subprocess.check_output(['git', '--no-lazy-fetch', 'show', revision + ':' + path], cwd=ROOT)


for path, expected in {
    'Sources/StreamProtocol/Input.swift': '82b454edc3cc818a7c8ccd372a3861c897161864',
    'Sources/StreamProtocol/Compatibility.swift': '8bd6f3d0b3dcdea6bff2f855f6af6153d48b1223',
    'Tests/checks/vision-input-controls/SourceInputFence.swift': '17918baec9691e5118000c42e348717bb29ef341',
}.items():
    content = (ROOT / path).read_bytes()
    actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
    check('exact peer148 blob ' + path, actual == expected)

stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
old_stream = baseline('iOSClient/StreamClient.swift').decode()
send = block(stream, 'func sendInput(')
check('confirmed capture and serialization precede queue', send.index('guard let input = visionInputBinding.capture(event) else { return }') < send.index('Self.visionInputBytes(input)') < send.index('queue.async'))
check('locked scoped send and weak actual callback retained', 'self.link.send(bytes, onlyOn: expected) { [weak self] in\n                self?.visionInputDebt.record(input, on: expected)' in send)
check('iPad input path unchanged', send.split('#else', 1)[1] == block(old_stream, 'func sendInput(').split('#else', 1)[1])
hello = block(stream, 'private static let helloPayload: Data =')
check('capability confined to Vision', '#if os(visionOS)\n        hello.sourceInput = 1\n        #endif' in hello)
apply = block(stream, 'private func applyVisionInputCatalog(')
check('binding guard and drain precede catalog mutation and confirmation', apply.index('guard let peer, connection === peer') < apply.index('takeReleases()') < apply.index('cancelVisionInputs()') < apply.index('windows =') < apply.index('active =') < apply.index('visionInputBinding = binding'))
catalog = stream[stream.index('        case .windowList:'):stream.index('                // Forget thumbnails')]
check('main catalog checks current peer before binding', catalog.index('guard self.connection === from') < catalog.index('self.applyVisionInputCatalog(list, from: from)'))
check('connection setter awaits catalog before resuming UI', block(stream, 'var connection: NWConnection?').index('visionInputBinding = .awaitingCatalog') < block(stream, 'var connection: NWConnection?').index('setMoving(false)'))
check('move and teardown await catalog', all('visionInputBinding = .awaitingCatalog' in block(stream, marker) for marker in ['private func finishMoveAfterInputDrain(', 'func tearDown(status:']))
check('SessionLink locked implementation unchanged', (ROOT / 'iOSClient/SessionLink.swift').read_bytes() == baseline('iOSClient/SessionLink.swift'))
check('stream kinds and Data helpers unchanged', (ROOT / 'Sources/StreamProtocol/StreamMessage.swift').read_bytes() == baseline('Sources/StreamProtocol/StreamMessage.swift'))
session = (ROOT / 'visionOSClient/VisionInputSession.swift').read_text()
check('UI admission requires confirmed binding', ' && client.visionInputBinding.isConfirmed' in block(session, 'var canSend: Bool'))
check('normal chord and stop controls unchanged outside catalog gate', session.replace(' && client.visionInputBinding.isConfirmed', '') == baseline('visionOSClient/VisionInputSession.swift').decode())
debt = (ROOT / 'visionOSClient/VisionInputDebt.swift').read_text()
binding = block(debt, 'enum VisionInputBinding:')
check('binding distinguishes awaiting legacy and scoped', all(case in binding for case in ['case awaitingCatalog', 'case confirmedLegacy', 'case scoped(generation: String)']) and 'case .awaitingCatalog: return nil' in binding and 'case .confirmedLegacy: return CapturedVisionInput(event: event, generation: nil)' in binding)
prior_debt = baseline('visionOSClient/VisionInputDebt.swift', 'c62487a654e707aa47470213d4ac94e7dccb9f11').decode()
check('captured value and actual-send debt scope unchanged', debt[debt.index('struct CapturedVisionInput'): ] == prior_debt[prior_debt.index('struct CapturedVisionInput'): ])
check('unknown optional generation state removed', 'visionInputGeneration' not in stream and '@Published private(set) var visionInputBinding = VisionInputBinding.awaitingCatalog' in stream)
workspace = (ROOT / 'visionOSClient/SillVisionApp.swift').read_text()
check('waiting message outside disabled input controls and stop stays available', workspace.index('else if client.visionInputBinding == .awaitingCatalog') < workspace.index('private var controls: some View') and 'Button("누른 입력 해제") { input.releaseAll() }' in workspace)
check('palette also observes binding admission', 'VisionKeyPalette(input: input, desktop: client.active == .desktop)\n                        .disabled(!client.visionInputBinding.isConfirmed)' in workspace and '.disabled(!input.canSend)' in block(workspace, 'private var controls: some View'))
move = block(stream, 'private func finishMoveAfterInputDrain(')
check('move resets before adoption and retains normal catalog delivery', move.index('visionInputBinding = .awaitingCatalog') < move.index('link.handOver(') and 'for m in kept { self.deliver(m.header, m.payload, from: c) }' in move)

switcher = (ROOT / 'Sources/StreamProtocol/Switcher.swift').read_text()
field = '''
    /// Changes whenever the active source changes, including A → B → A. Echoed in SourceInput;
    /// scoped connections must echo it. Legacy connections pin source selection and keep their
    /// original input format until they disconnect or negotiate scoped input.
    public var inputGeneration: String?
'''
expected = baseline('Sources/StreamProtocol/Switcher.swift').decode().replace('    public var remoteAudio: Int?\n', '    public var remoteAudio: Int?\n' + field).replace('remoteAudio: Int? = nil) {', 'remoteAudio: Int? = nil, inputGeneration: String? = nil) {').replace('        self.remoteAudio = remoteAudio\n', '        self.remoteAudio = remoteAudio\n        self.inputGeneration = inputGeneration\n')
check('Switcher delta only adds peer optional field beside audio', switcher == expected)

files, manifest = fixture()
check('fixture has no unresolved substitutions', all(token not in files['Client.swift'] for token in ['// EXTRACTED', '// OVERLAY_DRAIN', '// MOVE_INPUT_RESET', '// BINDING_STATE']))
check('fixture uses actual Wire and framing without shadows', all(token not in files['Client.swift'] for token in ['enum Wire', 'struct StreamMessage', 'struct StreamHeader', 'enum StreamMessageKind']))
check('fixture extracts Vision and legacy Hello', 'hello.sourceInput = 1' in files['Client.swift'] and 'hello.sourceInput = 1' not in block(files['Client.swift'], 'private static let legacyHelloPayload: Data ='))
check('six mutants change sources', all(files[mutant] != files[original] for mutant, original in [('mutants/debt/Client.swift', 'Client.swift'), ('mutants/route/SessionLink.swift', 'iOSClient/SessionLink.swift'), ('mutants/capture/Client.swift', 'Client.swift'), ('mutants/generation/VisionInputDebt.swift', 'visionOSClient/VisionInputDebt.swift'), ('mutants/admission/Client.swift', 'Client.swift'), ('mutants/controls/VisionInputSession.swift', 'visionOSClient/VisionInputSession.swift')]))
remote = (Path(__file__).parent / 'remote.py').read_text()
check('input fixture builds actual protocol dependencies', "['Input','Switcher','StreamMessage','Compatibility']" in remote and '-whole-module-optimization' in remote)
reconnect = (ROOT / 'Tests/checks/reconnect-glue/mini.py').read_text()
check('reconnect pointer fixture includes Wire and Data helpers', all('Sources/StreamProtocol/' + name + '.swift' in reconnect for name in ['Input', 'Switcher', 'StreamMessage']) and "['Input','Switcher','StreamMessage']" in reconnect and '-whole-module-optimization' in reconnect)
for relative in ['Tests/checks/vision-input-controls/extract.py', 'Tests/checks/vision-input-controls/static.py', 'Tests/checks/vision-input-controls/mini.py', 'Tests/checks/vision-input-controls/remote.py', 'Tests/checks/reconnect-glue/mini.py']:
    ast.parse((ROOT / relative).read_text(), filename=relative)
check('Python fixture syntax', True)
print(json.dumps({'checks': results, 'count': len(results), 'extractionSHA256': manifest, 'scope': 'Static source and fixture checks only. Swift behavior and compilation remain unexecuted.'}, indent=2))
