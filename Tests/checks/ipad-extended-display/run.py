"""실제 소비 메서드와 SessionLink를 Mini의 해시 검증 RAM에서 검사한다."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
if len(sys.argv) != 2:
    raise SystemExit('usage: run.py ABSOLUTE_FRESH_ROUTED_OUTPUT')
OUT = Path(sys.argv[1])


def augment(inputs, block, root, here):
    screen = (root/'iOSClient/StreamScreen.swift').read_text()
    portrait = (root/'iOSClient/PortraitStreamScreen.swift').read_text()
    button = block(screen, 'struct IPadExtendedDisplayButton: View')
    assert '.disabled(!client.canSelectIPadExtendedDesktop)' in button
    assert 'accessibilityLabel: "iPad 확장 화면", action: selectExtendedDisplay' in button
    assert '.accessibilityIdentifier("iPadExtendedDisplayButton")' in button
    assert '확장 화면 요청 중' in button and '.lineLimit(2)' in button
    landscape = block(screen, 'private struct TopBar: View')
    vertical = block(portrait, 'private func windowBar(')
    assert all('IPadExtendedDisplayButton(client: client,' in bar for bar in [landscape, vertical])
    assert 'MacDisplayChooser(client: client,' in landscape and 'desktopButton(width: layout.buttonWidth)' in vertical
    assert 'IPadExtendedDisplayButton' not in block(portrait, 'private func phoneRow1(')
    members = '\n'.join(block(button, marker).replace('private ', '') for marker in [
        'private var candidate:', 'private var selected:', 'private func selectExtendedDisplay()'])
    inputs['Button.swift'] = 'import Foundation\n@MainActor struct ButtonFixture { let client: Client\n' + members + '\n}'
    inputs['main.swift'] = (HERE/'main.swift').read_text()
    inputs.pop('AutomaticDisplay.swift', None)
    subprocess.run([sys.executable, '-B', str(root/'Tests/checks/ipad-test-destinations/layout.py'),
                    str(OUT/'Layout.swift')], check=True)
    inputs['Layout.swift'] = (OUT/'Layout.swift').read_text()
    stream = (root/'iOSClient/StreamClient.swift').read_text()
    ready = block(stream, 'var displaySelectionReady:')
    inputs['Client.swift'] = inputs['Client.swift'].replace('var displaySelectionReady = true', ready)
    inputs['Client.swift'] = inputs['Client.swift'].replace('        displaySelectionReady = list.displaySelection == 1 && list.displayInventoryID != nil\n', '')
    accepted = 'guard self.applyVisionInputCatalog(list, from: from) else { return }'
    callback = 'self.observeExtendedDesktopCatalog(list, peer: peer)'
    assert stream.index(accepted) < stream.index(callback), '카탈로그 수용 뒤 소비해야 합니다.'
    class_start = inputs['Client.swift'].index('@MainActor final class Client')
    non_ipad = inputs['Client.swift'][class_start:].replace('#if true', '#if os(iOS)')
    inputs['NonIPadClient.swift'] = 'import Foundation\n' + block(non_ipad, '@MainActor final class Client').replace('final class Client', 'final class NonIPadClient', 1)
    for name in ['StreamClient.swift', 'StreamClient+Viewport.swift', 'StreamScreen.swift']:
        inputs[name+'.swiftparse'] = (root/'iOSClient'/name).read_text()
    print('실제 버튼·송신 메서드·카탈로그 수용 메서드·44pt 배치 검사를 결합했습니다.')


program = ROOT/'Tests/checks/source-request/run.py'
code = program.read_text().replace('sha = lambda data:', 'augment(inputs, block, root, here)\nsha = lambda data:', 1)
code = code.replace("+ list((root/'Sources/StreamProtocol').glob('*.swift'))", "+ list((root/'Sources/StreamProtocol').glob('*.swift')) + list((root/'Tests/checks/ipad-extended-display').glob('*'))")
sys.argv = [str(program), '--suite', 'client', '--output', str(OUT)]
exec(compile(code, str(program), 'exec'), {'__file__': str(program), 'augment': augment})
