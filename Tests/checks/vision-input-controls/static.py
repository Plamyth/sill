import ast
import json
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
prior_stream = subprocess.check_output(['git', '--no-lazy-fetch', 'show', 'e564f03c6206f192c84a1a2703d17d43c4ec70a8:iOSClient/StreamClient.swift'], cwd=ROOT).decode()
check('Vision input encoder unchanged', select_platform(send, vision=True) == select_platform(block(prior_stream, 'func sendInput('), vision=True))
check('iPad move coalescer retains captured peer and permit', 'sendPresentedInput(move.input, onlyOn: move.peer, permit: move.permit)' in block(stream, 'private func flushPendingMove()'))
check('native capture owns immutable permit before enqueue', send.index('let permit = visionInputPermit') < send.index('queue.async') and 'onlyOn: expected, permit: permit' in send)
check('native actual-send debt callback remains weak', 'self?.visionInputDebt.record(input, on: expected)' in send)
hello = block(stream, 'private static let helloPayload: Data =')
check('both clients advertise presentation capability', all('let presentationInput: Int? = 1' in select_platform(hello, vision=v) for v in [False, True]))
check('both clients retain optional source codec negotiation', all('sourceInput: 1' in select_platform(hello, vision=v) for v in [False, True]))
check('input session controls unchanged', (ROOT / 'visionOSClient/VisionInputSession.swift').read_text() == baseline('visionOSClient/VisionInputSession.swift'))
workspace = (ROOT / 'visionOSClient/SillVisionApp.swift').read_text()
check('emergency release remains available', 'Button("누른 입력 해제") { input.releaseAll() }' in workspace and '.disabled(!input.canSend || draftShown)' in block(workspace, 'private var controls: some View'))
check('move and teardown await fresh catalog', all('visionInputBinding = .awaitingCatalog' in block(stream, marker) for marker in ['private func finishMoveAfterInputDrain(', 'func tearDown(status:']))
files, manifest = fixture()
check('fixture substitutions resolved', all(marker not in files['Client.swift'] for marker in ['// EXTRACTED', '// OVERLAY_DRAIN', '// MOVE_INPUT_RESET', '// BINDING_STATE']))
check('fixture uses production SourceInputFence', files['Tests/checks/vision-input-controls/SourceInputFence.swift'] == (ROOT / 'Sources/SillHost/SourceInputFence.swift').read_text())
check('fixture includes native presentation state', files['visionOSClient/VisionPresentation.swift'] == (ROOT / 'visionOSClient/VisionPresentation.swift').read_text())
check('fixture has actual scoped input and hello paths', all(marker in files['Client.swift'] for marker in ['private func observeVisionInputCatalog(', 'private func visionPresentationChanged(', 'private static let helloPayload:', 'private static let iPadHelloPayload:']))
pairs = [('debt', 'Client.swift'), ('route', 'iOSClient/SessionLink.swift'), ('capture', 'Client.swift'), ('generation', 'visionOSClient/VisionInputDebt.swift'), ('admission', 'Client.swift'), ('controls', 'visionOSClient/VisionInputSession.swift')]
check('all six prior runtime mutants change source', all(files['mutants/' + name + '/' + Path(path).name] != files[path] for name, path in pairs))
resume = block(stream, 'if let resume = self.resumeSource')
check('automatic resume unchanged by input patch', resume == block(prior_stream, 'if let resume = self.resumeSource'))
for path in Path(__file__).parent.glob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
check('fixture Python syntax valid', True)
print(json.dumps({'checks': results, 'count': len(results), 'extractionSHA256': manifest,
                  'scope': 'Static source parity and fixture generation only. Swift compilation and runtime are not executed.'}, indent=2))
