import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
peer = root / 'Sources/SillHost/LocalCursorPeer.swift'
channel = root / 'Sources/SillHost/LocalCursorUnixChannel.swift'
inputs = [peer, channel, *sorted(here.glob('*.swift')), Path(__file__).resolve()]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source = channel.read_text()
def block(marker):
    start = source.index(marker); opening = source.index('{', start); end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end].replace('private ', '', 1)
methods = '\n'.join(block(marker) for marker in ['private static func address(', 'private func prepareDirectory(', 'private func identity(', 'private func acquireLifecycleLock(', 'private func releaseLifecycleLock(', 'private func readDiscovery(', 'private func clearStaleEndpoint(', 'private func writeDiscovery(', 'private func removeOwnedFiles('])
methods = methods.replace('Darwin.open(discoveryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)', 'Boundary.open(discoveryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)')
with tempfile.TemporaryDirectory(prefix='ccr-ci-', dir='/tmp') as temporary:
    out = Path(temporary).resolve()
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(out / 'cache')]
    subprocess.run(common + [str(peer), str(channel), str(here / 'main.swift'), '-o', str(out / 'peer')], check=True, timeout=180)
    subprocess.run([str(out / 'peer')], check=True, timeout=30)
    emitted = out / 'FileChecks.swift'
    emitted.write_text((here / 'FileChecks.swift').read_text().replace('// FILE_IDENTITY', block('private struct FileIdentity:')).replace('// METHODS', methods))
    subprocess.run(common + [str(emitted), '-o', str(out / 'files')], check=True, timeout=180)
    namespace = out / 'namespace'; namespace.mkdir()
    subprocess.run([str(out / 'files'), str(namespace)], check=True, timeout=30)
assert all(hashlib.sha256((root / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
print(json.dumps({'sourceHashes': hashes, 'sourceUnchanged': True, 'temporaryOutputRemoved': not out.exists(), 'productionNamespaceOrAppInput': 0, 'fixtureUnixFilesystemChecks': True}))
