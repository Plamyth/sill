"""Compile production wire/runtime in an inert process without app or audio startup."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='configured-craft-') as temporary:
    out = Path(temporary)
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill',
             '-module-cache-path', str(out / 'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
        '-o', str(out / 'libStreamProtocol.dylib')], check=True)
    server = (root / 'Sources/SillHost/StreamServer.swift').read_text()
    ticket = server[server.index('    final class ConfiguredCraftExchange:'):server.index('    private var viewerCount:')]
    handlers = server[server.index('    private func receiveConfiguredCraft('):server.index('    private func replayCatalog(')]
    fixture = out / 'ServerChecks.swift'
    fixture.write_text((here / 'ServerChecks.swift').read_text().replace('// PRODUCTION_TICKET', ticket)
                       .replace('// PRODUCTION_HANDLERS', handlers))
    socket_source = (root / 'Sources/SillHost/ProviderCallSocket.swift').read_text()
    bridge = (root / 'Sources/SillHost/ProviderCallBridge.swift').read_text()
    support = out / 'ProviderSupport.swift'
    support.write_text(bridge[:bridge.index('enum ProviderCallTarget:')] + '\n' +
                       socket_source[socket_source.index('protocol ProviderCallTransport:'):socket_source.index('final class ProviderCallSocket:')])
    subprocess.run(swift + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out),
        str(root / 'Sources/SillHost/HostConfiguredCraftRuntime.swift'),
        str(support), str(here / 'Main.swift'), str(fixture), '-o', str(out / 'checks')], check=True)
    subprocess.run([str(out / 'checks')], check=True, timeout=40,
                   env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)})
    relay = (root / 'Sources/SillHost/LocalAudioRelay.swift').read_text()
    socket_support = out / 'SocketSupport.swift'
    socket_support.write_text(bridge[:bridge.index('enum ProviderCallTarget:')] + '\n' +
        relay[relay.index('enum LocalAudioRelayJSON {'):relay.index('@MainActor\nfinal class LocalAudioRelay')])
    subprocess.run(swift + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), str(socket_support),
        str(root / 'Sources/SillHost/ProviderCallSocket.swift'),
        str(root / 'Sources/SillHost/HostConfiguredCraftRuntime.swift'),
        str(here / 'SocketChecks.swift'), '-o', str(out / 'socket-checks')], check=True)
    with tempfile.TemporaryDirectory(prefix='.ccr-craft-', dir=Path.home()) as socket_directory:
        subprocess.run([str(out / 'socket-checks'), socket_directory], check=True, timeout=20)
    assert not Path(socket_directory).exists(), 'isolated socket directory leaked'
    negative = out / 'Negative.swift'
    negative.write_text('''import Foundation
import Darwin
@main struct Negative {
    static func main() throws {
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        do {
            _ = try ProviderPeerAnchor.verify(pair[0], policy: .core)
            fatalError("inert fixture was accepted as installed Core")
        } catch { print("production Core peer verifier rejects inert fixture; actual Core effects=0") }
    }
}''')
    subprocess.run(swift + ['-parse-as-library', str(root / 'Sources/SillHost/ProviderPeerAnchor.swift'),
                           str(negative), '-o', str(out / 'negative')], check=True)
    subprocess.run([str(out / 'negative')], check=True, timeout=15)
print('configured-craft scratch removed; app/device/audio effects=0')
