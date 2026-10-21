import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
production = [root / 'Sources/SillHost' / name for name in ['LocalCursorInputLease.swift', 'LocalCursorInputProtocol.swift', 'LocalCursorInputBroker.swift']]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
relay = root / 'Sources/SillHost/LocalAudioRelay.swift'
inputs = production + protocol + [relay, here / 'Boundary.swift', here / 'main.swift', Path(__file__).resolve()]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source = relay.read_text(); start = source.index('enum LocalAudioRelayJSON {'); opening = source.index('{', start); end = opening + 1; depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}'); end += 1
with tempfile.TemporaryDirectory(prefix='cursor-broker-') as temporary:
    out = Path(temporary)
    validator = out / 'Validator.swift'; validator.write_text('import Foundation\n' + source[start:end])
    shared = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol', *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'), '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
    subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, production), str(validator), str(here / 'Boundary.swift'), str(here / 'main.swift'), '-o', str(out / 'checks')], check=True, timeout=180)
    subprocess.run([str(out / 'checks')], check=True, timeout=30)
assert all(hashlib.sha256((root / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
print(json.dumps({'sourceHashes': hashes, 'sourceUnchanged': True, 'temporaryOutputRemoved': not out.exists(), 'actualProductionInput': 0}))
