"""실제 startup/등록/교환 메서드를 추출해 소켓·시계·Keychain 대역으로 검사한다."""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CLIENT = ROOT / 'iOSClient'

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

stream = (CLIENT / 'StreamClient.swift').read_text()
startup = '\n'.join(block(stream, marker) for marker in [
    'private enum StartupAutoConnection', 'func armSavedMacAutoConnect()',
    'private func trySavedMacAutoConnect()', 'func rememberPreferredMac('])
owner = (CLIENT / 'StreamClient+OwnerBootstrap.swift').read_text()
owner = owner.replace('import Network\n', '').replace('import UIKit\n', '').replace('#if os(iOS)', '#if true')
exchange = owner[owner.index('final class OwnerBootstrapExchange'):]
extension = owner[owner.index('#if true'):owner.index('/// 실제 등록 교환 소켓')]
remote = (CLIENT / 'StreamClient+Remote.swift').read_text()
# 실제 startRemote의 정리 순서와 수동 취소 진입점도 사용한다.
methods = '\n'.join(block(remote, marker) for marker in [
    'func startRemote()', 'func cancelPairing()', 'func pairTyped('])
methods += '\n' + block(stream, 'private func cameForward()')
methods += '\n' + block(stream, 'private func wentToBackground()')
# 수동 연결·새 페어링은 실제 진입점의 첫 취소 구간을 가져와 소켓 소유권을 검사한다.
home = (CLIENT / 'StreamClient+Home.swift').read_text()
boundaries = []
for source, marker in [(stream, 'func connect(to mac:'), (stream, 'func connect(to endpoint:'),
                       (stream, 'func disconnect()'), (remote, 'func dialSaved('),
                       (remote, 'private func startPairing('), (home, 'func startAsk('),
                       (home, 'func pairLinkAtHome(')]:
    entry = block(source, marker)
    prologue = entry[entry.index('{') + 1:entry.index('#endif') + len('#endif')]
    boundaries.append('func cancellationBoundary' + str(len(boundaries)) + '() {' + prologue + '\n}')
methods += '\n' + '\n'.join(boundaries)
fixture = (HERE / 'Standins.swift').read_text().replace('// STARTUP_METHODS', startup + '\n' + methods)
fixture = fixture.replace('private func cameForward()', 'func cameForward()').replace('private func wentToBackground()', 'func wentToBackground()')
fixture += '\n' + extension + '\n' + exchange + '\n' + (HERE / 'scenarios.swift').read_text()
# 공통 타입만 실제 소스로 컴파일한다. Network/Keychain은 호출하지 않는다.
with tempfile.TemporaryDirectory(prefix='build-', dir=HERE) as folder:
    out = Path(folder)
    cache = HERE / '.cache'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run(['swiftc', '-module-cache-path', str(cache), '-emit-library', '-emit-module',
                    '-module-name', 'StreamProtocol',
                    *map(str, sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))),
                    '-o', str(out / 'libStreamProtocol.dylib')], check=True, env=env, timeout=180)
    (out / 'main.swift').write_text(fixture.replace('#if os(iOS)', '#if true'))
    subprocess.run(['swiftc', '-module-cache-path', str(cache), '-I', str(out), '-L', str(out),
                    '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out),
                    str(CLIENT / 'SavedMacs.swift'), str(CLIENT / 'OwnerBootstrapState.swift'),
                    str(out / 'main.swift'), '-o', str(out / 'checks')], check=True, env=env, timeout=180)
    startup_checks = subprocess.run([str(out / 'checks'), str(out / 'synthetic.json')], timeout=30)

    connector = (CLIENT / 'RemoteConnector.swift').read_text().replace('import Network\n', '')
    connector = (HERE / 'Connector.swift').read_text().replace('// ACTUAL_CONNECTOR', connector)
    (out / 'main.swift').write_text(connector)
    subprocess.run(['swiftc', '-module-cache-path', str(cache), '-I', str(out), '-L', str(out),
                    '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out),
                    str(out / 'main.swift'), '-o', str(out / 'connector-checks')], check=True, env=env, timeout=180)
    connector_checks = subprocess.run([str(out / 'connector-checks')], timeout=30)
    if startup_checks.returncode != 0 or connector_checks.returncode != 0:
        raise SystemExit(1)
