"""실제 iOS ingress guard와 상태 표현을 컴파일한다. SwiftUI/SDK/실기기 수용은 별도다."""
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
remote = (CLIENT / 'StreamClient+Remote.swift').read_text()
home = (CLIENT / 'StreamClient+Home.swift').read_text()
entries = [(remote, name) for name in [
    'func requestPairingCode(', 'func handleOpenURL(', 'func confirmPendingLink(',
    'func pairTyped(', 'func scanned(', 'func pair(link:', 'func pair(code:', 'private func startPairing(']]
entries += [(home, name) for name in ['func startAsk(', 'func askOverStream(', 'func pairLinkAtHome(']]
guards = []
for source, name in entries:
    body = block(source, name)
    prologue = body[body.index('{') + 1:].lstrip()
    guard = 'guard Self.manualPairingEnabled else { return }'
    assert prologue.startswith(guard), name + ' must refuse before cancellation, parsing, keys or sockets'
    guards.append(f'func ingress{len(guards)}() {{ {prologue[:len(guard)]}\n effects += 1\n }}')
# UI 도달성은 구조 검사로 보조하며 실제 실행 검사와 구분한다.
content = (CLIENT / 'ContentView.swift').read_text()
assert 'manualConnectionEnabled' not in content
assert '#if DEBUG || !os(iOS)\nstruct ConnectScreen' in content
assert '#if !os(iOS)' in block(content, '.onOpenURL {')
assert 'client.manualPairingUIEnabled' in block(content, '@ViewBuilder var body:')
panel = (CLIENT / 'HostSettingsPanel.swift').read_text()
manual = block(panel, 'if client.manualPairingUIEnabled {')
assert 'Button(action: pairThisDevice)' in manual and '스캔' in manual
screen = (CLIENT / 'StreamScreen.swift').read_text()
assert 'client.manualPairingUIEnabled &&' in block(screen, 'private var overlayShown:')
for name in ['private func openPairingOverlay()', 'private func openLinkOverlay()']:
    assert block(screen, name).split('{', 1)[1].lstrip().startswith('guard client.manualPairingUIEnabled else { return }')
# Sill과 SillPhone은 같은 소스를 두 Sources phase에서 사용한다.
project = (CLIENT / 'Sill.xcodeproj/project.pbxproj').read_text()
for name in ['ContentView.swift', 'HostSettingsPanel.swift', 'StreamScreen.swift', 'StreamClient.swift',
             'StreamClient+Home.swift', 'StreamClient+Remote.swift', 'StreamClient+OwnerBootstrap.swift']:
    assert project.count('/* ' + name + ' in Sources */ =') == 2, name

members = '\n'.join(block(stream, name) for name in [
    'static var manualPairingEnabled:', 'var manualPairingUIEnabled:',
    'private enum StartupAutoConnection', 'var automaticConnectionPresentation:',
    'func dial(_ mac:'])
members += '\n' + block(remote, 'func handleOpenURL(')
members = members.replace('private enum StartupAutoConnection', 'enum StartupAutoConnection')
members = members.replace('#if os(iOS)', '#if true')
fixture = '''import Foundation
import StreamProtocol
enum DiscoveryPolicy {
    enum HomeDial { case updateSill, waitForTap, ask(pinned: Bool), pinned, anyKey, plain }
    static func updateSillStatus(mac: String) -> String { "update" }
    static func sessionTrust(_ decision: HomeDial, savedPin: Data?) -> Int? { 1 }
}
struct FoundMac { var name = "합성 Mac"; var macID: String? }
final class StreamClient {
    enum Pairing: Equatable { case idle, failed(Problem) }
    enum Problem { case notALink }
    var pairing = Pairing.idle
    var pendingLink: PairLink?
    func cancelOwnerBootstrap() { ownerBootstrap.cancel(); effects += 1 }
    func savedMac(_ id: String) -> SavedMac? { savedMacs.first { $0.macID == id } }
    func homeDecision(_ mac: FoundMac, macID: String?, tap: Bool) -> DiscoveryPolicy.HomeDial { .ask(pinned: true) }
    func ask(_ mac: FoundMac, savedID: String?, tagNamed: Bool, replaces: String?) { effects += 1 }
    func dialRow(_ mac: FoundMac, macID: String?, trust: Int, tagNamed: Bool, tap: Bool) -> Bool { effects += 1; return true }
    static let preferredTrustedMacKey = "Sill.preferredTrustedMacID"
    static let lookingOnNetwork = "network-wait-fixture"
    var ownerBootstrap = OwnerBootstrapState()
    var startupAutoConnection = StartupAutoConnection.unarmed
    var savedMacs: [SavedMac] = []
    var mockDiscovery = false
    struct Reconnect { var remoteAllowed: Bool }
    var connection: Int?, remoteDial: Int?
    var reconnect: Reconnect?
    var status = lookingOnNetwork
    var effects = 0
// MEMBERS
}
''' .replace('// MEMBERS', members + '\n' + '\n'.join(guards))
fixture += (HERE / 'ui.swift').read_text()
with tempfile.TemporaryDirectory(prefix='ui-build-', dir=HERE) as folder:
    out = Path(folder)
    cache = HERE / '.cache'
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run(['swiftc', '-module-cache-path', str(cache), '-emit-library', '-emit-module',
                    '-module-name', 'StreamProtocol', *map(str, sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))),
                    '-o', str(out / 'libStreamProtocol.dylib')], check=True, env=env, timeout=180)
    (out / 'main.swift').write_text(fixture)
    for mode in ['release', 'debug']:
        subprocess.run(['swiftc', *(['-D', 'DEBUG'] if mode == 'debug' else []),
                        '-module-cache-path', str(cache), '-I', str(out), '-L', str(out),
                        '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out),
                        str(CLIENT / 'SavedMacs.swift'), str(CLIENT / 'OwnerBootstrapState.swift'),
                        str(out / 'main.swift'), '-o', str(out / mode)], check=True, env=env, timeout=180)
        subprocess.run([str(out / mode)], check=True, timeout=30)
    sources = [CLIENT / name for name in ['ContentView.swift', 'HostSettingsPanel.swift', 'StreamScreen.swift',
                                         'StreamClient.swift', 'StreamClient+Home.swift', 'StreamClient+Remote.swift']]
    for mode in ['release', 'debug']:
        subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-ios17.0',
                        *(['-D', 'DEBUG'] if mode == 'debug' else []), *map(str, sources)],
                       check=True, timeout=60)
print('PASS release/debug iOS parse; UI ingress structure and shared SillPhone source references; not SDK typecheck')
